// SPDX-License-Identifier: Apache-2.0
// Sharp SM83, the Game Boy's CPU, exact to the machine cycle: one bus access
// (or none) per M-cycle, in the order the chip makes them.
//
// Bus timing: the CPU advances one M-cycle on each clock with `ce` high.
// During an M-cycle, addr/rd/wr/dout describe its access (combinationally from
// the CPU's state); a read's data must be on `din` by the clock edge that ends
// the M-cycle, and a write takes effect on that edge. An internal M-cycle has
// rd and wr low.
//
// As on the chip, an instruction's last step (an ALU result, a register
// loaded from memory) is written back during the M-cycle that fetches the
// next opcode: `wb` holds it pending until that M-cycle's edge. The dbg_*
// outputs show the registers with it applied, so at an opcode fetch they are
// the registers as the previous instruction left them.
//
// Interrupts: `int_req` is the system's IE & IF (bits 0-4: VBlank, STAT,
// timer, serial, joypad), combinational from its registers, so a write to IE
// or IF is seen in the next M-cycle. Dispatch takes 5 M-cycles: the opcode
// fetch dropped, two internal cycles, PC's high byte pushed, then its low
// byte, during which the CPU picks the vector from int_req as it is then and
// pulses `int_ack` with that bit for the system to clear in IF. If none is
// left (the high byte's push wrote IE), PC goes to $0000 and nothing is acked.
//
// HALT stops the CPU until int_req is non-zero; the M-cycle that sees it is
// the next one's first: the dispatch's dropped fetch (IME set) or the opcode
// fetch (IME clear), so `rd` may rise during it. With IME clear and an
// interrupt already pending, it doesn't halt and the next opcode byte is read
// twice (the HALT bug); with EI just before it and an interrupt pending, the
// interrupt returns to the HALT. EI enables interrupts after the next
// instruction; DI and RETI act at once. STOP reads the byte after it and
// stops the CPU, with `stopped` high, until `stop_exit` (the system's joypad
// line or speed switch); with an interrupt pending it does nothing (the next
// byte is the next opcode), unless `stop_switch` (the Color's speed switch is
// armed: it stops then too, as MesenCE's does). An illegal opcode locks the CPU up, `locked` high,
// until reset.
//
// Save state (docs/conventions.md): four words, readable and writable while
// ce is low, mid-instruction included.
//   0: A, B, C, D (A in bits 31-24)
//   1: E, H, L, then flags Z N H C, M-cycle step (3 bits), CB prefix
//   2: SP, PC
//   3: opcode, data latches low and high, then write-back pending, IME,
//      halted, stopped, locked, dispatching, in bits 7-2
module cpu_sm83 #(
    parameter bit SAVE_STATE = 1'b1  // 0 leaves out the save-state port's logic: writes do nothing, reads give 0
) (
    input  logic        clk,
    input  logic        rst,        // synchronous; PC starts at $0000 (the boot ROM)
    input  logic        ce,         // one M-cycle per clock with ce high

    output logic [15:0] addr,
    output logic        rd,         // this M-cycle reads din at addr
    output logic        wr,         // this M-cycle writes dout to addr
    output logic [7:0]  dout,
    input  logic [7:0]  din,

    input  logic [4:0]  int_req,    // IE & IF
    output logic [4:0]  int_ack,    // one-hot, in the dispatch's last M-cycle: clear this bit of IF at its edge
    input  logic        stop_exit,  // leaves STOP
    input  logic        stop_switch, // STOP stops even with an interrupt pending (a speed switch is armed)

    output logic        sync,       // this M-cycle fetches an opcode
    output logic        halted,
    output logic        stopped,
    output logic        stop_pulse, // the M-cycle that enters STOP (the system resets DIV)
    output logic        locked,     // an illegal opcode locked the CPU up

    // Registers, with any pending write-back applied.
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_sp,
    output logic [15:0] dbg_af,
    output logic [15:0] dbg_bc,
    output logic [15:0] dbg_de,
    output logic [15:0] dbg_hl,
    output logic        dbg_ime,    // IME, DI's effect included
    output logic        dbg_ei,     // an EI's enable is pending
    output logic        dbg_boundary, // between instructions: the next M-cycle fetches, dispatches or idles

    // Save-state port.
    input  logic [1:0]  st_addr,
    output logic [31:0] st_rdata,   // word st_addr, the clock after
    input  logic        st_we,
    input  logic [31:0] st_wdata
);

    // ---------------------------------------------------------------- state

    logic [7:0]  ra, rb, rc, rd_, re, rh, rl;  // rd_: register D (rd is the read strobe)
    logic [3:0]  rf;                            // Z N H C
    logic [15:0] sp, pc;
    logic [7:0]  op;                            // opcode (the second byte after CB)
    logic        cb;                            // op is a CB-prefixed opcode
    logic [2:0]  mc;                            // M-cycle step within the instruction; 0 between instructions
    logic        wb;                            // op's write-back is pending (mc is 0)
    logic [7:0]  tlo, thi;                      // data latches: operands and data read
    logic        ime, halt_r, stop_r, lock_r, disp;

    // ------------------------------------------------------------ functions

    localparam logic [3:0] FN = 4'b0100, FH = 4'b0010;

    // ALU A,v for op[5:3] (ADD ADC SUB SBC AND XOR OR CP): {result, Z N H C}.
    function automatic logic [11:0] alu8(input logic [2:0] sel, input logic [7:0] x,
                                         input logic [7:0] v, input logic cin);
        logic [8:0] s;
        logic [7:0] r;
        logic       n, h, c, ci;
        s = 9'd0; r = 8'd0; n = 1'b0; h = 1'b0; c = 1'b0;
        ci = sel[0] && cin;  // ADC and SBC
        case (sel)
            3'd0, 3'd1: begin  // ADD, ADC
                s = {1'b0, x} + {1'b0, v} + {8'd0, ci};
                h = ({1'b0, x[3:0]} + {1'b0, v[3:0]} + {4'd0, ci}) > 5'h0F;
                r = s[7:0]; c = s[8];
            end
            3'd2, 3'd3, 3'd7: begin  // SUB, SBC, CP (CP's sel[0] is 1, but it has no carry in)
                if (sel == 3'd7) ci = 1'b0;
                s = {1'b0, x} - {1'b0, v} - {8'd0, ci};
                h = {1'b0, x[3:0]} < ({1'b0, v[3:0]} + {4'd0, ci});
                r = s[7:0]; n = 1'b1; c = s[8];
            end
            3'd4: begin r = x & v; h = 1'b1; end
            3'd5: r = x ^ v;
            default: r = x | v;  // 6: OR
        endcase
        alu8 = {sel == 3'd7 ? x : r, r == 8'd0, n, h, c};
    endfunction

    // Rotate or shift v by sel (RLC RRC RL RR SLA SRA SWAP SRL), carry in cin: {result, carry}.
    function automatic logic [8:0] rot(input logic [2:0] sel, input logic [7:0] v, input logic cin);
        case (sel)
            3'd0: rot = {v[6:0], v[7], v[7]};
            3'd1: rot = {v[0], v[7:1], v[0]};
            3'd2: rot = {v[6:0], cin, v[7]};
            3'd3: rot = {cin, v[7:1], v[0]};
            3'd4: rot = {v[6:0], 1'b0, v[7]};
            3'd5: rot = {v[7], v[7:1], v[0]};
            3'd6: rot = {v[3:0], v[7:4], 1'b0};
            default: rot = {1'b0, v[7:1], v[0]};
        endcase
    endfunction

    // CB-prefixed opcode o (its bits 7-3) on v: {result, Z N H C}. Rotates
    // and shifts for o[7:6] = 0, BIT for 1, RES for 2, SET for 3; f is the
    // flags before, kept where the opcode leaves them.
    function automatic logic [11:0] cbop(input logic [7:3] o, input logic [7:0] v, input logic [3:0] f);
        logic [8:0] rv;
        logic [7:0] bm;
        rv = rot(o[5:3], v, f[0]);
        bm = 8'd1 << o[5:3];
        case (o[7:6])
            2'd0:    cbop = {rv[8:1], rv[8:1] == 8'd0, 1'b0, 1'b0, rv[0]};
            2'd1:    cbop = {v, (v & bm) == 8'd0, 1'b0, 1'b1, f[0]};
            2'd2:    cbop = {v & ~bm, f};
            default: cbop = {v | bm, f};
        endcase
    endfunction

    // DAA on x with flags f: {result, Z N H C}.
    function automatic logic [11:0] daa(input logic [7:0] x, input logic [2:0] f);  // f: N H C
        logic [7:0] corr, r;
        logic       c;
        corr = 8'd0; c = f[0];
        if (f[1] || (!f[2] && x[3:0] > 4'd9)) corr[3:0] = 4'h6;
        if (f[0] || (!f[2] && x > 8'h99)) begin corr[7:4] = 4'h6; c = 1'b1; end
        r = f[2] ? x - corr : x + corr;
        daa = {r, r == 8'd0, f[2], 1'b0, c};  // Z N H C
    endfunction

    // Opcodes that lock the CPU up.
    function automatic logic illegal(input logic [7:0] o);
        case (o)
            8'hD3, 8'hDB, 8'hDD, 8'hE3, 8'hE4, 8'hEB, 8'hEC, 8'hED, 8'hF4, 8'hFC, 8'hFD: illegal = 1'b1;
            default: illegal = 1'b0;
        endcase
    endfunction

    // Opcodes whose only M-cycle is their fetch.
    function automatic logic one_cycle(input logic [7:0] o);
        one_cycle = 1'b0;
        case (o[7:6])
            2'b00: one_cycle = o == 8'h00 || o == 8'h10 || o[2:0] == 3'd7
                            || ((o[2:1] == 2'b10) && o[5:3] != 3'd6);  // INC r, DEC r
            2'b01: one_cycle = o[5:3] != 3'd6 && o[2:0] != 3'd6 || o == 8'h76;
            2'b10: one_cycle = o[2:0] != 3'd6;
            default: one_cycle = o == 8'hE9 || o == 8'hF3 || o == 8'hFB || illegal(o);
        endcase
    endfunction

    // ------------------------------------------------- write-back (between instructions)

    // w_*: the registers with op's pending write-back applied.
    logic [7:0]  w_a, w_b, w_c, w_d, w_e, w_h, w_l;
    logic [3:0]  w_f;
    logic [15:0] w_sp, w_pc;
    logic        w_ime;

    function automatic logic [7:0] reg8(input logic [2:0] i, input logic [7:0] b_, input logic [7:0] c_,
                                        input logic [7:0] d_, input logic [7:0] e_, input logic [7:0] h_,
                                        input logic [7:0] l_, input logic [7:0] m_, input logic [7:0] a_);
        case (i)
            3'd0: reg8 = b_;
            3'd1: reg8 = c_;
            3'd2: reg8 = d_;
            3'd3: reg8 = e_;
            3'd4: reg8 = h_;
            3'd5: reg8 = l_;
            3'd6: reg8 = m_;
            default: reg8 = a_;
        endcase
    endfunction

    logic [7:0]  src;      // op[2:0]'s register, (HL) and d8 being the data read
    logic [11:0] alu_r, cb_r, daa_r, inc_r, dec_r;
    logic [8:0]  rot_r;
    logic [7:0]  incdec_in;
    logic [16:0] add16;
    logic [15:0] rr16;     // op[5:4]'s register pair (3: SP)
    logic [15:0] spe;      // SP + the signed offset in tlo
    logic        spe_h, spe_c;

    always_comb begin
        src = reg8(op[2:0], rb, rc, rd_, re, rh, rl, tlo, ra);
        if (!cb && op[7:6] == 2'b11) src = tlo;  // ALU A,d8
        alu_r = alu8(op[5:3], ra, src, rf[0]);
        cb_r  = cbop(op[7:3], src, rf);
        daa_r = daa(ra, rf[2:0]);
        rot_r = rot({1'b0, op[4:3]}, ra, rf[0]);  // RLCA RRCA RLA RRA: CB's RLC RRC RL RR on A
        incdec_in = reg8(op[5:3], rb, rc, rd_, re, rh, rl, tlo, ra);
        inc_r = {incdec_in + 8'd1, incdec_in == 8'hFF, 1'b0, incdec_in[3:0] == 4'hF, rf[0]};
        dec_r = {incdec_in - 8'd1, incdec_in == 8'h01, 1'b1, incdec_in[3:0] == 4'h0, rf[0]};
        case (op[5:4])
            2'd0: rr16 = {rb, rc};
            2'd1: rr16 = {rd_, re};
            2'd2: rr16 = {rh, rl};
            default: rr16 = sp;
        endcase
        add16 = {1'b0, rh, rl} + {1'b0, rr16};
        spe = sp + {{8{tlo[7]}}, tlo};
        spe_h = ({1'b0, sp[3:0]} + {1'b0, tlo[3:0]}) > 5'h0F;
        spe_c = ({1'b0, sp[7:0]} + {1'b0, tlo}) > 9'h0FF;
    end

    // Writes v to op[5:3]'s register (6, (HL), is never one).
    `define SM83_PUT(IDX, V) \
        case (IDX) \
            3'd0: w_b = V; 3'd1: w_c = V; 3'd2: w_d = V; 3'd3: w_e = V; \
            3'd4: w_h = V; 3'd5: w_l = V; 3'd7: w_a = V; default: ; \
        endcase

    always_comb begin
        w_a = ra; w_b = rb; w_c = rc; w_d = rd_; w_e = re; w_h = rh; w_l = rl; w_f = rf;
        w_sp = sp; w_pc = pc; w_ime = ime;
        if (wb) begin
            if (cb) begin
                if (op[7:6] != 2'b01 && op[2:0] != 3'd6) `SM83_PUT(op[2:0], cb_r[11:4])
                w_f = cb_r[3:0];
            end else begin
                casez (op)
                    8'b00??_0001: case (op[5:4])  // LD rr,d16
                        2'd0: {w_b, w_c} = {thi, tlo};
                        2'd1: {w_d, w_e} = {thi, tlo};
                        2'd2: {w_h, w_l} = {thi, tlo};
                        default: w_sp = {thi, tlo};
                    endcase
                    8'b00??_?100: begin  // INC r, INC (HL)
                        `SM83_PUT(op[5:3], inc_r[11:4])
                        w_f = inc_r[3:0];
                    end
                    8'b00??_?101: begin  // DEC r, DEC (HL)
                        `SM83_PUT(op[5:3], dec_r[11:4])
                        w_f = dec_r[3:0];
                    end
                    8'b00??_?110: `SM83_PUT(op[5:3], tlo)  // LD r,d8 (36 writes nothing back)
                    8'b000?_?111: begin  // RLCA RRCA RLA RRA: CB's rotates of A, Z clear
                        w_a = rot_r[8:1];
                        w_f = {3'b000, rot_r[0]};
                    end
                    8'h27: begin w_a = daa_r[11:4]; w_f = daa_r[3:0]; end
                    8'h2F: begin w_a = ~ra; w_f = rf | FN | FH; end
                    8'h37: w_f = {rf[3], 3'b001};
                    8'h3F: w_f = {rf[3], 2'b00, ~rf[0]};
                    8'b00??_1001: begin  // ADD HL,rr
                        {w_h, w_l} = add16[15:0];
                        w_f = {rf[3], 1'b0, ({1'b0, rh[3:0], rl} + {1'b0, rr16[11:0]}) > 13'h0FFF, add16[16]};
                    end
                    8'b00??_1010: w_a = tlo;  // LD A,(rr) and (HL+-)
                    8'b01??_????: if (op[5:3] != 3'd6) `SM83_PUT(op[5:3], src)  // LD r,r' and LD r,(HL)
                    8'b10??_????, 8'b11??_?110: begin  // ALU A,r / (HL) / d8
                        w_a = alu_r[11:4];
                        w_f = alu_r[3:0];
                    end
                    8'b11??_0001: case (op[5:4])  // POP
                        2'd0: {w_b, w_c} = {thi, tlo};
                        2'd1: {w_d, w_e} = {thi, tlo};
                        2'd2: {w_h, w_l} = {thi, tlo};
                        default: begin w_a = thi; w_f = tlo[7:4]; end
                    endcase
                    8'hE8: begin w_sp = spe; w_f = {2'b00, spe_h, spe_c}; end
                    8'hF8: begin {w_h, w_l} = spe; w_f = {2'b00, spe_h, spe_c}; end
                    8'hE9: w_pc = {rh, rl};
                    8'hF0, 8'hF2, 8'hFA: w_a = tlo;
                    8'hF3: w_ime = 1'b0;
                    8'hFB: w_ime = 1'b1;
                    default: ;
                endcase
            end
        end
    end
    `undef SM83_PUT

    // ------------------------------------------------------------- M-cycle

    logic [7:0]  n_a, n_b, n_c, n_d, n_e, n_h, n_l;
    logic [3:0]  n_f;
    logic [15:0] n_sp, n_pc;
    logic [7:0]  n_op, n_tlo, n_thi;
    logic        n_cb, n_wb, n_ime, n_halt, n_stop, n_lock, n_disp;
    logic [2:0]  n_mc;

    logic        pend, eff_ime, prev_halt, prev_stop, prev_ill, cond, boundary;
    logic [15:0] w_bc, w_de, w_hl, t16;
    logic [2:0]  s;         // the step, RET's and push's shared sequences lined up
    logic [4:0]  ack;

    always_comb begin
        pend      = |int_req;
        prev_halt = wb && !cb && op == 8'h76;
        prev_stop = wb && !cb && op == 8'h10;
        prev_ill  = wb && !cb && illegal(op);
        eff_ime   = ime && !(wb && !cb && op == 8'hF3);  // DI acts at once; EI's enable comes a fetch later
        boundary  = mc == 3'd0 && !disp;
        w_bc = {w_b, w_c}; w_de = {w_d, w_e}; w_hl = {w_h, w_l};
        t16  = {thi, tlo};
        case (op[4:3])
            2'd0: cond = !w_f[3];
            2'd1: cond = w_f[3];
            2'd2: cond = !w_f[0];
            default: cond = w_f[0];
        endcase
        ack = int_req[0] ? 5'b00001 : int_req[1] ? 5'b00010 : int_req[2] ? 5'b00100
            : int_req[3] ? 5'b01000 : int_req[4] ? 5'b10000 : 5'b00000;

        n_a = w_a; n_b = w_b; n_c = w_c; n_d = w_d; n_e = w_e; n_h = w_h; n_l = w_l; n_f = w_f;
        n_sp = w_sp; n_pc = w_pc; n_ime = w_ime;
        n_op = op; n_cb = cb; n_tlo = tlo; n_thi = thi; n_mc = mc; n_wb = 1'b0;
        n_halt = halt_r; n_stop = stop_r; n_lock = lock_r; n_disp = disp;
        addr = w_pc; rd = 1'b0; wr = 1'b0; dout = 8'h00;
        sync = 1'b0; stop_pulse = 1'b0; int_ack = 5'b00000;
        s = mc;

        if (boundary) begin
            // Halted, the M-cycle that sees an interrupt is the next one's
            // first: the dispatch's dropped fetch (IME set), or the fetch.
            if (halt_r && pend) n_halt = 1'b0;
            if (lock_r) begin
                // locked up for good
            end else if (stop_r) begin
                if (stop_exit) n_stop = 1'b0;
            end else if (halt_r && !pend) begin
                // halted: no access
            end else if (prev_ill) begin
                n_lock = 1'b1;
            end else if (prev_stop && (!pend || stop_switch)) begin
                rd = 1'b1;  // STOP's second byte, read and skipped
                n_pc = w_pc + 16'd1;
                n_stop = 1'b1;
                stop_pulse = 1'b1;
            end else if (prev_halt && !pend) begin
                rd = 1'b1;  // read and dropped
                n_halt = 1'b1;
            end else if (eff_ime && pend) begin
                rd = 1'b1;  // the opcode fetch, dropped
                n_disp = 1'b1;
                n_mc = 3'd1;
                n_ime = 1'b0;
                if (prev_halt) n_pc = w_pc - 16'd1;  // EI; HALT: return to the HALT
            end else begin
                rd = 1'b1;
                sync = 1'b1;
                n_op = din;
                n_cb = 1'b0;
                if (!prev_halt) n_pc = w_pc + 16'd1;  // else the HALT bug: this byte is read again
                if (one_cycle(din)) n_wb = 1'b1;
                else n_mc = 3'd1;
            end
        end else if (disp) begin
            n_mc = mc + 3'd1;
            case (mc)
                3'd2: n_sp = sp - 16'd1;
                3'd3: begin
                    wr = 1'b1; addr = sp; dout = pc[15:8];
                    n_sp = sp - 16'd1;
                end
                3'd4: begin
                    wr = 1'b1; addr = sp; dout = pc[7:0];
                    int_ack = ack;
                    n_pc = ack[0] ? 16'h0040 : ack[1] ? 16'h0048 : ack[2] ? 16'h0050
                         : ack[3] ? 16'h0058 : ack[4] ? 16'h0060 : 16'h0000;
                    n_mc = 3'd0;
                    n_disp = 1'b0;
                end
                default: ;
            endcase
        end else if (cb) begin
            // mc 2 and 3: (HL)
            if (mc == 3'd2) begin
                rd = 1'b1; addr = w_hl; n_tlo = din;
                if (op[7:6] == 2'b01) begin n_mc = 3'd0; n_wb = 1'b1; end
                else n_mc = 3'd3;
            end else begin
                wr = 1'b1; addr = w_hl; dout = cb_r[11:4];
                n_mc = 3'd0; n_wb = 1'b1;
            end
        end else begin
            n_mc = mc + 3'd1;
            casez (op)
                8'hCB: begin  // the second opcode byte
                    rd = 1'b1; sync = 1'b0; n_op = din; n_cb = 1'b1; n_pc = pc + 16'd1;
                    if (din[2:0] != 3'd6) begin n_mc = 3'd0; n_wb = 1'b1; end
                end
                8'b00??_0001, 8'h08, 8'hC3, 8'b110?_?010, 8'b110?_?100, 8'hCD, 8'hEA, 8'hFA: begin
                    // 16-bit operands; then what each does with them
                    if (mc == 3'd1) begin rd = 1'b1; n_tlo = din; n_pc = pc + 16'd1; end
                    else if (mc == 3'd2) begin
                        rd = 1'b1; n_thi = din; n_pc = pc + 16'd1;
                        if (op[7:6] == 2'b00 && op[3:0] == 4'h1) begin n_mc = 3'd0; n_wb = 1'b1; end  // LD rr,d16
                        else if (op[7:5] == 3'b110 && op[0] == 1'b0 && !cond) begin n_mc = 3'd0; n_wb = 1'b1; end  // JP cc / CALL cc not taken
                    end else begin
                        case (op)
                            8'h08: begin
                                wr = 1'b1;
                                if (mc == 3'd3) begin addr = t16; dout = sp[7:0]; end
                                else begin addr = t16 + 16'd1; dout = sp[15:8]; n_mc = 3'd0; n_wb = 1'b1; end
                            end
                            8'hEA: begin wr = 1'b1; addr = t16; dout = ra; n_mc = 3'd0; n_wb = 1'b1; end
                            8'hFA: begin rd = 1'b1; addr = t16; n_tlo = din; n_mc = 3'd0; n_wb = 1'b1; end
                            8'hC2, 8'hCA, 8'hD2, 8'hDA, 8'hC3: begin n_pc = t16; n_mc = 3'd0; n_wb = 1'b1; end
                            default: ;  // CALL: then the push (s = mc)
                        endcase
                    end
                end
                8'b00??_0010: begin  // LD (BC),A  LD (DE),A  LD (HL+),A  LD (HL-),A
                    wr = 1'b1; dout = ra; n_mc = 3'd0; n_wb = 1'b1;
                    addr = op[5:4] == 2'd0 ? w_bc : op[5:4] == 2'd1 ? w_de : w_hl;
                    if (op[5:4] == 2'd2) {n_h, n_l} = w_hl + 16'd1;
                    if (op[5:4] == 2'd3) {n_h, n_l} = w_hl - 16'd1;
                end
                8'b00??_1010: begin  // LD A,(BC) ... LD A,(HL-)
                    rd = 1'b1; n_tlo = din; n_mc = 3'd0; n_wb = 1'b1;
                    addr = op[5:4] == 2'd0 ? w_bc : op[5:4] == 2'd1 ? w_de : w_hl;
                    if (op[5:4] == 2'd2) {n_h, n_l} = w_hl + 16'd1;
                    if (op[5:4] == 2'd3) {n_h, n_l} = w_hl - 16'd1;
                end
                8'b00??_0011, 8'b00??_1011: begin  // INC rr, DEC rr
                    n_mc = 3'd0; n_wb = 1'b1;
                    addr = rr16;
                    case (op[5:4])
                        2'd0: {n_b, n_c} = op[3] ? w_bc - 16'd1 : w_bc + 16'd1;
                        2'd1: {n_d, n_e} = op[3] ? w_de - 16'd1 : w_de + 16'd1;
                        2'd2: {n_h, n_l} = op[3] ? w_hl - 16'd1 : w_hl + 16'd1;
                        default: n_sp = op[3] ? sp - 16'd1 : sp + 16'd1;
                    endcase
                end
                8'h34, 8'h35: begin  // INC (HL), DEC (HL)
                    addr = w_hl;
                    if (mc == 3'd1) begin rd = 1'b1; n_tlo = din; end
                    else begin
                        wr = 1'b1; dout = op[0] ? tlo - 8'd1 : tlo + 8'd1;
                        n_mc = 3'd0; n_wb = 1'b1;
                    end
                end
                8'b00??_?110: begin  // LD r,d8 and LD (HL),d8
                    if (mc == 3'd1) begin
                        rd = 1'b1; n_tlo = din; n_pc = pc + 16'd1;
                        if (op != 8'h36) begin n_mc = 3'd0; n_wb = 1'b1; end
                    end else begin
                        wr = 1'b1; addr = w_hl; dout = tlo; n_mc = 3'd0; n_wb = 1'b1;
                    end
                end
                8'b00??_1001: begin n_mc = 3'd0; n_wb = 1'b1; end  // ADD HL,rr
                8'h18, 8'b001?_?000: begin  // JR e, JR cc,e
                    if (mc == 3'd1) begin
                        rd = 1'b1; n_tlo = din; n_pc = pc + 16'd1;
                        if (op != 8'h18 && !cond) begin n_mc = 3'd0; n_wb = 1'b1; end
                    end else begin
                        n_pc = pc + {{8{tlo[7]}}, tlo};
                        n_mc = 3'd0; n_wb = 1'b1;
                    end
                end
                8'b01??_?110: begin  // LD r,(HL)
                    rd = 1'b1; addr = w_hl; n_tlo = din; n_mc = 3'd0; n_wb = 1'b1;
                end
                8'b0111_00??, 8'b0111_010?, 8'h77: begin  // LD (HL),r (76 is HALT)
                    wr = 1'b1; addr = w_hl; dout = src; n_mc = 3'd0; n_wb = 1'b1;
                end
                8'b10??_?110: begin  // ALU A,(HL)
                    rd = 1'b1; addr = w_hl; n_tlo = din; n_mc = 3'd0; n_wb = 1'b1;
                end
                8'b11??_?110: begin  // ALU A,d8
                    rd = 1'b1; n_tlo = din; n_pc = pc + 16'd1; n_mc = 3'd0; n_wb = 1'b1;
                end
                8'b110?_?000: begin  // RET cc: a check, then RET's steps
                    if (mc == 3'd1) begin
                        if (!cond) begin n_mc = 3'd0; n_wb = 1'b1; end
                    end else s = mc;
                end
                8'hC9, 8'hD9: s = mc + 3'd1;  // RET, RETI
                8'b11??_0001: begin  // POP
                    rd = 1'b1; addr = sp; n_sp = sp + 16'd1;
                    if (mc == 3'd1) n_tlo = din;
                    else begin n_thi = din; n_mc = 3'd0; n_wb = 1'b1; end
                end
                8'b11??_0101, 8'b11??_?111: s = mc + 3'd2;  // PUSH, RST: the push's steps
                8'hE0, 8'hF0: begin  // LDH (a8),A  LDH A,(a8)
                    if (mc == 3'd1) begin rd = 1'b1; n_tlo = din; n_pc = pc + 16'd1; end
                    else begin
                        addr = {8'hFF, tlo}; n_mc = 3'd0; n_wb = 1'b1;
                        if (op[4]) begin rd = 1'b1; n_tlo = din; end
                        else begin wr = 1'b1; dout = ra; end
                    end
                end
                8'hE2, 8'hF2: begin  // LD (C),A  LD A,(C)
                    addr = {8'hFF, rc}; n_mc = 3'd0; n_wb = 1'b1;
                    if (op[4]) begin rd = 1'b1; n_tlo = din; end
                    else begin wr = 1'b1; dout = ra; end
                end
                8'hE8, 8'hF8: begin  // ADD SP,e  LD HL,SP+e
                    if (mc == 3'd1) begin rd = 1'b1; n_tlo = din; n_pc = pc + 16'd1; end
                    else if (mc == 3'd3 || op == 8'hF8) begin n_mc = 3'd0; n_wb = 1'b1; end
                end
                8'hF9: begin n_sp = w_hl; n_mc = 3'd0; n_wb = 1'b1; end  // LD SP,HL
                default: begin n_mc = 3'd0; n_wb = 1'b1; end
            endcase

            // RET's steps (s 2-4) and the push's (s 3-5): CALL, PUSH and RST share it.
            if (op == 8'hC9 || op == 8'hD9 || op[7:5] == 3'b110 && op[2:0] == 3'b000) begin
                if (s == 3'd2) begin rd = 1'b1; addr = sp; n_tlo = din; n_sp = sp + 16'd1; end
                else if (s == 3'd3) begin rd = 1'b1; addr = sp; n_thi = din; n_sp = sp + 16'd1; end
                else if (s == 3'd4) begin
                    n_pc = t16; n_mc = 3'd0; n_wb = 1'b1;
                    if (op == 8'hD9) n_ime = 1'b1;
                end
            end else if (op == 8'hCD || op[7:5] == 3'b110 && op[2:0] == 3'b100
                      || op[7:6] == 2'b11 && op[3:0] == 4'h5 || op[7:6] == 2'b11 && op[2:0] == 3'b111) begin
                if (s == 3'd3) begin addr = sp; n_sp = sp - 16'd1; end
                else if (s == 3'd4) begin
                    wr = 1'b1; addr = sp;
                    n_sp = sp - 16'd1;
                    if (op[3:0] == 4'h5)  // PUSH
                        case (op[5:4])
                            2'd0: dout = rb;
                            2'd1: dout = rd_;
                            2'd2: dout = rh;
                            default: dout = ra;
                        endcase
                    else dout = pc[15:8];
                end else if (s == 3'd5) begin
                    wr = 1'b1; addr = sp;
                    if (op[3:0] == 4'h5)
                        case (op[5:4])
                            2'd0: dout = rc;
                            2'd1: dout = re;
                            2'd2: dout = rl;
                            default: dout = {rf, 4'h0};
                        endcase
                    else dout = pc[7:0];
                    n_mc = 3'd0; n_wb = 1'b1;
                    if (op[2:0] == 3'b111) n_pc = {10'd0, op[5:3], 3'd0};  // RST
                    else if (op[3:0] != 4'h5) n_pc = t16;                    // CALL
                end
            end
        end

    end

    // -------------------------------------------------------------- registers

    always_ff @(posedge clk) begin
        if (rst) begin
            {ra, rb, rc, rd_, re, rh, rl} <= '0;
            rf <= 4'd0; sp <= 16'd0; pc <= 16'd0;
            op <= 8'd0; cb <= 1'b0; mc <= 3'd0; wb <= 1'b0; tlo <= 8'd0; thi <= 8'd0;
            ime <= 1'b0; halt_r <= 1'b0; stop_r <= 1'b0; lock_r <= 1'b0; disp <= 1'b0;
        end else if (ce) begin
            ra <= n_a; rb <= n_b; rc <= n_c; rd_ <= n_d; re <= n_e; rh <= n_h; rl <= n_l; rf <= n_f;
            sp <= n_sp; pc <= n_pc;
            op <= n_op; cb <= n_cb; mc <= n_mc; wb <= n_wb; tlo <= n_tlo; thi <= n_thi;
            ime <= n_ime; halt_r <= n_halt; stop_r <= n_stop; lock_r <= n_lock; disp <= n_disp;
        end else if (SAVE_STATE && st_we) begin
            case (st_addr)
                2'd0: {ra, rb, rc, rd_} <= st_wdata;
                2'd1: {re, rh, rl, rf, mc, cb} <= st_wdata;
                2'd2: {sp, pc} <= st_wdata;
                default: {op, tlo, thi, wb, ime, halt_r, stop_r, lock_r, disp} <= st_wdata[31:2];
            endcase
        end
    end

    always_ff @(posedge clk) begin
        case (st_addr)
            2'd0: st_rdata <= {ra, rb, rc, rd_};
            2'd1: st_rdata <= {re, rh, rl, rf, mc, cb};
            2'd2: st_rdata <= {sp, pc};
            default: st_rdata <= {op, tlo, thi, wb, ime, halt_r, stop_r, lock_r, disp, 2'b00};
        endcase
        if (!SAVE_STATE)
            st_rdata <= '0;
    end

    assign halted  = halt_r;
    assign stopped = stop_r;
    assign locked  = lock_r;
    assign dbg_pc  = w_pc;
    assign dbg_sp  = w_sp;
    assign dbg_af  = {w_a, w_f, 4'h0};
    assign dbg_bc  = {w_b, w_c};
    assign dbg_de  = {w_d, w_e};
    assign dbg_hl  = {w_h, w_l};
    assign dbg_ime = eff_ime;
    assign dbg_ei  = wb && !cb && op == 8'hFB;
    assign dbg_boundary = boundary;

endmodule
