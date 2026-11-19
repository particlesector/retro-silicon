// SPDX-License-Identifier: Apache-2.0
// For gb_roms_test: the console (gameboy) with its cartridge's controller and RAM
// (gb_cart), the ROM outside on `rom_addr`/`rom_q` (the test serves it a clock
// later, as block RAM would), and the cartridge's RAM and clock on gb_cart's shell
// port while held in reset.
module gb_cart_top #(
    parameter int RAM_AW = 17
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         ce,
    input  logic         cgb_hw,

    input  logic [2:0]   mbc,
    input  logic         rtc,
    input  logic         rumble,
    input  logic [4:0]   rom_log2,
    input  logic [4:0]   ram_log2,
    output logic [22:0]  rom_addr,
    input  logic [7:0]   rom_q,

    input  logic         sh_we,
    input  logic         sh_rtc,
    input  logic [16:0]  sh_addr,
    input  logic [7:0]   sh_wdata,
    output logic [7:0]   sh_q,

    input  logic         boot_we,
    input  logic [11:0]  boot_addr,
    input  logic [7:0]   boot_wdata,
    input  logic [7:0]   keys,

    output logic [15:0]  cart_addr,
    output logic         cart_wr,
    output logic [7:0]   cart_wdata,
    output logic [7:0]   ser_tx,
    output logic         ser_tx_valid,
    output logic         m_end,
    output logic         cpu_sync,
    output logic [15:0]  cpu_pc,
    output logic         pix_we,
    output logic [7:0]   pix_x,
    output logic [7:0]   pix_y,
    output logic [14:0]  pix_color,
    output logic         frame_end,
    output logic         frame_cut,
    output logic [7:0]   lcdc,
    output logic signed [9:0] aud_l,
    output logic signed [9:0] aud_r
);
    logic [7:0] cart_rdata, boot_q;
    logic       cart_rd, boot_on, m_last;

    gameboy u_gb (
        .clk, .rst, .ce, .cgb_hw_in(cgb_hw),
        .cart_addr, .cart_rd, .cart_wr, .cart_wdata, .cart_rdata,
        .boot_we, .boot_addr, .boot_wdata, .boot_q,
        .keys, .ser_tx, .ser_tx_valid,
        .m_end, .m_last, .cpu_sync, .cpu_pc, .boot_on, .lcdc,
        .pix_we, .pix_x, .pix_y, .pix_color, .frame_end, .frame_cut, .aud_l, .aud_r);

    gb_cart #(.ROM_AW(23), .RAM_AW(RAM_AW)) u_cart (
        .clk, .rst, .ce,
        .mbc, .rtc, .rumble, .rom_log2, .ram_log2,
        .addr(cart_addr), .wr(cart_wr), .wdata(cart_wdata), .rdata(cart_rdata),
        .rom_addr, .rom_q,
        .sh_we, .sh_rtc, .sh_addr, .sh_wdata, .sh_q);

    wire unused = &{1'b0, cart_rd, boot_on, m_last, boot_q};
endmodule
