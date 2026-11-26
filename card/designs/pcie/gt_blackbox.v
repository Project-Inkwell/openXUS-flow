// Minimal Yosys blackbox declarations for UltraScale+ GTY/BUFG_GT primitives
// used by card/designs/pcie/top.v (only needed if Yosys cells_xtra.v omits them).
(* blackbox *)
module IBUFDS_GTE4 #(
    parameter [0:0] REFCLK_EN_TX_PATH = 1'b0,
    parameter [1:0] REFCLK_HROW_CK_SEL = 2'b00,
    parameter [1:0] REFCLK_ICNTL_RX = 2'b00
) (
    output O,
    output ODIV2,
    input  CEB,
    (* iopad_external_pin *) input  I,
    (* iopad_external_pin *) input  IB
);
endmodule

(* blackbox *)
module BUFG_GT_SYNC (
    output CESYNC,
    output CLRSYNC,
    input  CE,
    input  CLK,
    input  CLR
);
endmodule

(* blackbox *)
module BUFG_GT (
    output O,
    input  CE,
    input  CEMASK,
    input  CLR,
    input  CLRMASK,
    input  [2:0] DIV,
    input  I
);
endmodule

(* blackbox *)
module GTYE4_CHANNEL #(
    parameter PCS_PCIE_EN = "FALSE",
    parameter integer CPLL_REFCLK_DIV = 1,
    parameter integer CPLL_FBDIV_45 = 5,
    parameter integer CPLL_FBDIV = 5,
    parameter integer TXOUT_DIV = 2,
    parameter integer RXOUT_DIV = 2,
    parameter integer TX_DATA_WIDTH = 20,
    parameter integer RX_DATA_WIDTH = 20,
    parameter integer TX_INT_DATAWIDTH = 0,
    parameter integer RX_INT_DATAWIDTH = 0,
    parameter TX_XCLK_SEL = "TXOUT",
    parameter RX_XCLK_SEL = "RXDES",
    parameter TXBUF_EN = "TRUE",
    parameter RXBUF_EN = "TRUE",
    parameter TX_DRIVE_MODE = "PIPE",
    parameter ALIGN_COMMA_DOUBLE = "FALSE",
    parameter [9:0] ALIGN_COMMA_ENABLE = 10'b1111111111,
    parameter integer ALIGN_COMMA_WORD = 1,
    parameter ALIGN_MCOMMA_DET = "TRUE",
    parameter [9:0] ALIGN_MCOMMA_VALUE = 10'b1010000011,
    parameter ALIGN_PCOMMA_DET = "TRUE",
    parameter [9:0] ALIGN_PCOMMA_VALUE = 10'b0101111100,
    parameter SHOW_REALIGN_COMMA = "TRUE",
    parameter DEC_MCOMMA_DETECT = "TRUE",
    parameter DEC_PCOMMA_DETECT = "TRUE",
    parameter DEC_VALID_COMMA_ONLY = "FALSE",
    parameter CLK_CORRECT_USE = "TRUE",
    parameter CLK_COR_KEEP_IDLE = "FALSE",
    parameter integer CLK_COR_MAX_LAT = 14,
    parameter integer CLK_COR_MIN_LAT = 11,
    parameter CLK_COR_PRECEDENCE = "TRUE",
    parameter [9:0] CLK_COR_SEQ_1_1 = 10'b0100011100,
    parameter [3:0] CLK_COR_SEQ_1_ENABLE = 4'b1111,
    parameter integer CLK_COR_SEQ_LEN = 1,
    parameter RXBUF_RESET_ON_CB_CHANGE = "TRUE",
    parameter RXBUF_RESET_ON_COMMAALIGN = "FALSE",
    parameter RXBUF_RESET_ON_EIDLE = "TRUE",
    parameter RXBUF_RESET_ON_RATE_CHANGE = "TRUE",
    parameter RX_DISPERR_SEQ_MATCH = "TRUE",
    parameter [11:0] PD_TRANS_TIME_FROM_P2 = 12'h03C,
    parameter [7:0]  PD_TRANS_TIME_NONE_P2 = 8'h19,
    parameter [7:0]  PD_TRANS_TIME_TO_P2 = 8'h64
) (
    (* iopad_external_pin *) input          GTYRXP,
    (* iopad_external_pin *) input          GTYRXN,
    (* iopad_external_pin *) output         GTYTXP,
    (* iopad_external_pin *) output         GTYTXN,
    input          GTREFCLK1,
    input          CPLLLOCKDETCLK,
    input          CPLLLOCKEN,
    input          CPLLPD,
    input  [2:0]   CPLLREFCLKSEL,
    input          CPLLRESET,
    output         CPLLLOCK,
    input          GTTXRESET,
    input          GTRXRESET,
    input          TXUSERRDY,
    input          RXUSERRDY,
    input          TXPROGDIVRESET,
    input          RXPROGDIVRESET,
    output         TXRESETDONE,
    output         RXRESETDONE,
    output         TXPMARESETDONE,
    output         RXPMARESETDONE,
    output         TXOUTCLK,
    input  [2:0]   TXOUTCLKSEL,
    input          TXUSRCLK,
    input          TXUSRCLK2,
    input          RXUSRCLK,
    input          RXUSRCLK2,
    input  [1:0]   TXPLLCLKSEL,
    input  [1:0]   RXPLLCLKSEL,
    input  [1:0]   TXSYSCLKSEL,
    input  [1:0]   RXSYSCLKSEL,
    input          TX8B10BEN,
    input          RX8B10BEN,
    input          RXCOMMADETEN,
    input          RXMCOMMAALIGNEN,
    input          RXPCOMMAALIGNEN,
    input  [127:0] TXDATA,
    input  [15:0]  TXCTRL0,
    input  [15:0]  TXCTRL1,
    input  [7:0]   TXCTRL2,
    input          TXELECIDLE,
    input          TXDETECTRX,
    input  [1:0]   TXPD,
    input  [1:0]   RXPD,
    input  [2:0]   TXRATE,
    input  [2:0]   RXRATE,
    input  [1:0]   TXDEEMPH,
    input  [2:0]   TXMARGIN,
    input          TXPDELECIDLEMODE,
    input          RXPOLARITY,
    output [127:0] RXDATA,
    output [15:0]  RXCTRL0,
    output         RXVALID,
    output [2:0]   RXSTATUS,
    output         RXELECIDLE,
    output         PHYSTATUS,
    input          DRPCLK
);
endmodule
