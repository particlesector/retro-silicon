// SPDX-License-Identifier: Apache-2.0
// Stand-ins for the Xilinx 7-series primitives the board tops use, for the
// lint tests only (rs_component's LINT files): the ports UG953 gives, with
// simple behaviour. Yosys's synth_xilinx provides the real ones, so board
// builds never read this file.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
(* blackbox *)
module PLLE2_BASE #(
    parameter BANDWIDTH = "OPTIMIZED", parameter integer CLKFBOUT_MULT = 5, parameter real CLKFBOUT_PHASE = 0.0,
    parameter real CLKIN1_PERIOD = 0.0, parameter integer DIVCLK_DIVIDE = 1, parameter real REF_JITTER1 = 0.0,
    parameter integer CLKOUT0_DIVIDE = 1, parameter integer CLKOUT1_DIVIDE = 1, parameter integer CLKOUT2_DIVIDE = 1,
    parameter integer CLKOUT3_DIVIDE = 1, parameter integer CLKOUT4_DIVIDE = 1, parameter integer CLKOUT5_DIVIDE = 1,
    parameter STARTUP_WAIT = "FALSE"
) (
    input  logic CLKIN1, CLKFBIN, RST, PWRDWN,
    output logic CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKFBOUT, LOCKED
);
    assign {CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKFBOUT} = {7{CLKIN1}};
    assign LOCKED = !RST;
endmodule

(* blackbox *)
module MMCME2_BASE #(
    parameter BANDWIDTH = "OPTIMIZED", parameter real CLKFBOUT_MULT_F = 5.0, parameter real CLKFBOUT_PHASE = 0.0,
    parameter real CLKIN1_PERIOD = 0.0, parameter integer DIVCLK_DIVIDE = 1, parameter real REF_JITTER1 = 0.0,
    parameter real CLKOUT0_DIVIDE_F = 1.0, parameter integer CLKOUT1_DIVIDE = 1, parameter integer CLKOUT2_DIVIDE = 1,
    parameter integer CLKOUT3_DIVIDE = 1, parameter integer CLKOUT4_DIVIDE = 1, parameter integer CLKOUT5_DIVIDE = 1,
    parameter integer CLKOUT6_DIVIDE = 1, parameter CLKOUT4_CASCADE = "FALSE", parameter STARTUP_WAIT = "FALSE"
) (
    input  logic CLKIN1, CLKFBIN, RST, PWRDWN,
    output logic CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B,
    output logic CLKOUT4, CLKOUT5, CLKOUT6, CLKFBOUT, CLKFBOUTB, LOCKED
);
    assign {CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6, CLKFBOUT} = {8{CLKIN1}};
    assign {CLKOUT0B, CLKOUT1B, CLKOUT2B, CLKOUT3B, CLKFBOUTB} = {5{!CLKIN1}};
    assign LOCKED = !RST;
endmodule

(* blackbox *)
module BUFG (input logic I, output logic O);
    assign O = I;
endmodule

(* blackbox *)
module BUFGCE (input logic I, CE, output logic O);
    assign O = I & CE;
endmodule

(* blackbox *)
module OSERDESE2 #(
    parameter DATA_RATE_OQ = "DDR", parameter DATA_RATE_TQ = "DDR", parameter integer DATA_WIDTH = 4,
    parameter SERDES_MODE = "MASTER", parameter integer TRISTATE_WIDTH = 4
) (
    input  logic CLK, CLKDIV, RST, OCE, TCE, TBYTEIN,
    input  logic D1, D2, D3, D4, D5, D6, D7, D8, T1, T2, T3, T4, SHIFTIN1, SHIFTIN2,
    output logic OQ, OFB, TQ, TFB, TBYTEOUT, SHIFTOUT1, SHIFTOUT2
);
    assign {OQ, OFB} = {2{D1}};
    assign {TQ, TFB, TBYTEOUT} = '0;
    assign {SHIFTOUT1, SHIFTOUT2} = {D3, D4};
endmodule

(* blackbox *)
module OBUFDS (input logic I, output logic O, OB);
    assign O = I;
    assign OB = !I;
endmodule

// The Zynq-7000's processing system: only the HP0 port's pins (UG585's PS7).
(* blackbox *)
module PS7 (
    input  logic        SAXIHP0ACLK,
    output logic        SAXIHP0ARESETN,
    input  logic [31:0] SAXIHP0ARADDR, SAXIHP0AWADDR,
    input  logic        SAXIHP0ARVALID, SAXIHP0AWVALID, SAXIHP0WVALID, SAXIHP0RREADY, SAXIHP0BREADY, SAXIHP0WLAST,
    input  logic        SAXIHP0RDISSUECAP1EN, SAXIHP0WRISSUECAP1EN,
    input  logic [3:0]  SAXIHP0ARLEN, SAXIHP0AWLEN, SAXIHP0ARCACHE, SAXIHP0AWCACHE, SAXIHP0ARQOS, SAXIHP0AWQOS,
    input  logic [1:0]  SAXIHP0ARSIZE, SAXIHP0AWSIZE, SAXIHP0ARBURST, SAXIHP0AWBURST, SAXIHP0ARLOCK, SAXIHP0AWLOCK,
    input  logic [2:0]  SAXIHP0ARPROT, SAXIHP0AWPROT,
    input  logic [5:0]  SAXIHP0ARID, SAXIHP0AWID, SAXIHP0WID,
    input  logic [63:0] SAXIHP0WDATA,
    input  logic [7:0]  SAXIHP0WSTRB,
    output logic        SAXIHP0ARREADY, SAXIHP0AWREADY, SAXIHP0WREADY, SAXIHP0RVALID, SAXIHP0RLAST, SAXIHP0BVALID,
    output logic [63:0] SAXIHP0RDATA,
    output logic [1:0]  SAXIHP0RRESP, SAXIHP0BRESP,
    output logic [5:0]  SAXIHP0RID, SAXIHP0BID, SAXIHP0WACOUNT,
    output logic [7:0]  SAXIHP0RCOUNT, SAXIHP0WCOUNT,
    output logic [2:0]  SAXIHP0RACOUNT
);
    assign {SAXIHP0ARESETN, SAXIHP0ARREADY, SAXIHP0AWREADY, SAXIHP0WREADY, SAXIHP0RVALID, SAXIHP0RLAST,
            SAXIHP0BVALID} = '0;
    assign {SAXIHP0RDATA, SAXIHP0RRESP, SAXIHP0BRESP, SAXIHP0RID, SAXIHP0BID, SAXIHP0WACOUNT, SAXIHP0RCOUNT,
            SAXIHP0WCOUNT, SAXIHP0RACOUNT} = '0;
endmodule
