// SPDX-License-Identifier: Apache-2.0
// The Atari 2600 (NTSC): the 6507 (`cpu/6502` with decimal mode, 13 address lines), the TIA
// (`video/tia`, picture and sound) and the RIOT (`io/riot-6532`) on one bus, with the cartridge outside.
//
// One colour clock per `cc`; a CPU cycle is 3 of them, so `cc` must come at least 2 clocks apart for
// the RIOT's registered read. The cartridge sees the CPU's address on `cart_addr` while `cart_sel` is
// high (A12) and must have `cart_data` there by the clock that ends the cycle.
//
// The bus: A12 high selects the cartridge; A12 low with A7 low the TIA (writes by A5-A0, reads by
// A3-A0, which drive only bits 7-6: the rest keep the bus's last value, as on the console); A12 low
// with A7 high the RIOT, its RAM when A9 is low. Port A's pins are wired-AND: a bit reads low if the
// joystick pulls it low or the RIOT drives it low as an output.

module atari2600 #(
    parameter bit TIA_SCORE_GLITCH = 1'b0  // video/tia's SCORE_GLITCH
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cc,          // one colour clock

    output logic [11:0] cart_addr,
    output logic        cart_sel,    // this cycle is the cartridge's
    output logic        cart_we,
    output logic [7:0]  cart_wdata,
    input  logic [7:0]  cart_data,

    input  logic [7:0]  joy,         // SWCHA's pins: P0 right, left, down, up in 7-4, P1 in 3-0; 0 pressed
    input  logic [7:0]  switches,    // SWCHB's pins: 0 reset, 1 select, 3 colour, 6-7 difficulty; 0 pressed
    input  logic [1:0]  fire_n,      // INPT4, INPT5: P0's and P1's fire buttons

    output logic [7:0]  pix,         // the TIA's picture (video/tia's README)
    output logic        pix_on,
    output logic [7:0]  pix_x,
    output logic        line_end,
    output logic        vsync,
    output logic        vblank,
    output logic [3:0]  aud0,        // the TIA's sound: each channel's level, and Stella's sample points
    output logic [3:0]  aud1,
    output logic        aud_tick,

    output logic        cpu_sync,
    output logic [15:0] cpu_pc,
    output logic        bus_ce,      // for traces: this clock ends a CPU cycle, whose access is on bus_*
    output logic [12:0] bus_addr,
    output logic        bus_we,
    output logic [7:0]  bus_data
);

    // ---- Cycle ----
    logic [1:0] ph;  // colour clock within the CPU cycle
    always_ff @(posedge clk)
        if (rst) ph <= 2'd0;
        else if (cc) ph <= ph == 2'd2 ? 2'd0 : ph + 2'd1;
    wire ce = cc && ph == 2'd2;

    // ---- CPU ----
    logic [15:0] addr;
    logic        we, rdy;
    logic [7:0]  cpu_dout, cpu_din;
    logic [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p;
    logic        halted;
    logic [31:0] cpu_st;

    cpu_6502 #(.DECIMAL(1'b1), .SAVE_STATE(1'b0)) u_cpu (
        .clk, .rst, .soft_rst(1'b0), .ce,
        .addr, .we, .dout(cpu_dout), .din(cpu_din), .rdy,
        .irq_n(1'b1), .nmi_n(1'b1),
        .sync(cpu_sync), .halted,
        .dbg_pc(cpu_pc), .dbg_a, .dbg_x, .dbg_y, .dbg_s, .dbg_p,
        .st_addr(2'd0), .st_rdata(cpu_st), .st_we(1'b0), .st_wdata(32'd0)
    );

    wire sel_cart = addr[12];
    wire sel_tia  = !addr[12] && !addr[7];
    wire sel_riot = !addr[12] && addr[7];

    // ---- TIA ----
    logic [7:0]  tia_dout;
    logic [31:0] tia_st;
    tia #(.SAVE_STATE(1'b0), .SCORE_GLITCH(TIA_SCORE_GLITCH)) u_tia (
        .clk, .rst, .cc, .ce,
        .cs(sel_tia), .addr(we ? addr[5:0] : {2'b00, addr[3:0]}), .we, .din(cpu_dout),
        .dout(tia_dout), .rdy, .fire_n,
        .pix, .pix_on, .x(pix_x), .line_end, .vsync, .vblank, .aud0, .aud1, .aud_tick,
        .st_addr(5'd0), .st_rdata(tia_st), .st_we(1'b0), .st_wdata(32'd0)
    );

    // ---- RIOT ----
    logic [7:0]  riot_dout, pa_out, pa_ddr, pb_out, pb_ddr;
    logic        riot_irq_n;
    logic [31:0] riot_st;
    riot_6532 #(.SAVE_STATE(1'b0)) u_riot (
        .clk, .rst, .ce,
        .cs(sel_riot), .rs_n(addr[9]), .addr(addr[6:0]), .we, .din(cpu_dout), .dout(riot_dout),
        .pa_in(joy & (pa_out | ~pa_ddr)), .pa_out, .pa_ddr,
        .pb_in(switches), .pb_out, .pb_ddr,
        .irq_n(riot_irq_n),
        .st_addr(6'd0), .st_rdata(riot_st), .st_we(1'b0), .st_wdata(32'd0)
    );

    // ---- Data bus ----
    logic [7:0] bus;  // its last value: what the TIA leaves in bits 5-0
    always_comb begin
        if (sel_cart)
            cpu_din = cart_data;
        else if (sel_tia)
            cpu_din = {tia_dout[7:6], bus[5:0]};
        else
            cpu_din = riot_dout;
    end
    always_ff @(posedge clk)
        if (rst) bus <= 8'd0;
        else if (ce) bus <= we ? cpu_dout : cpu_din;

    assign bus_ce     = ce;
    assign bus_addr   = addr[12:0];
    assign bus_we     = we;
    assign bus_data   = we ? cpu_dout : cpu_din;

    assign cart_addr  = addr[11:0];
    assign cart_sel   = sel_cart;
    assign cart_we    = we;
    assign cart_wdata = cpu_dout;

    // The 2600 leaves the CPU's interrupts unconnected.
    wire unused = &{1'b0, tia_dout[5:0], bus[7:6], addr[15:13], dbg_a, dbg_x, dbg_y, dbg_s, dbg_p, halted, cpu_st, tia_st, riot_st,
                    riot_irq_n, pb_out, pb_ddr};

endmodule
