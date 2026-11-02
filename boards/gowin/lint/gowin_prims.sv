// SPDX-License-Identifier: Apache-2.0
// Stand-ins for the Gowin primitives the board tops use, for the lint tests
// only (rs_component's LINT files): the ports Gowin's primitive guide gives,
// with simple behaviour. Yosys's synth_gowin and Gowin's own tools provide
// the real ones, so board builds never read this file.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
(* blackbox *)
module rPLL #(
    parameter FCLKIN = "100.0", parameter DYN_IDIV_SEL = "false", parameter IDIV_SEL = 0,
    parameter DYN_FBDIV_SEL = "false", parameter FBDIV_SEL = 0, parameter DYN_ODIV_SEL = "false",
    parameter ODIV_SEL = 8, parameter PSDA_SEL = "0000", parameter DYN_DA_EN = "false",
    parameter DUTYDA_SEL = "1000", parameter CLKOUT_FT_DIR = 1'b1, parameter CLKOUTP_FT_DIR = 1'b1,
    parameter CLKOUT_DLY_STEP = 0, parameter CLKOUTP_DLY_STEP = 0, parameter CLKFB_SEL = "internal",
    parameter CLKOUT_BYPASS = "false", parameter CLKOUTP_BYPASS = "false",
    parameter CLKOUTD_BYPASS = "false", parameter DYN_SDIV_SEL = 2, parameter CLKOUTD_SRC = "CLKOUT",
    parameter CLKOUTD3_SRC = "CLKOUT", parameter DEVICE = "GW2A-18C"
) (
    input  logic       CLKIN, CLKFB, RESET, RESET_P,
    input  logic [5:0] FBDSEL, IDSEL, ODSEL,
    input  logic [3:0] PSDA, DUTYDA, FDLY,
    output logic       CLKOUT, LOCK, CLKOUTP, CLKOUTD, CLKOUTD3
);
    assign {CLKOUT, CLKOUTP, CLKOUTD, CLKOUTD3} = {4{CLKIN}};
    assign LOCK = !RESET;
endmodule

(* blackbox *)
module DQCE (
    input  logic CLKIN, CE,
    output logic CLKOUT
);
    assign CLKOUT = CLKIN & CE;
endmodule

// The GW5A's clock gate, DQCE's counterpart.
(* blackbox *)
module DCE (
    input  logic CLKIN, CE,
    output logic CLKOUT
);
    assign CLKOUT = CLKIN & CE;
endmodule

(* blackbox *)
module CLKDIV #(
    parameter DIV_MODE = "2", parameter GSREN = "false"
) (
    input  logic HCLKIN, RESETN, CALIB,
    output logic CLKOUT
);
    assign CLKOUT = HCLKIN & RESETN;
endmodule

(* blackbox *)
module OSER10 #(
    parameter GSREN = "false", parameter LSREN = "true"
) (
    input  logic D0, D1, D2, D3, D4, D5, D6, D7, D8, D9, PCLK, FCLK, RESET,
    output logic Q
);
    assign Q = D0;
endmodule

(* blackbox *)
module TLVDS_OBUF (
    input  logic I,
    output logic O, OB
);
    assign O  = I;
    assign OB = !I;
endmodule
(* blackbox *)
module ELVDS_OBUF (
    input  logic I,
    output logic O, OB
);
    assign O  = I;
    assign OB = !I;
endmodule

// The GW5A's PLL (the Tang Console 138K's), with the ports and parameters
// boards/tang-console-138k uses.
(* blackbox *)
module PLL #(
    parameter FCLKIN = "50", parameter IDIV_SEL = 1, parameter FBDIV_SEL = 1, parameter MDIV_SEL = 8,
    parameter MDIV_FRAC_SEL = 0, parameter ODIV0_SEL = 8, parameter ODIV1_SEL = 8, parameter ODIV2_SEL = 8,
    parameter ODIV3_SEL = 8, parameter ODIV4_SEL = 8, parameter ODIV5_SEL = 8, parameter ODIV6_SEL = 8,
    parameter ODIV0_FRAC_SEL = 0, parameter CLKOUT0_EN = "TRUE", parameter CLKOUT1_EN = "FALSE",
    parameter CLKOUT2_EN = "FALSE", parameter CLKOUT3_EN = "FALSE", parameter CLKOUT4_EN = "FALSE",
    parameter CLKOUT5_EN = "FALSE", parameter CLKOUT6_EN = "FALSE", parameter CLKFB_SEL = "INTERNAL"
) (
    input  logic       CLKIN, CLKFB, RESET, PLLPWD, RESET_I, RESET_O,
    input  logic [5:0] FBDSEL, IDSEL,
    input  logic [6:0] MDSEL, ODSEL0, ODSEL1, ODSEL2, ODSEL3, ODSEL4, ODSEL5, ODSEL6,
    input  logic [2:0] MDSEL_FRAC, ODSEL0_FRAC,
    input  logic       ENCLK0, ENCLK1, ENCLK2, ENCLK3, ENCLK4, ENCLK5, ENCLK6,
    output logic       LOCK, CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6, CLKFBOUT
);
    assign {CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6, CLKFBOUT} = {8{CLKIN}};
    assign LOCK = !RESET;
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
