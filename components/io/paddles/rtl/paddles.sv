// SPDX-License-Identifier: Apache-2.0
// The Atari 2600's four paddle inputs (INPT0-3), as Stella 7.0 models them: each a 68 nF capacitor
// charged from 5 V through its paddle's pot and 1.8 kohm, and dumped to ground through the TIA's
// 50 ohm while VBLANK bit 7 is set. The TIA reads 1 once a capacitor passes its threshold, the
// voltage a 1 Mohm pot reaches 379 lines after a dump.
//
// Each capacitor's voltage `u` is a 40-bit fraction of 5 V, stepped once a colour clock:
//   dumped:           u -= u * dump_rate
//   charging:         u += (1 - u) * rate(pos)
//   with no paddle:   u holds (Stella's unconnected pin; only a dump changes it)
// each step rounded to the nearest. `paddles_rate` (generated) has each position's rate.
//
// One multiplier steps the four capacitors in turn after each colour clock edge, with `dump` as it
// stands after that edge, in two stages: a capacitor's product on one clock, and its scaling and sum
// on the next (so the four take 5 clocks), each capacitor's operands registered a clock before. Each colour clock's step, with the dump that colour clock
// sees, is done before the next edge, so `hi` there is the capacitor at the end of the colour clock
// being read: a read `3n` colour clocks after a dump ends sees `3n` steps of charging, as Stella's
// timestamps count. So `cc` must come at least 6 clocks apart. A position change takes effect
// within 6 clocks.

module paddles #(
    parameter bit SAVE_STATE = 1'b1  // 0 leaves out the save-state port's logic
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cc,       // one colour clock
    input  logic        dump,     // VBLANK bit 7 (video/tia's `dump`)
    input  logic [3:0]  on,       // a paddle is plugged into input i
    input  logic [31:0] pos,      // paddle i's position in bits 8i+7:8i: a pot of pos / 256 Mohm

    output logic [3:0]  hi,       // input i is above the TIA's threshold

    // Save state: 5 words (each capacitor's u, low 32 bits in words 0-3, the high bytes in word 4),
    // written while `cc` is low and the capacitors aren't stepping (from the 6th clock after `cc`).
    input  logic [2:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);

    // ---- Rates: one position looked up each clock, in turn ----
    logic [1:0]  rr, rr_d, rr_q;           // the position being looked up, and where its rate goes
    logic [28:0] rate_q, dump_rate;
    logic [39:0] uth;
    logic [28:0] rate [4];

    paddles_rate u_rate (.clk, .pos(pos[8*rr +: 8]), .rate(rate_q), .dump_rate, .uth);

    // The ROM takes rr's position on the falling edge and has its rate on the rising edge after.
    always_ff @(negedge clk) rr_d <= rr;
    always_ff @(posedge clk) begin
        rr   <= rr + 2'd1;
        rr_q <= rr_d;
        rate[rr_q] <= rate_q;
    end

    // ---- The capacitors ----
    logic [39:0] u [4];
    logic [2:0]  step;  // after a colour clock: 1-4 multiply for capacitor step - 1; 2-5 add; 6 idle
    wire  [1:0]  ch = 2'(step - 3'd1);


    // Each capacitor's operands, taken a clock before its multiply (on the colour clock for the
    // first, then on steps 1-3), so the multiplier's inputs start at registers: the capacitor's
    // voltage, its distance to 5 V, and its rate. Every capacitor's last step lands before the
    // colour clock (at most step 5, and `cc` is at least 6 clocks apart), and each is taken
    // before its own step lands. `dump` is chosen at the multiply, as a write on the colour clock
    // changes it then.
    wire  [1:0]  och = cc ? 2'd0 : 2'(step);  // the capacitor the next clock multiplies
    logic [40:0] o_u, o_up;                   // its distance to 0, and to 5 V
    logic [28:0] o_rate;
    always_ff @(posedge clk) begin
        o_u    <= {1'b0, u[och]};
        o_up   <= 41'h100_0000_0000 - {1'b0, u[och]};
        o_rate <= rate[och];
    end

    // Stage 1, the one multiplier: x * m, x the distance to 0 while dumped, else to 5 V; a rate
    // c = {s, m} is m * 2^-(24 + s).
    wire  [28:0] c = dump ? dump_rate : o_rate;
    wire  [40:0] x = dump ? o_u : o_up;
    logic [64:0] p;                 // the product, waiting for stage 2
    logic [4:0]  p_s;
    logic [1:0]  p_ch;
    logic        p_down, p_go;      // dumped; the capacitor moves (dumped or plugged in)

    // Stage 2: the product scaled by 2^-(24 + s), rounded to the nearest.
    wire  [64:0] r = p >> (6'd23 + 6'(p_s));
    wire  [39:0] delta = 40'((r + 65'd1) >> 1);

    always_ff @(posedge clk)
        if (rst) begin
            for (int i = 0; i < 4; i++) u[i] <= 40'd0;
            step <= 3'd6;
            p_go <= 1'b0;
        end else if (cc) begin
            step <= 3'd1;
            p_go <= 1'b0;
        end else if (step != 3'd6) begin
            step <= step + 3'd1;
            p_go <= 1'b0;
            if (step <= 3'd4) begin
                p      <= x * {41'd0, c[23:0]};
                p_s    <= c[28:24];
                p_ch   <= ch;
                p_down <= dump;
                p_go   <= dump || on[ch];
            end
            if (p_go) u[p_ch] <= p_down ? u[p_ch] - delta : u[p_ch] + delta;
        end else if (SAVE_STATE && st_we) begin
            case (st_addr)
                3'd0, 3'd1, 3'd2, 3'd3: u[st_addr[1:0]][31:0] <= st_wdata;
                3'd4: {u[3][39:32], u[2][39:32], u[1][39:32], u[0][39:32]} <= st_wdata;
                default: ;
            endcase
        end

    always_comb
        for (int i = 0; i < 4; i++) hi[i] = u[i] > uth;

    if (SAVE_STATE) begin : g_st
        always_ff @(posedge clk)
            case (st_addr)
                3'd0, 3'd1, 3'd2, 3'd3: st_rdata <= u[st_addr[1:0]][31:0];
                3'd4: st_rdata <= {u[3][39:32], u[2][39:32], u[1][39:32], u[0][39:32]};
                default: st_rdata <= 32'd0;
            endcase
    end else begin : g_nost
        assign st_rdata = '0;
    end

endmodule
