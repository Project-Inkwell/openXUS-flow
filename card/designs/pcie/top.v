// PCIe Gen1 x1 Endpoint on AS02MC04 (xcku3p-ffvb676-2-e) using pci_eerie soft
// core + GTYE4_CHANNEL_X0Y7 (Bank 225 Lane 0) + IBUFDS_GTE4 (MGTREFCLK1 T7/T6)
// + BUFG_GT/BUFG_GT_SYNC + 4 KB BAR0 scratchpad RAM.
//
// Clocking (zero MMCMs, zero QPLL):
//   100 MHz PCIe refclk (T7/T6) -> IBUFDS_GTE4 (GTYE4_COMMON_X0Y1/IBUFDS1_GTYE4)
//     .O     -> GTYE4_CHANNEL_X0Y7.GTREFCLK1 -> CPLL (N1=5, N2=5, M=1, D=2 -> 2.5 GT/s)
//     .ODIV2 -> BUFG_GT_SYNC + BUFG_GT(DIV=0) -> refclk_100m (100 MHz, DRP/lockdet/reset FSM)
//   GTYE4_CHANNEL_X0Y7.TXOUTCLK (125 MHz) -> BUFG_GT_SYNC ->
//     BUFG_GT(DIV=0) -> pclk (125 MHz: TXUSRCLK/2, RXUSRCLK/2, pci_eerie.PIPECLK)
//     BUFG_GT(DIV=1) -> uclk (62.5 MHz: pci_eerie.USERCLK/2, MIM BRAMs, BAR0 app)
//
// Internal power-on GT reset sequence (NO_RESET style) allows volatile JTAG
// reconfiguration + host PCIe rescan without needing PERST#.
`timescale 1ns / 1ps

module mim_ram #(
    parameter WIDTH = 69,
    parameter AW    = 9
) (
    input                  clk,
    input                  we,
    input      [AW-1:0]    waddr,
    input      [WIDTH-1:0] wdata,
    input                  re,
    input      [AW-1:0]    raddr,
    output reg [WIDTH-1:0] rdata
);
    // Split into <=36-bit halves so Yosys maps each half cleanly to RAMB18E2/RAMB36E2
    // without exceeding nextpnr's 36-bit write width limit.
    localparam LO = 36;
    localparam HI = WIDTH - LO;
    reg [LO-1:0] mem_lo [0:(1<<AW)-1];
    reg [HI-1:0] mem_hi [0:(1<<AW)-1];
    reg [LO-1:0] q_lo;
    reg [HI-1:0] q_hi;
    always @(posedge clk) begin
        if (we) begin
            mem_lo[waddr] <= wdata[LO-1:0];
            mem_hi[waddr] <= wdata[WIDTH-1:LO];
        end
        if (re) begin
            q_lo <= mem_lo[raddr];
            q_hi <= mem_hi[raddr];
        end
    end
    always @(*) rdata = {q_hi, q_lo};
endmodule

// 4 KB BAR0 memory responder on pci_eerie's 64-bit TRN interface (uclk = 62.5 MHz).
// Supports 3DW/4DW MWr (any length, dword writes) and 1..32 DW MRd -> single CplD.
// TRN 64-bit format: [63:32] = first DW (wire order), [31:0] = second DW.
module trn_bar0_app (
    input             clk,
    input             rst,
    input             dl_up,
    input      [15:0] completer_id,
    // TRN RX
    input      [63:0] trn_rd,
    input             trn_rrem,
    input             trn_rsof,
    input             trn_reof,
    input             trn_rsrc_rdy,
    output            trn_rdst_rdy,
    input      [7:0]  trn_rbar_hit,
    // TRN TX
    output reg [63:0] trn_td,
    output reg        trn_trem,
    output reg        trn_tsof,
    output reg        trn_teof,
    output reg        trn_tsrc_rdy,
    input             trn_tdst_rdy,
    input             trn_tcfg_req,
    output            trn_tcfg_gnt,
    // Diagnostics
    output reg [7:0]  wr_cnt,
    output reg [7:0]  rd_cnt
);
    // 32 x 32-bit (128 B, mirrored across 4 KB BAR0) split into even/odd banks
    // (1024 FFs total, fast timing with -nolutram) supporting 1..32 DW bursts.
    reg [31:0] mem_e [0:15];
    reg [31:0] mem_o [0:15];
    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1) begin
            mem_e[i] = 32'h0;
            mem_o[i] = 32'h0;
        end
        // Pre-loaded signature in BAR0[0..1] (little-endian host reads 0xCAFEBABE, 0x4B52414B)
        mem_e[0] = 32'hBEBA_FECA;
        mem_o[0] = 32'h4B41_524B;
    end

    reg        we_a, we_b;
    reg [4:0]  wa_a, wa_b;
    reg [31:0] wd_a, wd_b;
    wire       we_e = (we_a && !wa_a[0]) || (we_b && !wa_b[0]);
    wire       we_o = (we_a &&  wa_a[0]) || (we_b &&  wa_b[0]);
    wire [3:0] wa_e = (we_a && !wa_a[0]) ? wa_a[4:1] : wa_b[4:1];
    wire [3:0] wa_o = (we_a &&  wa_a[0]) ? wa_a[4:1] : wa_b[4:1];
    wire [31:0] wd_e = (we_a && !wa_a[0]) ? wd_a : wd_b;
    wire [31:0] wd_o = (we_a &&  wa_a[0]) ? wd_a : wd_b;
    always @(posedge clk) begin
        if (we_e) mem_e[wa_e] <= wd_e;
        if (we_o) mem_o[wa_o] <= wd_o;
    end

    // ---------------- RX ----------------
    wire [31:0] d_hi = trn_rd[63:32]; // first DW in TRN beat
    wire [31:0] d_lo = trn_rd[31:0];  // second DW in TRN beat

    reg        rx_in, rx_first, rx_wr, rx_4dw;
    reg [4:0]  rx_addr;
    reg [31:0] h0, h1;
    reg        rd_req;
    reg [31:0] rd_h0, rd_h1;
    reg [4:0]  rd_addr;
    reg        rd_busy;

    // Pause accepting new reads while one completion is pending
    assign trn_rdst_rdy = !rd_req;

    always @(posedge clk) begin
        if (rst) begin
            rx_in <= 1'b0; rx_first <= 1'b0; rd_req <= 1'b0;
            we_a <= 1'b0; we_b <= 1'b0;
            wr_cnt <= 8'd0; rd_cnt <= 8'd0;
        end else begin
            we_a <= 1'b0; we_b <= 1'b0;
            if (rd_req && rd_busy) rd_req <= 1'b0;
            if (trn_rsrc_rdy && trn_rdst_rdy) begin
                if (trn_rsof) begin
                    h0 <= d_hi; h1 <= d_lo;
                    rx_wr <= d_hi[30]; rx_4dw <= d_hi[29];
                    rx_in <= !trn_reof; rx_first <= 1'b1;
                end else if (rx_in) begin
                    rx_first <= 1'b0;
                    if (rx_first) begin
                        if (!rx_4dw) begin
                            // 3DW header: d_hi = addr, d_lo = DW0 payload (for MWr)
                            rx_addr <= d_hi[6:2] + 5'd1;
                            if (rx_wr && h0[28:24] == 5'b00000) begin
                                we_a <= 1'b1; wa_a <= d_hi[6:2]; wd_a <= d_lo;
                                wr_cnt <= wr_cnt + 8'd1;
                            end else if (!rx_wr && h0[28:24] == 5'b00000) begin
                                rd_req <= 1'b1; rd_h0 <= h0; rd_h1 <= h1; rd_addr <= d_hi[6:2];
                                rd_cnt <= rd_cnt + 8'd1;
                            end
                        end else begin
                            // 4DW header: d_hi = addr_hi, d_lo = addr_lo
                            rx_addr <= d_lo[6:2];
                            if (!rx_wr && h0[28:24] == 5'b00000) begin
                                rd_req <= 1'b1; rd_h0 <= h0; rd_h1 <= h1; rd_addr <= d_lo[6:2];
                                rd_cnt <= rd_cnt + 8'd1;
                            end
                        end
                    end else if (rx_wr && h0[28:24] == 5'b00000) begin
                        we_a <= 1'b1; wa_a <= rx_addr; wd_a <= d_hi;
                        we_b <= (!trn_reof) || trn_rrem; wa_b <= rx_addr + 5'd1; wd_b <= d_lo;
                        rx_addr <= rx_addr + 5'd2;
                    end
                    if (trn_reof) rx_in <= 1'b0;
                end
            end
        end
    end

    // ---------------- TX (CplD completions) ----------------
    function [11:0] f_bcnt;
        input [9:0] l; input [3:0] fbe; input [3:0] lbe;
        reg [12:0] b; reg [1:0] fs, ls;
        begin
            fs = fbe[0] ? 2'd0 : fbe[1] ? 2'd1 : fbe[2] ? 2'd2 : fbe[3] ? 2'd3 : 2'd0;
            if (l == 10'd1) begin
                ls = fbe[3] ? 2'd0 : fbe[2] ? 2'd1 : fbe[1] ? 2'd2 : fbe[0] ? 2'd3 : 2'd0;
                b = (fbe == 4'd0) ? 13'd1 : 13'd4 - fs - ls;
            end else begin
                ls = lbe[3] ? 2'd0 : lbe[2] ? 2'd1 : lbe[1] ? 2'd2 : 2'd3;
                b = {1'b0, (l == 0 ? 11'd1024 : {1'b0, l}), 2'b00} - fs - ls;
            end
            f_bcnt = b[11:0];
        end
    endfunction
    function [1:0] f_laddr_lo;
        input [3:0] fbe;
        f_laddr_lo = fbe[0] ? 2'd0 : fbe[1] ? 2'd1 : fbe[2] ? 2'd2 : fbe[3] ? 2'd3 : 2'd0;
    endfunction

    reg [1:0]  c_st;
    reg [9:0]  c_len, c_left;
    reg [4:0]  c_addr;
    wire [4:0] c_addr1 = c_addr + 5'd1;
    wire [31:0] e_c  = mem_e[c_addr[4:1]];
    wire [31:0] o_c  = mem_o[c_addr[4:1]];
    wire [31:0] e_c1 = mem_e[c_addr1[4:1]];

    // Always grant internal config/UR completions when we are not mid-packet
    assign trn_tcfg_gnt = (c_st == 2'd0);

    always @(posedge clk) begin
        if (rst || !dl_up) begin
            rd_busy <= 1'b0; c_st <= 2'd0;
            trn_tsrc_rdy <= 1'b0; trn_tsof <= 1'b0; trn_teof <= 1'b0; trn_trem <= 1'b1;
            trn_td <= 64'd0;
        end else begin
            case (c_st)
            2'd0: begin
                trn_tsrc_rdy <= 1'b0; trn_tsof <= 1'b0; trn_teof <= 1'b0;
                if (rd_req && !rd_busy && trn_tdst_rdy && !trn_tcfg_req) begin
                    rd_busy <= 1'b1;
                    c_len <= rd_h0[9:0]; c_addr <= rd_addr;
                    // Beat 0: DW0 (CplD) in [63:32], DW1 (completer/bytecount) in [31:0]
                    trn_td <= {
                        {3'b010, 5'b01010, 1'b0, rd_h0[22:20], 4'h0, 2'b00, rd_h0[13:12], 2'b00, rd_h0[9:0]},
                        {completer_id, 3'b000, 1'b0, f_bcnt(rd_h0[9:0], rd_h1[3:0], rd_h1[7:4])}
                    };
                    trn_tsof <= 1'b1; trn_teof <= 1'b0; trn_trem <= 1'b1; trn_tsrc_rdy <= 1'b1;
                    c_st <= 2'd1;
                end
            end
            2'd1: begin
                // Beat 1: DW2 (reqid/tag/laddr) in [63:32], DW3 (first data) in [31:0]
                trn_td <= {
                    {rd_h1[31:16], rd_h1[15:8], 1'b0, c_addr[4:0], f_laddr_lo(rd_h1[3:0])},
                    (c_addr[0] ? o_c : e_c)
                };
                trn_tsof <= 1'b0;
                trn_teof <= (c_len == 10'd1);
                trn_trem <= 1'b1;
                trn_tsrc_rdy <= 1'b1;
                c_addr <= c_addr + 5'd1;
                c_left <= c_len - 10'd1;
                c_st <= (c_len == 10'd1) ? 2'd3 : 2'd2;
            end
            2'd2: begin
                // Subsequent data beats
                trn_td <= c_addr[0] ? {o_c, e_c1} : {e_c, o_c};
                trn_tsof <= 1'b0;
                trn_teof <= (c_left <= 10'd2);
                trn_trem <= (c_left != 10'd1);
                trn_tsrc_rdy <= 1'b1;
                c_addr <= c_addr + 5'd2;
                c_left <= (c_left <= 10'd2) ? 10'd0 : (c_left - 10'd2);
                if (c_left <= 10'd2) c_st <= 2'd3;
            end
            default: begin
                trn_tsrc_rdy <= 1'b0; trn_tsof <= 1'b0; trn_teof <= 1'b0;
                rd_busy <= 1'b0;
                c_st <= 2'd0;
            end
            endcase
        end
    end
endmodule

module top (
    input  refclk_p,
    input  refclk_n,
    input  rxp,
    input  rxn,
    output txp,
    output txn,
    output led
);
    // ------------------------------------------------------------------
    // 1. Reference clock (Bank 225 MGTREFCLK1: T7/T6 -> GTYE4_COMMON_X0Y1)
    // ------------------------------------------------------------------
    wire refclk_o, refclk_odiv2;
    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH(1'b0),
        .REFCLK_HROW_CK_SEL(2'b00),
        .REFCLK_ICNTL_RX(2'b00)
    ) ibufds_ref (
        .I(refclk_p),
        .IB(refclk_n),
        .CEB(1'b0),
        .O(refclk_o),
        .ODIV2(refclk_odiv2)
    );

    wire ref_ce_sync, ref_clr_sync, refclk_100m;
    BUFG_GT_SYNC sync_ref (
        .CLK(refclk_odiv2), .CE(1'b1), .CLR(1'b0),
        .CESYNC(ref_ce_sync), .CLRSYNC(ref_clr_sync)
    );
    BUFG_GT bufg_ref (
        .I(refclk_odiv2), .CE(ref_ce_sync), .CEMASK(1'b0),
        .CLR(ref_clr_sync), .CLRMASK(1'b0), .DIV(3'd0),
        .O(refclk_100m)
    );

    // ------------------------------------------------------------------
    // 2. GTYE4_CHANNEL_X0Y7 power-on reset sequencer (100 MHz domain)
    // ------------------------------------------------------------------
    wire cplllock, txpmaresetdone, rxpmaresetdone, txresetdone, rxresetdone;
    reg [15:0] por_cnt = 16'd0;
    reg [2:0]  rst_st = 3'd0;
    reg        cpllreset = 1'b0;
    reg        gt_txrx_reset = 1'b1;
    reg        gt_userrdy = 1'b0;
    reg        pcie_rstn = 1'b0;

    // 2-FF synchronizers into refclk_100m
    reg [1:0] s_cplllock = 2'b00, s_pma = 2'b00, s_rstdone = 2'b00;
    always @(posedge refclk_100m) begin
        s_cplllock <= {s_cplllock[0], cplllock};
        s_pma      <= {s_pma[0], txpmaresetdone & rxpmaresetdone};
        s_rstdone  <= {s_rstdone[0], txresetdone & rxresetdone};
        case (rst_st)
        3'd0: begin // Initial settle (~650 us at 100 MHz)
            cpllreset <= 1'b0; gt_txrx_reset <= 1'b1; gt_userrdy <= 1'b0; pcie_rstn <= 1'b0;
            por_cnt <= por_cnt + 16'd1;
            if (&por_cnt) begin por_cnt <= 16'd0; rst_st <= 3'd1; end
        end
        3'd1: begin // Pulse CPLLRESET high (~20 us)
            cpllreset <= 1'b1; gt_txrx_reset <= 1'b1;
            por_cnt <= por_cnt + 16'd1;
            if (por_cnt == 16'd2000) begin por_cnt <= 16'd0; rst_st <= 3'd2; end
        end
        3'd2: begin // Wait for CPLL lock
            cpllreset <= 1'b0; gt_txrx_reset <= 1'b1;
            if (s_cplllock[1]) begin por_cnt <= 16'd0; rst_st <= 3'd3; end
        end
        3'd3: begin // Release GTTXRESET/GTRXRESET, wait for PMA reset done
            gt_txrx_reset <= 1'b0;
            if (s_pma[1]) begin por_cnt <= 16'd0; rst_st <= 3'd4; end
        end
        3'd4: begin // Assert TXUSERRDY/RXUSERRDY, wait for TX/RX reset done
            gt_userrdy <= 1'b1;
            if (s_rstdone[1]) begin por_cnt <= 16'd0; rst_st <= 3'd5; end
        end
        default: begin // Running
            cpllreset <= 1'b0; gt_txrx_reset <= 1'b0; gt_userrdy <= 1'b1; pcie_rstn <= 1'b1;
        end
        endcase
    end

    // ------------------------------------------------------------------
    // 3. GTYE4_CHANNEL_X0Y7 (Bank 225 Lane 0, Gen1 2.5 GT/s CPLL PIPE)
    // ------------------------------------------------------------------
    wire txoutclk, pclk, uclk;
    wire tx_ce_sync, tx_clr_sync;
    BUFG_GT_SYNC sync_tx (
        .CLK(txoutclk), .CE(1'b1), .CLR(!txpmaresetdone),
        .CESYNC(tx_ce_sync), .CLRSYNC(tx_clr_sync)
    );
    BUFG_GT bufg_pclk (
        .I(txoutclk), .CE(tx_ce_sync), .CEMASK(1'b0),
        .CLR(tx_clr_sync), .CLRMASK(1'b0), .DIV(3'd0),
        .O(pclk)
    );
    BUFG_GT bufg_uclk (
        .I(txoutclk), .CE(tx_ce_sync), .CEMASK(1'b0),
        .CLR(tx_clr_sync), .CLRMASK(1'b0), .DIV(3'd1),
        .O(uclk)
    );

    wire [15:0] pipe_txdata, pipe_rxdata;
    wire [1:0]  pipe_txdatak, pipe_rxdatak, pipe_powerdown;
    wire [2:0]  pipe_rxstatus;
    wire        pipe_txelecidle, pipe_txdetectrx, pipe_rxpolarity;
    wire        pipe_rxvalid, pipe_rxelecidle, pipe_phystatus;
    wire [127:0] gt_rxdata;
    wire [15:0]  gt_rxctrl0;

    GTYE4_CHANNEL #(
        .PCS_PCIE_EN("TRUE"),
        .CPLL_REFCLK_DIV(1),
        .CPLL_FBDIV_45(5),
        .CPLL_FBDIV(5),
        .TXOUT_DIV(2),
        .RXOUT_DIV(2),
        .TX_DATA_WIDTH(20),
        .RX_DATA_WIDTH(20),
        .TX_INT_DATAWIDTH(0),
        .RX_INT_DATAWIDTH(0),
        .TX_XCLK_SEL("TXOUT"),
        .RX_XCLK_SEL("RXDES"),
        .TXBUF_EN("TRUE"),
        .RXBUF_EN("TRUE"),
        .TX_DRIVE_MODE("PIPE"),
        .ALIGN_COMMA_DOUBLE("FALSE"),
        .ALIGN_COMMA_ENABLE(10'b1111111111),
        .ALIGN_COMMA_WORD(1),
        .ALIGN_MCOMMA_DET("TRUE"),
        .ALIGN_MCOMMA_VALUE(10'b1010000011),
        .ALIGN_PCOMMA_DET("TRUE"),
        .ALIGN_PCOMMA_VALUE(10'b0101111100),
        .SHOW_REALIGN_COMMA("TRUE"),
        .DEC_MCOMMA_DETECT("TRUE"),
        .DEC_PCOMMA_DETECT("TRUE"),
        .DEC_VALID_COMMA_ONLY("FALSE"),
        .CLK_CORRECT_USE("TRUE"),
        .CLK_COR_KEEP_IDLE("FALSE"),
        .CLK_COR_MAX_LAT(14),
        .CLK_COR_MIN_LAT(11),
        .CLK_COR_PRECEDENCE("TRUE"),
        .CLK_COR_SEQ_1_1(10'b0100011100),
        .CLK_COR_SEQ_1_ENABLE(4'b1111),
        .CLK_COR_SEQ_LEN(1),
        .RXBUF_RESET_ON_CB_CHANGE("TRUE"),
        .RXBUF_RESET_ON_COMMAALIGN("FALSE"),
        .RXBUF_RESET_ON_EIDLE("TRUE"),
        .RXBUF_RESET_ON_RATE_CHANGE("TRUE"),
        .RX_DISPERR_SEQ_MATCH("TRUE"),
        .PD_TRANS_TIME_FROM_P2(12'h03C),
        .PD_TRANS_TIME_NONE_P2(8'h19),
        .PD_TRANS_TIME_TO_P2(8'h64)
    ) gty_ch0 (
        .GTYRXP(rxp), .GTYRXN(rxn),
        .GTYTXP(txp), .GTYTXN(txn),
        .GTREFCLK1(refclk_o),
        .CPLLLOCKDETCLK(refclk_100m),
        .CPLLLOCKEN(1'b1),
        .CPLLPD(1'b0),
        .CPLLREFCLKSEL(3'b010),
        .CPLLRESET(cpllreset),
        .CPLLLOCK(cplllock),
        .GTTXRESET(gt_txrx_reset),
        .GTRXRESET(gt_txrx_reset),
        .TXUSERRDY(gt_userrdy),
        .RXUSERRDY(gt_userrdy),
        .TXPROGDIVRESET(1'b0),
        .RXPROGDIVRESET(1'b0),
        .TXRESETDONE(txresetdone),
        .RXRESETDONE(rxresetdone),
        .TXPMARESETDONE(txpmaresetdone),
        .RXPMARESETDONE(rxpmaresetdone),
        .TXOUTCLK(txoutclk),
        .TXOUTCLKSEL(3'b010),
        .TXUSRCLK(pclk),
        .TXUSRCLK2(pclk),
        .RXUSRCLK(pclk),
        .RXUSRCLK2(pclk),
        .TXPLLCLKSEL(2'b00),
        .RXPLLCLKSEL(2'b00),
        .TXSYSCLKSEL(2'b00),
        .RXSYSCLKSEL(2'b00),
        .TX8B10BEN(1'b1),
        .RX8B10BEN(1'b1),
        .RXCOMMADETEN(1'b1),
        .RXMCOMMAALIGNEN(1'b1),
        .RXPCOMMAALIGNEN(1'b1),
        .TXDATA({112'd0, pipe_txdata}),
        .TXCTRL0(16'd0),
        .TXCTRL1(16'd0),
        .TXCTRL2({6'd0, pipe_txdatak}),
        .TXELECIDLE(pipe_txelecidle),
        .TXDETECTRX(pipe_txdetectrx),
        .TXPD(pipe_powerdown),
        .RXPD(pipe_powerdown),
        .TXRATE(3'b000),
        .RXRATE(3'b000),
        .TXDEEMPH(2'b01),
        .TXMARGIN(3'b000),
        .TXPDELECIDLEMODE(1'b0),
        .RXPOLARITY(pipe_rxpolarity),
        .RXDATA(gt_rxdata),
        .RXCTRL0(gt_rxctrl0),
        .RXVALID(pipe_rxvalid),
        .RXSTATUS(pipe_rxstatus),
        .RXELECIDLE(pipe_rxelecidle),
        .PHYSTATUS(pipe_phystatus),
        .DRPCLK(refclk_100m)
    );
    assign pipe_rxdata  = gt_rxdata[15:0];
    assign pipe_rxdatak = gt_rxctrl0[1:0];

    // ------------------------------------------------------------------
    // 4. pci_eerie Gen1 x1 soft PCIe endpoint + MIM BRAMs + BAR0 RAM
    // ------------------------------------------------------------------
    wire        mim_tx_wen, mim_tx_ren, mim_rx_wen, mim_rx_ren;
    wire [12:0] mim_tx_waddr, mim_tx_raddr, mim_rx_waddr, mim_rx_raddr;
    wire [68:0] mim_tx_wdata, mim_tx_rdata;
    wire [67:0] mim_rx_wdata, mim_rx_rdata;

    mim_ram #(.WIDTH(69), .AW(9)) mim_tx (
        .clk(uclk), .we(mim_tx_wen), .waddr(mim_tx_waddr[8:0]), .wdata(mim_tx_wdata),
        .re(mim_tx_ren), .raddr(mim_tx_raddr[8:0]), .rdata(mim_tx_rdata)
    );
    mim_ram #(.WIDTH(68), .AW(9)) mim_rx (
        .clk(uclk), .we(mim_rx_wen), .waddr(mim_rx_waddr[8:0]), .wdata(mim_rx_wdata),
        .re(mim_rx_ren), .raddr(mim_rx_raddr[8:0]), .rdata(mim_rx_rdata)
    );

    wire [127:0] trn_rd;
    wire [1:0]   trn_rrem;
    wire         trn_rsof, trn_reof, trn_rsrc_rdy, trn_rdst_rdy;
    wire [7:0]   trn_rbar_hit;
    wire [63:0]  trn_td;
    wire         trn_trem, trn_tsof, trn_teof, trn_tsrc_rdy;
    wire [3:0]   trn_tdst_rdy;
    wire         trn_tcfg_req, trn_tcfg_gnt;
    wire         dl_up, user_rstn;
    wire [5:0]   ltssm_state;
    wire [15:0]  cfg_msg_data;
    wire [63:0]  dbg_vec_a;

    pci_eerie #(
        .LINK_CAP_MAX_LINK_SPEED(4'h1),
        .LINK_CAP_MAX_LINK_WIDTH(6'h01),
        .PCIE_CAP_DEVICE_PORT_TYPE(4'h0),
        .HEADER_TYPE(8'h00),
        .CLASS_CODE(24'h058000),
        .BAR0(32'hFFFFF000),
        .BAR1(32'h00000000),
        .BAR2(32'h00000000),
        .BAR3(32'h00000000),
        .BAR4(32'h00000000),
        .BAR5(32'h00000000),
        .EXPANSION_ROM(32'h00000000),
        .DEV_CAP_MAX_PAYLOAD_SUPPORTED(3'd0),
        .VC0_RX_RAM_LIMIT(13'h1FF),
        .VC0_TOTAL_CREDITS_PH(8'd16),
        .VC0_TOTAL_CREDITS_PD(12'd128),
        .VC0_TOTAL_CREDITS_NPH(8'd12),
        .VC0_TOTAL_CREDITS_NPD(12'd24),
        .VC0_TOTAL_CREDITS_CH(8'd36),
        .VC0_TOTAL_CREDITS_CD(12'd200),
        .VC0_CPL_INFINITE("TRUE"),
        .TL_TX_RAM_RDATA_LATENCY(1),
        .TL_RX_RAM_RDATA_LATENCY(1),
        .PL_FAST_TRAIN("FALSE"),
        .UPCONFIG_CAPABLE("FALSE")
    ) pcie (
        .PIPECLK(pclk),
        .USERCLK(uclk),
        .USERCLK2(uclk),
        .SYSRSTN(pcie_rstn),
        .PLRSTN(pcie_rstn),
        .DLRSTN(pcie_rstn),
        .TLRSTN(pcie_rstn),
        .CMRSTN(pcie_rstn),
        .CMSTICKYRSTN(pcie_rstn),
        .FUNCLVLRSTN(1'b1),
        // Identity: 10EE:7011
        .CFGVENDID(16'h10EE),
        .CFGDEVID(16'h7011),
        .CFGREVID(8'h01),
        .CFGSUBSYSVENDID(16'h10EE),
        .CFGSUBSYSID(16'h0007),
        .CFGDSN(64'h0000_0001_0100_0A35),
        .CFGPCIECAPINTERRUPTMSGNUM(5'd0),
        .CFGPORTNUMBER(8'd0),
        .CFGDSBUSNUMBER(8'd0), .CFGDSDEVICENUMBER(5'd0), .CFGDSFUNCTIONNUMBER(3'd0),
        // Inactive cfg/err/pm/int/mgmt inputs
        .CFGINTERRUPTN(1'b1), .CFGINTERRUPTASSERTN(1'b1), .CFGINTERRUPTDI(8'd0), .CFGINTERRUPTSTATN(1'b1),
        .CFGTRNPENDINGN(1'b1), .CFGPMWAKEN(1'b1), .CFGPMTURNOFFOKN(1'b0),
        .CFGPMFORCESTATE(2'b00), .CFGPMFORCESTATEENN(1'b1), .CFGPMHALTASPML0SN(1'b1), .CFGPMHALTASPML1N(1'b1),
        .CFGPMSENDPMETON(1'b0),
        .CFGERRURN(1'b1), .CFGERRCORN(1'b1), .CFGERRCPLABORTN(1'b1), .CFGERRCPLTIMEOUTN(1'b1),
        .CFGERRCPLUNEXPECTN(1'b1), .CFGERRECRCN(1'b1), .CFGERRACSN(1'b1), .CFGERRATOMICEGRESSBLOCKEDN(1'b1),
        .CFGERRINTERNALCORN(1'b1), .CFGERRINTERNALUNCORN(1'b1), .CFGERRLOCKEDN(1'b1), .CFGERRMALFORMEDN(1'b1),
        .CFGERRMCBLOCKEDN(1'b1), .CFGERRNORECOVERYN(1'b1), .CFGERRPOISONEDN(1'b1), .CFGERRPOSTEDN(1'b1),
        .CFGERRAERHEADERLOG(128'd0), .CFGERRTLPCPLHEADER(48'd0), .CFGAERINTERRUPTMSGNUM(5'd0),
        .CFGFORCECOMMONCLOCKOFF(1'b0), .CFGFORCEEXTENDEDSYNCON(1'b0), .CFGFORCEMPS(3'd0),
        .CFGMGMTRDENN(1'b1), .CFGMGMTWRENN(1'b1), .CFGMGMTBYTEENN(4'hF), .CFGMGMTDWADDR(10'd0),
        .CFGMGMTDI(32'd0), .CFGMGMTWRREADONLYN(1'b1), .CFGMGMTWRRW1CASRWN(1'b1),
        .DRPCLK(refclk_100m), .DRPEN(1'b0), .DRPWE(1'b0), .DRPADDR(9'd0), .DRPDI(16'd0),
        .DBGMODE(2'b00), .DBGSUBMODE(1'b0), .PLDBGMODE(3'b000),
        .LL2SENDASREQL1(1'b0), .LL2SENDENTERL1(1'b0), .LL2SENDENTERL23(1'b0),
        .LL2SENDPMACK(1'b0), .LL2SUSPENDNOW(1'b0), .LL2TLPRCV(1'b0),
        .TL2ASPMSUSPENDCREDITCHECK(1'b0), .TL2PPMSUSPENDREQ(1'b0),
        .PL2DIRECTEDLSTATE(5'd0), .PLDIRECTEDLINKAUTON(1'b0), .PLDIRECTEDLINKCHANGE(2'b00),
        .PLDIRECTEDLINKSPEED(1'b0), .PLDIRECTEDLINKWIDTH(2'b00), .PLDIRECTEDLTSSMNEW(6'd0),
        .PLDIRECTEDLTSSMNEWVLD(1'b0), .PLDIRECTEDLTSSMSTALL(1'b0),
        .PLDOWNSTREAMDEEMPHSOURCE(1'b0), .PLTRANSMITHOTRST(1'b0), .PLUPSTREAMPREFERDEEMPH(1'b0),
        // PIPE lane 0
        .PIPERX0DATA(pipe_rxdata),
        .PIPERX0CHARISK(pipe_rxdatak),
        .PIPERX0VALID(pipe_rxvalid),
        .PIPERX0STATUS(pipe_rxstatus),
        .PIPERX0ELECIDLE(pipe_rxelecidle),
        .PIPERX0PHYSTATUS(pipe_phystatus),
        .PIPERX0CHANISALIGNED(1'b1),
        .PIPETX0DATA(pipe_txdata),
        .PIPETX0CHARISK(pipe_txdatak),
        .PIPETX0ELECIDLE(pipe_txelecidle),
        .PIPETX0POWERDOWN(pipe_powerdown),
        .PIPETXRCVRDET(pipe_txdetectrx),
        .PIPERX0POLARITY(pipe_rxpolarity),
        // Unused lanes 1..7 tied idle
        .PIPERX1DATA(16'd0), .PIPERX1CHARISK(2'd0), .PIPERX1VALID(1'b0), .PIPERX1STATUS(3'd0), .PIPERX1ELECIDLE(1'b1), .PIPERX1PHYSTATUS(1'b0), .PIPERX1CHANISALIGNED(1'b0),
        .PIPERX2DATA(16'd0), .PIPERX2CHARISK(2'd0), .PIPERX2VALID(1'b0), .PIPERX2STATUS(3'd0), .PIPERX2ELECIDLE(1'b1), .PIPERX2PHYSTATUS(1'b0), .PIPERX2CHANISALIGNED(1'b0),
        .PIPERX3DATA(16'd0), .PIPERX3CHARISK(2'd0), .PIPERX3VALID(1'b0), .PIPERX3STATUS(3'd0), .PIPERX3ELECIDLE(1'b1), .PIPERX3PHYSTATUS(1'b0), .PIPERX3CHANISALIGNED(1'b0),
        .PIPERX4DATA(16'd0), .PIPERX4CHARISK(2'd0), .PIPERX4VALID(1'b0), .PIPERX4STATUS(3'd0), .PIPERX4ELECIDLE(1'b1), .PIPERX4PHYSTATUS(1'b0), .PIPERX4CHANISALIGNED(1'b0),
        .PIPERX5DATA(16'd0), .PIPERX5CHARISK(2'd0), .PIPERX5VALID(1'b0), .PIPERX5STATUS(3'd0), .PIPERX5ELECIDLE(1'b1), .PIPERX5PHYSTATUS(1'b0), .PIPERX5CHANISALIGNED(1'b0),
        .PIPERX6DATA(16'd0), .PIPERX6CHARISK(2'd0), .PIPERX6VALID(1'b0), .PIPERX6STATUS(3'd0), .PIPERX6ELECIDLE(1'b1), .PIPERX6PHYSTATUS(1'b0), .PIPERX6CHANISALIGNED(1'b0),
        .PIPERX7DATA(16'd0), .PIPERX7CHARISK(2'd0), .PIPERX7VALID(1'b0), .PIPERX7STATUS(3'd0), .PIPERX7ELECIDLE(1'b1), .PIPERX7PHYSTATUS(1'b0), .PIPERX7CHANISALIGNED(1'b0),
        // MIM BRAMs
        .MIMTXWEN(mim_tx_wen), .MIMTXWADDR(mim_tx_waddr), .MIMTXWDATA(mim_tx_wdata),
        .MIMTXREN(mim_tx_ren), .MIMTXRADDR(mim_tx_raddr), .MIMTXRDATA(mim_tx_rdata),
        .MIMRXWEN(mim_rx_wen), .MIMRXWADDR(mim_rx_waddr), .MIMRXWDATA(mim_rx_wdata),
        .MIMRXREN(mim_rx_ren), .MIMRXRADDR(mim_rx_raddr), .MIMRXRDATA(mim_rx_rdata),
        // TRN
        .TRNLNKUP(dl_up),
        .USERRSTN(user_rstn),
        .TRNFCSEL(3'b000), .TRNRFCPRET(1'b0), .TRNRNPOK(1'b1), .TRNRNPREQ(1'b1),
        .TRNTDLLPDATA(32'd0), .TRNTDLLPSRCRDY(1'b0), .TRNTECRCGEN(1'b0),
        .TRNTSRCDSC(1'b0), .TRNTERRFWD(1'b0), .TRNTSTR(1'b0),
        .TRNRD(trn_rd), .TRNRREM(trn_rrem), .TRNRSOF(trn_rsof), .TRNREOF(trn_reof),
        .TRNRSRCRDY(trn_rsrc_rdy), .TRNRDSTRDY(trn_rdst_rdy), .TRNRBARHIT(trn_rbar_hit),
        .TRNTD({64'd0, trn_td}), .TRNTREM({1'b0, trn_trem}), .TRNTSOF(trn_tsof), .TRNTEOF(trn_teof),
        .TRNTSRCRDY(trn_tsrc_rdy), .TRNTDSTRDY(trn_tdst_rdy),
        .TRNTCFGREQ(trn_tcfg_req), .TRNTCFGGNT(trn_tcfg_gnt),
        // Status
        .PLLTSSMSTATE(ltssm_state),
        .CFGMSGDATA(cfg_msg_data),
        .DBGVECA(dbg_vec_a)
    );

    wire [7:0] wr_cnt, rd_cnt;
    trn_bar0_app app (
        .clk(uclk), .rst(!user_rstn), .dl_up(dl_up),
        .completer_id(cfg_msg_data),
        .trn_rd(trn_rd[63:0]), .trn_rrem(trn_rrem[0]), .trn_rsof(trn_rsof), .trn_reof(trn_reof),
        .trn_rsrc_rdy(trn_rsrc_rdy), .trn_rdst_rdy(trn_rdst_rdy), .trn_rbar_hit(trn_rbar_hit),
        .trn_td(trn_td), .trn_trem(trn_trem), .trn_tsof(trn_tsof), .trn_teof(trn_teof),
        .trn_tsrc_rdy(trn_tsrc_rdy), .trn_tdst_rdy(trn_tdst_rdy[0]),
        .trn_tcfg_req(trn_tcfg_req), .trn_tcfg_gnt(trn_tcfg_gnt),
        .wr_cnt(wr_cnt), .rd_cnt(rd_cnt)
    );

    // ------------------------------------------------------------------
    // 5. Status LED + readback diagnostic register (uclk domain)
    // ------------------------------------------------------------------
    reg [25:0] blink_cnt = 26'd0;
    (* KEEP = "TRUE" *) reg [31:0] pcie_diag = 32'd0;
    always @(posedge uclk) begin
        blink_cnt <= blink_cnt + 26'd1;
        pcie_diag <= {
            wr_cnt[3:0], rd_cnt[3:0],
            dbg_vec_a[7:0],
            rst_st, cplllock, txpmaresetdone, rxpmaresetdone, txresetdone, rxresetdone,
            1'b0, dl_up, ltssm_state
        };
    end
    assign led = dl_up ? blink_cnt[22] : blink_cnt[25];
endmodule
