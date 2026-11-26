// A blinky for the AS02MC04 (xcku3p-ffvb676-2-e) needing no clock pin:
// STARTUPE3's configuration clock (CFGMCLK, about 50 MHz) through a global
// buffer, a counter, and its top bits on four of the board's LEDs.
module top(output [3:0] led);
    wire cfgmclk, clk;
    STARTUPE3 startup (
        .CFGMCLK(cfgmclk), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
        .USRCCLKO(1'b0), .USRCCLKTS(1'b0), .USRDONEO(1'b1), .USRDONETS(1'b1),
        .DO(4'b0000), .DTS(4'b1111), .FCSBO(1'b1), .FCSBTS(1'b1));
    BUFGCE clock_buffer (.I(cfgmclk), .CE(1'b1), .O(clk));
    reg [25:0] count = 0;
    always @(posedge clk) count <= count + 1;
    assign led = count[25:22];
endmodule
