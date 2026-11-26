# Loading and reading back an UltraScale+ image over a CH347

The CH347 runs in JTAG mode 3 (1a86:55dd). On the AS02MC04 it is wired directly with about
20 cm of jumper wire. The card's JTAG is 3.3 V (even though there is a "1v8" marking near
the JTAG connector, which is a bit confusing), and the header's 1V8 pin is not connected.

`cfg.c` only programs the FPGA configuration memory. This bypasses the flash and is a lot
faster and prevents flash wear. `ch347.h` is responsible for streaming the commands.

    cfg <factor> load design.bit        # JPROGRAM, CFG_IN, the stream, JSTART
    cfg <factor> regs                   # FAR, CTL0, STAT, COR0, IDCODE, ...
    cfg <factor> count design.ll 2 1000 # the blinky's counter, read back twice
    cfg <factor> frames | capdiff | sample
    bypass <factor> <bytes>             # random bits through BYPASS, compared

    gcc -O2 -o cfg cfg.c $(pkg-config --cflags --libs libusb-1.0) -lpthread
