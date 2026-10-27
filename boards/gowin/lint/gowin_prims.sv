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
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
