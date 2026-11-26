// The PCIe reference clock into the fabric, as the PCIe endpoint takes it:
// the slot's 100 MHz (MGTREFCLK1, T7/T6) through IBUFDS_GTE4's ODIV2, a
// BUFG_GT_SYNC and a BUFG_GT, counting (`count`); GTYE4_CHANNEL_X0Y7 on the
// same reference clock's CPLL, its TXOUTCLK through a BUFG_GT counting
// (`txc`) and its CPLLLOCK sampled on CFGMCLK (`lock_q`); and a counter on
// CFGMCLK (`ctrl`) saying the image runs at all. Vivado's pcie-gty seed 9.
module top(input refclk_p, input refclk_n, input rxp, input rxn, output txp, output txn, output led);
    wire refclk_o, refclk_odiv2, ce, clr, clk, cfgmclk, cfg_clk;
    wire cplllock, txoutclk, tx_ce, tx_clr, txclk;
    IBUFDS_GTE4 #(.REFCLK_EN_TX_PATH(1'b0), .REFCLK_HROW_CK_SEL(2'b00), .REFCLK_ICNTL_RX(2'b00)) ibufds_ref (
        .I(refclk_p), .IB(refclk_n), .CEB(1'b0), .O(refclk_o), .ODIV2(refclk_odiv2));
    BUFG_GT_SYNC sync_ref (.CLK(refclk_odiv2), .CE(1'b1), .CLR(1'b0), .CESYNC(ce), .CLRSYNC(clr));
    BUFG_GT bufg_ref (.I(refclk_odiv2), .CE(ce), .CEMASK(1'b0), .CLR(clr), .CLRMASK(1'b0), .DIV(3'd0), .O(clk));
    GTYE4_CHANNEL #(.PCS_PCIE_EN("TRUE"), .CPLL_REFCLK_DIV(1), .CPLL_FBDIV_45(5), .CPLL_FBDIV(5),
        .TXOUT_DIV(2), .RXOUT_DIV(2), .TX_DATA_WIDTH(20), .RX_DATA_WIDTH(20), .TX_INT_DATAWIDTH(0), .RX_INT_DATAWIDTH(0),
        .TXBUF_EN("TRUE"), .RXBUF_EN("TRUE"), .TX_DRIVE_MODE("PIPE")) gty_ch0 (
        .GTYRXP(rxp), .GTYRXN(rxn), .GTYTXP(txp), .GTYTXN(txn),
        .GTREFCLK1(refclk_o), .CPLLLOCKDETCLK(clk), .CPLLLOCKEN(1'b1), .CPLLPD(1'b0), .CPLLREFCLKSEL(3'b010), .CPLLRESET(1'b0), .CPLLLOCK(cplllock),
        .GTTXRESET(1'b0), .GTRXRESET(1'b0), .TXUSERRDY(1'b1), .RXUSERRDY(1'b1), .TXPROGDIVRESET(1'b0), .RXPROGDIVRESET(1'b0),
        .TXOUTCLK(txoutclk), .TXOUTCLKSEL(3'b010), .TXUSRCLK(txclk), .TXUSRCLK2(txclk), .RXUSRCLK(txclk), .RXUSRCLK2(txclk),
        .TXPLLCLKSEL(2'b00), .RXPLLCLKSEL(2'b00), .TXSYSCLKSEL(2'b00), .RXSYSCLKSEL(2'b00), .TXDATA(128'd0), .DRPCLK(clk));
    BUFG_GT_SYNC sync_tx (.CLK(txoutclk), .CE(1'b1), .CLR(1'b0), .CESYNC(tx_ce), .CLRSYNC(tx_clr));
    BUFG_GT bufg_tx (.I(txoutclk), .CE(tx_ce), .CEMASK(1'b0), .CLR(tx_clr), .CLRMASK(1'b0), .DIV(3'd0), .O(txclk));
    STARTUPE3 startup (.CFGMCLK(cfgmclk), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0), .USRCCLKO(1'b0), .USRCCLKTS(1'b0),
        .USRDONEO(1'b1), .USRDONETS(1'b1), .DO(4'b0000), .DTS(4'b1111), .FCSBO(1'b1), .FCSBTS(1'b1));
    BUFGCE cfg_buffer (.I(cfgmclk), .CE(1'b1), .O(cfg_clk));
    reg [25:0] count = 0, ctrl = 0, txc = 0;
    reg lock_q = 0;
    always @(posedge clk) count <= count + 1;
    always @(posedge cfg_clk) ctrl <= ctrl + 1;
    always @(posedge txclk) txc <= txc + 1;
    always @(posedge cfg_clk) lock_q <= cplllock;
    assign led = count[25] ^ ctrl[25] ^ txc[25] ^ lock_q;
endmodule
