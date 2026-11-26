// PicoRV32 on the AS02MC04 (xcku3p-ffvb676-2-e), clocked by STARTUPE3's
// CFGMCLK through a global buffer and held in reset for its first 2^7
// cycles: 8 KB of memory in block RAM holding its program (firmware.hex),
// a register at 0x10000000 whose bit 0 is the LED (B11), and a register at
// 0x10000004 the program writes its result to, read back from the card.
module top(output led);
    wire cfgmclk, clk;
    STARTUPE3 startup (
        .CFGMCLK(cfgmclk), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b1), .PACK(1'b0),
        .USRCCLKO(1'b0), .USRCCLKTS(1'b0), .USRDONEO(1'b1), .USRDONETS(1'b1),
        .DO(4'b0000), .DTS(4'b1111), .FCSBO(1'b1), .FCSBTS(1'b1));
    BUFGCE clock_buffer (.I(cfgmclk), .CE(1'b1), .O(clk));
    reg [7:0] reset_count = 0;
    wire resetn = reset_count[7];
    always @(posedge clk) if (!resetn) reset_count <= reset_count + 1;

    wire mem_valid, mem_instr;
    reg mem_ready = 0;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0] mem_wstrb;
    wire [31:0] read;
    picorv32 #(.ENABLE_COUNTERS(0), .CATCH_MISALIGN(0), .CATCH_ILLINSN(0), .STACKADDR(32'h2000), .PROGADDR_RESET(0))
        cpu (.clk(clk), .resetn(resetn), .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
             .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(read));

    reg [31:0] memory [0:2047];
    initial $readmemh("firmware.hex", memory);
    reg [31:0] word = 0;
    reg led_register = 0;
    reg [31:0] result = 0;
    wire in_memory = mem_addr < 32'h2000;
    // The memory: a word read and its bytes written as the strobes say,
    // the read word ready the cycle after.
    always @(posedge clk) begin
        if (mem_valid && in_memory) begin
            word <= memory[mem_addr[12:2]];
            if (mem_wstrb[0]) memory[mem_addr[12:2]][7:0] <= mem_wdata[7:0];
            if (mem_wstrb[1]) memory[mem_addr[12:2]][15:8] <= mem_wdata[15:8];
            if (mem_wstrb[2]) memory[mem_addr[12:2]][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) memory[mem_addr[12:2]][31:24] <= mem_wdata[31:24];
        end
    end
    reg was_memory = 0;
    reg [31:0] io_word = 0;
    always @(posedge clk) begin
        mem_ready <= mem_valid && !mem_ready;
        was_memory <= in_memory;
        if (mem_valid && !mem_ready && !in_memory) begin
            if (mem_addr[2] == 0 && |mem_wstrb) led_register <= mem_wdata[0];
            if (mem_addr[2] == 1 && |mem_wstrb) result <= mem_wdata;
            io_word <= mem_addr[2] ? result : {31'b0, led_register};
        end
    end
    // The memory's word the cycle it is ready, the registers' the cycle after.
    assign read = was_memory ? word : io_word;
    assign led = led_register;
endmodule
