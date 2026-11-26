// SERV (servant, olofk/serv) on the AS02MC04 (xcku3p-ffvb676-2-e): clocked
// by STARTUPE3's CFGMCLK through a global buffer, held in reset for the
// first 2^8 cycles, its GPIO on LED B11. Memories as registers: the backend
// places no block or LUT RAM yet.
module top(output led);
    wire cfgmclk, clk;
    STARTUPE3 startup (
        .CFGMCLK(cfgmclk), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
        .USRCCLKO(1'b0), .USRCCLKTS(1'b0), .USRDONEO(1'b1), .USRDONETS(1'b1),
        .DO(4'b0000), .DTS(4'b1111), .FCSBO(1'b1), .FCSBTS(1'b1));
    BUFGCE clock_buffer (.I(cfgmclk), .CE(1'b1), .O(clk));
    reg [8:0] reset_count = 0;
    wire reset = !reset_count[8];
    always @(posedge clk) if (reset) reset_count <= reset_count + 1;
    servant #(.memfile("blinky.hex"), .memsize(64), .sim(0), .with_csr(0)) soc (.wb_clk(clk), .wb_rst(reset), .q(led));
endmodule
