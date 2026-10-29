// SPDX-License-Identifier: Apache-2.0
// NMOS 6502 CPU, cycle-exact on the bus: one access per CPU cycle, including
// the dummy reads and writes of the original, so memory-mapped hardware sees
// what it would on the real chip. DECIMAL = 1 gives the NMOS decimal mode
// (including its flag quirks); the NES's 2A03 has none, so it uses
// DECIMAL = 0, where ADC and SBC are binary whatever D says.
//
// Bus timing: the CPU advances one cycle on each clock with `ce` high. During a
// cycle, addr/we/dout describe its access (combinationally from CPU state); a
// read's data must be on `din` by the clock edge that ends the cycle, and a
// write takes effect on that edge.
//
// Covers every official opcode and the stable unofficial ones (LAX, SAX, DCP,
// ISC, SLO, RLA, SRE, RRA, ANC, ALR, ARR, AXS, SBC $EB, the NOPs). JAM opcodes
// and the unstable ones (XAA, LAX #imm, AHX, SHX, SHY, TAS, LAS) stop the CPU
// with `halted` set until reset.
//
// Save state (docs/conventions.md): four words, readable and writable while
// ce is low, mid-instruction included.
//   0: A, X, Y, S (A in bits 31-24)
//   1: PC, then the internal address register
//   2: opcode, data latch, base address low, then N V D I Z C, page-cross, RMW carry
//   3: bits 1-0 phase, 4-2 cycle, 6-5 interrupt source, then interrupt go and
//      snapshot, IRQ and NMI samples, NMI pending, NMI vector
module cpu_6502 #(
    parameter bit DECIMAL    = 1'b1,  // 0 for the NES's 2A03
    parameter bit SAVE_STATE = 1'b1   // 0 leaves out the save-state port's logic: writes do nothing, reads give 0
) (
    input  logic        clk,
    input  logic        rst,      // synchronous; the CPU runs its reset sequence after it falls
    input  logic        ce,       // one CPU cycle per clock with ce high

    output logic [15:0] addr,
    output logic        we,       // this cycle writes dout to addr
    output logic [7:0]  dout,
    input  logic [7:0]  din,
    input  logic        rdy,      // low stalls the CPU on a read cycle (writes always complete)

    input  logic        irq_n,    // level-sensitive, active low
    input  logic        nmi_n,    // edge-sensitive, active low

    output logic        sync,     // this cycle fetches an opcode
    output logic        halted,   // a JAM or unsupported opcode stopped the CPU

    // Registers, for traces and debugging; P as pushed by PHP but with B clear.
    output logic [15:0] dbg_pc,
    output logic [7:0]  dbg_a,
    output logic [7:0]  dbg_x,
    output logic [7:0]  dbg_y,
    output logic [7:0]  dbg_s,
    output logic [7:0]  dbg_p,

    // Save-state port.
    input  logic [1:0]  st_addr,
    output logic [31:0] st_rdata,  // word st_addr, the clock after
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    // ---- Decoding ----
    typedef enum logic [4:0] {
        M_IMP, M_IMM, M_ZP, M_ZPX, M_ZPY, M_ABS, M_ABX, M_ABY, M_IZX, M_IZY,
        M_REL, M_JMP, M_JMPI, M_JSR, M_RTS, M_RTI, M_BRK, M_PUSH, M_PULL, M_HALT
    } mode_t;

    typedef enum logic [1:0] {K_READ, K_WRITE, K_RMW} kind_t;

    typedef enum logic [5:0] {
        A_NONE,   // RMW without a second step: flags from the result
        A_LDA, A_LDX, A_LDY, A_LAX, A_AND, A_ORA, A_EOR, A_ADC, A_SBC,
        A_CMP, A_CPX, A_CPY, A_BIT, A_NOP, A_ANC, A_ALR, A_ARR, A_AXS,
        A_STA, A_STX, A_STY, A_SAX,
        A_TAX, A_TAY, A_TXA, A_TYA, A_TSX, A_TXS, A_INX, A_INY, A_DEX, A_DEY,
        A_CLC, A_SEC, A_CLI, A_SEI, A_CLV, A_CLD, A_SED, A_ACC,
        A_PHA, A_PHP, A_PLA, A_PLP
    } alu_t;

    typedef enum logic [2:0] {R_NONE, R_ASL, R_LSR, R_ROL, R_ROR, R_INC, R_DEC} rmw_t;

    mode_t d_mode;
    kind_t d_kind;
    alu_t  d_alu;
    rmw_t  d_rmw;
    logic [7:0] ir;

    // The ALU and read-modify-write groups share a layout: bits 7-5 pick the
    // operation, bits 4-2 the addressing mode.
    function automatic mode_t group_mode(input logic [2:0] bbb);
        case (bbb)
            3'd0:    group_mode = M_IZX;
            3'd1:    group_mode = M_ZP;
            3'd2:    group_mode = M_IMM;
            3'd3:    group_mode = M_ABS;
            3'd4:    group_mode = M_IZY;
            3'd5:    group_mode = M_ZPX;
            3'd6:    group_mode = M_ABY;
            default: group_mode = M_ABX;
        endcase
    endfunction

    always_comb begin
        d_mode = M_HALT;
        d_kind = K_READ;
        d_alu  = A_NOP;
        d_rmw  = R_NONE;
        case (ir[1:0])
            2'b01: begin  // ORA AND EOR ADC STA LDA CMP SBC
                d_mode = group_mode(ir[4:2]);
                case (ir[7:5])
                    3'd0: d_alu = A_ORA;
                    3'd1: d_alu = A_AND;
                    3'd2: d_alu = A_EOR;
                    3'd3: d_alu = A_ADC;
                    3'd4: begin d_alu = A_STA; d_kind = K_WRITE; end
                    3'd5: d_alu = A_LDA;
                    3'd6: d_alu = A_CMP;
                    default: d_alu = A_SBC;
                endcase
                if (ir == 8'h89) begin  // STA #imm doesn't exist: a two-byte NOP
                    d_alu  = A_NOP;
                    d_kind = K_READ;
                end
            end
            2'b11: begin  // unofficial: the 01 and 10 groups combined
                d_mode = group_mode(ir[4:2]);
                case (ir[7:5])
                    3'd0: begin d_kind = K_RMW; d_rmw = R_ASL; d_alu = A_ORA; end  // SLO
                    3'd1: begin d_kind = K_RMW; d_rmw = R_ROL; d_alu = A_AND; end  // RLA
                    3'd2: begin d_kind = K_RMW; d_rmw = R_LSR; d_alu = A_EOR; end  // SRE
                    3'd3: begin d_kind = K_RMW; d_rmw = R_ROR; d_alu = A_ADC; end  // RRA
                    3'd4: begin d_kind = K_WRITE; d_alu = A_SAX; end
                    3'd5: d_alu = A_LAX;
                    3'd6: begin d_kind = K_RMW; d_rmw = R_DEC; d_alu = A_CMP; end  // DCP
                    default: begin d_kind = K_RMW; d_rmw = R_INC; d_alu = A_SBC; end  // ISC
                endcase
                if (ir[7:6] == 2'b10 && ir[4:2] == 3'd5) d_mode = M_ZPY;  // SAX, LAX zp,Y
                if (ir[7:6] == 2'b10 && ir[4:2] == 3'd7) d_mode = M_ABY;  // AHX, LAX abs,Y
                if (ir[4:2] == 3'd2) begin  // the #imm column
                    d_kind = K_READ;
                    d_rmw  = R_NONE;
                    case (ir[7:5])
                        3'd0, 3'd1: d_alu = A_ANC;
                        3'd2:       d_alu = A_ALR;
                        3'd3:       d_alu = A_ARR;
                        3'd6:       d_alu = A_AXS;
                        3'd7:       d_alu = A_SBC;
                        default:    d_mode = M_HALT;  // XAA, LAX #imm: unstable
                    endcase
                end
                // AHX, TAS, LAS: unstable
                if (ir == 8'h93 || ir == 8'h9F || ir == 8'h9B || ir == 8'hBB) d_mode = M_HALT;
            end
            2'b10: begin  // ASL ROL LSR ROR STX LDX DEC INC, transfers, NOPs
                case (ir[7:5])
                    3'd0: begin d_kind = K_RMW; d_rmw = R_ASL; d_alu = A_NONE; end
                    3'd1: begin d_kind = K_RMW; d_rmw = R_ROL; d_alu = A_NONE; end
                    3'd2: begin d_kind = K_RMW; d_rmw = R_LSR; d_alu = A_NONE; end
                    3'd3: begin d_kind = K_RMW; d_rmw = R_ROR; d_alu = A_NONE; end
                    3'd4: begin d_kind = K_WRITE; d_alu = A_STX; end
                    3'd5: d_alu = A_LDX;
                    3'd6: begin d_kind = K_RMW; d_rmw = R_DEC; d_alu = A_NONE; end
                    default: begin d_kind = K_RMW; d_rmw = R_INC; d_alu = A_NONE; end
                endcase
                case (ir[4:2])
                    3'd0:  // #imm: LDX, or NOP #imm; 02/22/42/62 are JAM
                        if (ir[7]) begin
                            d_mode = M_IMM;
                            d_kind = K_READ;
                            d_rmw  = R_NONE;
                            if (ir != 8'hA2) d_alu = A_NOP;
                        end else
                            d_mode = M_HALT;
                    3'd1: d_mode = M_ZP;
                    3'd2: begin
                        d_mode = M_IMP;
                        d_kind = K_READ;
                        case (ir[7:5])
                            3'd0, 3'd1, 3'd2, 3'd3: d_alu = A_ACC;  // ASL A, ROL A, LSR A, ROR A
                            3'd4:    begin d_alu = A_TXA; d_rmw = R_NONE; end
                            3'd5:    begin d_alu = A_TAX; d_rmw = R_NONE; end
                            3'd6:    begin d_alu = A_DEX; d_rmw = R_NONE; end
                            default: begin d_alu = A_NOP; d_rmw = R_NONE; end
                        endcase
                    end
                    3'd3: d_mode = M_ABS;
                    3'd4: d_mode = M_HALT;  // x2 JAMs
                    3'd5: d_mode = ir[7:6] == 2'b10 ? M_ZPY : M_ZPX;  // STX/LDX use Y
                    3'd6: begin
                        d_mode = M_IMP;
                        d_kind = K_READ;
                        d_rmw  = R_NONE;
                        d_alu  = ir == 8'h9A ? A_TXS : ir == 8'hBA ? A_TSX : A_NOP;
                    end
                    default:
                        if (ir == 8'h9E)
                            d_mode = M_HALT;  // SHX: unstable
                        else
                            d_mode = ir == 8'hBE ? M_ABY : M_ABX;
                endcase
            end
            default: begin  // 2'b00: control, BIT, LDY/STY/CPY/CPX, NOPs
                case (ir[4:2])
                    3'd0:
                        case (ir[7:5])
                            3'd0: d_mode = M_BRK;
                            3'd1: d_mode = M_JSR;
                            3'd2: begin d_mode = M_RTI; d_alu = A_PLP; end
                            3'd3: d_mode = M_RTS;
                            3'd4: begin d_mode = M_IMM; d_alu = A_NOP; end
                            3'd5: begin d_mode = M_IMM; d_alu = A_LDY; end
                            3'd6: begin d_mode = M_IMM; d_alu = A_CPY; end
                            default: begin d_mode = M_IMM; d_alu = A_CPX; end
                        endcase
                    3'd1, 3'd3, 3'd5, 3'd7: begin
                        case (ir[4:2])
                            3'd1:    d_mode = M_ZP;
                            3'd3:    d_mode = M_ABS;
                            3'd5:    d_mode = M_ZPX;
                            default: d_mode = M_ABX;
                        endcase
                        case (ir[7:5])
                            3'd1: d_alu = ir[4] ? A_NOP : A_BIT;  // BIT zp/abs; 34/3C are NOPs
                            3'd4: begin d_alu = A_STY; d_kind = K_WRITE; end
                            3'd5: d_alu = A_LDY;
                            3'd6: d_alu = ir[4] ? A_NOP : A_CPY;
                            3'd7: d_alu = ir[4] ? A_NOP : A_CPX;
                            default: d_alu = A_NOP;
                        endcase
                        if (ir == 8'h4C) d_mode = M_JMP;
                        if (ir == 8'h6C) d_mode = M_JMPI;
                        if (ir == 8'h9C) d_mode = M_HALT;  // SHY: unstable
                        if (ir == 8'h94) d_mode = M_ZPX;   // STY zp,X
                    end
                    3'd2:
                        case (ir[7:5])
                            3'd0: begin d_mode = M_PUSH; d_alu = A_PHP; end
                            3'd1: begin d_mode = M_PULL; d_alu = A_PLP; end
                            3'd2: begin d_mode = M_PUSH; d_alu = A_PHA; end
                            3'd3: begin d_mode = M_PULL; d_alu = A_PLA; end
                            3'd4: begin d_mode = M_IMP; d_alu = A_DEY; end
                            3'd5: begin d_mode = M_IMP; d_alu = A_TAY; end
                            3'd6: begin d_mode = M_IMP; d_alu = A_INY; end
                            default: begin d_mode = M_IMP; d_alu = A_INX; end
                        endcase
                    3'd4: d_mode = M_REL;
                    default: begin  // 3'd6: flag instructions and TYA
                        d_mode = M_IMP;
                        case (ir[7:5])
                            3'd0: d_alu = A_CLC;
                            3'd1: d_alu = A_SEC;
                            3'd2: d_alu = A_CLI;
                            3'd3: d_alu = A_SEI;
                            3'd4: d_alu = A_TYA;
                            3'd5: d_alu = A_CLV;
                            3'd6: d_alu = A_CLD;
                            default: d_alu = A_SED;
                        endcase
                    end
                endcase
            end
        endcase
    end

    // ---- Registers ----
    typedef enum logic [1:0] {P_FETCH, P_ADDR, P_DATA, P_HALT} phase_t;
    typedef enum logic [1:0] {I_NONE, I_IRQ, I_NMI, I_RESET} int_t;

    phase_t      phase;
    logic [2:0]  t;          // cycle within the phase
    logic [15:0] pc, ad;     // ad: effective address, or a vector or branch target
    logic [7:0]  a, x, y, s, dl, bal;
    logic        fn, fv, fd, fi, fz, fc;
    logic        page_x;      // indexing crossed a page
    logic        rc;         // carry out of the read-modify-write step
    int_t        int_src;    // the BRK sequence is serving this interrupt (I_NONE: a BRK)
    logic        int_go;     // run an interrupt sequence instead of the next opcode
    logic        int_snap;   // branches: interrupt state at the end of their first cycle
    logic        irq_r;      // irq_n, sampled every cycle
    logic        nmi_r;      // nmi_n, sampled every cycle
    logic        nmi_pend;   // an NMI edge is waiting to be served
    logic        nmi_vec;    // this BRK sequence is fetching the NMI vector

    wire [7:0] p_reg = {fn, fv, 1'b1, 1'b0, fd, fi, fz, fc};
    wire       int_now = nmi_pend || (irq_r && !fi);

    assign dbg_pc = pc;
    assign dbg_a  = a;
    assign dbg_x  = x;
    assign dbg_y  = y;
    assign dbg_s  = s;
    assign dbg_p  = p_reg;
    assign halted = phase == P_HALT;
    assign sync   = phase == P_FETCH;

    // ---- Read-modify-write unit: {carry, result} ----
    function automatic logic [8:0] rmw_calc(input rmw_t op, input logic [7:0] v, input logic c);
        case (op)
            R_ASL:   rmw_calc = {v[7], v[6:0], 1'b0};
            R_LSR:   rmw_calc = {v[0], 1'b0, v[7:1]};
            R_ROL:   rmw_calc = {v[7], v[6:0], c};
            R_ROR:   rmw_calc = {v[0], c, v[7:1]};
            R_INC:   rmw_calc = {c, v + 8'd1};
            R_DEC:   rmw_calc = {c, v - 8'd1};
            default: rmw_calc = {c, v};
        endcase
    endfunction

    // ---- ALU: the effect of executing d_alu with operand m and carry cin ----
    logic [7:0] m;
    logic       cin;
    logic [7:0] e_a, e_x, e_y, e_s;
    logic       e_n, e_v, e_d, e_i, e_z, e_c;

    always_comb begin
        logic [8:0] sum, acc;
        logic [7:0] t8;
        logic [4:0] dlo;         // decimal ADC: the low digit
        logic [5:0] slo;         // decimal SBC: the low digit, signed
        logic [9:0] dsig, dsum;  // decimal: the whole result, signed and unsigned
        e_a = a; e_x = x; e_y = y; e_s = s;
        e_n = fn; e_v = fv; e_d = fd; e_i = fi; e_z = fz; e_c = cin;
        sum  = '0;
        acc  = '0;
        t8   = '0;
        dlo  = '0;
        slo  = '0;
        dsig = '0;
        dsum = '0;
        case (d_alu)
            A_NONE: begin e_n = m[7]; e_z = m == '0; end
            A_LDA:  begin e_a = m; e_n = m[7]; e_z = m == '0; end
            A_LDX:  begin e_x = m; e_n = m[7]; e_z = m == '0; end
            A_LDY:  begin e_y = m; e_n = m[7]; e_z = m == '0; end
            A_LAX:  begin e_a = m; e_x = m; e_n = m[7]; e_z = m == '0; end
            A_AND:  begin e_a = a & m; e_n = e_a[7]; e_z = e_a == '0; end
            A_ORA:  begin e_a = a | m; e_n = e_a[7]; e_z = e_a == '0; end
            A_EOR:  begin e_a = a ^ m; e_n = e_a[7]; e_z = e_a == '0; end
            A_ADC, A_SBC: begin
                t8  = d_alu == A_SBC ? ~m : m;
                sum = {1'b0, a} + {1'b0, t8} + {8'b0, cin};
                e_a = sum[7:0];
                e_c = sum[8];
                e_v = (~(a[7] ^ t8[7])) & (a[7] ^ sum[7]);
                e_n = sum[7];
                e_z = sum[7:0] == '0;
                // NMOS decimal mode. ADC: N and V from the sum after the low
                // digit's adjustment, Z from the binary sum. SBC: every flag from
                // the binary result; only the accumulator is adjusted.
                if (DECIMAL && fd) begin
                    if (d_alu == A_ADC) begin
                        dlo = {1'b0, a[3:0]} + {1'b0, m[3:0]} + {4'b0, cin};
                        if (dlo >= 5'd10)
                            dlo = ((dlo + 5'd6) & 5'h0F) + 5'h10;
                        // Signed for N and V, unsigned for the result and C.
                        dsig = {{2{a[7]}}, a[7:4], 4'b0} + {{2{m[7]}}, m[7:4], 4'b0} + {5'b0, dlo};
                        e_n = dsig[7];
                        e_v = $signed(dsig) < -10'sd128 || $signed(dsig) > 10'sd127;
                        dsum = {2'b0, a[7:4], 4'b0} + {2'b0, m[7:4], 4'b0} + {5'b0, dlo};
                        if (dsum >= 10'h0A0)
                            dsum = dsum + 10'h060;
                        e_a = dsum[7:0];
                        e_c = dsum >= 10'h100;
                    end else begin
                        slo = {2'b0, a[3:0]} - {2'b0, m[3:0]} + {5'b0, cin} - 6'd1;
                        if (slo[5])  // negative
                            slo = ((slo - 6'd6) & 6'h0F) - 6'h10;
                        dsum = {2'b0, a[7:4], 4'b0} - {2'b0, m[7:4], 4'b0} + {{4{slo[5]}}, slo};
                        if (dsum[9])  // negative
                            dsum = dsum - 10'h060;
                        e_a = dsum[7:0];
                    end
                end
            end
            A_CMP, A_CPX, A_CPY, A_AXS: begin
                case (d_alu)
                    A_CPX:   t8 = x;
                    A_CPY:   t8 = y;
                    A_AXS:   t8 = a & x;
                    default: t8 = a;
                endcase
                sum = {1'b0, t8} - {1'b0, m};
                e_c = !sum[8];
                e_n = sum[7];
                e_z = sum[7:0] == '0;
                if (d_alu == A_AXS) e_x = sum[7:0];
            end
            A_BIT:  begin e_n = m[7]; e_v = m[6]; e_z = (a & m) == '0; end
            A_ANC:  begin e_a = a & m; e_n = e_a[7]; e_z = e_a == '0; e_c = e_a[7]; end
            A_ALR: begin
                t8  = a & m;
                e_c = t8[0];
                e_a = {1'b0, t8[7:1]};
                e_n = 1'b0;
                e_z = e_a == '0;
            end
            A_ARR: begin
                t8  = a & m;
                e_a = {cin, t8[7:1]};
                e_n = e_a[7];
                e_z = e_a == '0;
                e_c = e_a[6];
                e_v = e_a[6] ^ e_a[5];
            end
            A_TAX:  begin e_x = a; e_n = a[7]; e_z = a == '0; end
            A_TAY:  begin e_y = a; e_n = a[7]; e_z = a == '0; end
            A_TXA:  begin e_a = x; e_n = x[7]; e_z = x == '0; end
            A_TYA:  begin e_a = y; e_n = y[7]; e_z = y == '0; end
            A_TSX:  begin e_x = s; e_n = s[7]; e_z = s == '0; end
            A_TXS:  e_s = x;
            A_INX:  begin e_x = x + 8'd1; e_n = e_x[7]; e_z = e_x == '0; end
            A_INY:  begin e_y = y + 8'd1; e_n = e_y[7]; e_z = e_y == '0; end
            A_DEX:  begin e_x = x - 8'd1; e_n = e_x[7]; e_z = e_x == '0; end
            A_DEY:  begin e_y = y - 8'd1; e_n = e_y[7]; e_z = e_y == '0; end
            A_CLC:  e_c = 1'b0;
            A_SEC:  e_c = 1'b1;
            A_CLI:  e_i = 1'b0;
            A_SEI:  e_i = 1'b1;
            A_CLV:  e_v = 1'b0;
            A_CLD:  e_d = 1'b0;
            A_SED:  e_d = 1'b1;
            A_ACC: begin
                acc = rmw_calc(d_rmw, a, fc);
                e_a = acc[7:0];
                e_c = acc[8];
                e_n = acc[7];
                e_z = acc[7:0] == '0;
            end
            A_PLA:  begin e_a = m; e_n = m[7]; e_z = m == '0; end
            A_PLP:  begin e_n = m[7]; e_v = m[6]; e_d = m[3]; e_i = m[2]; e_z = m[1]; e_c = m[0]; end
            default: ;  // NOP, stores, pushes: no register effect
        endcase
    end

    // What a write instruction stores.
    logic [7:0] store_val;
    always_comb
        case (d_alu)
            A_STX:   store_val = x;
            A_STY:   store_val = y;
            A_SAX:   store_val = a & x;
            default: store_val = a;
        endcase

    // Branch condition: bits 7-6 pick N, V, C or Z; bit 5 is the value that takes it.
    logic taken;
    always_comb
        case (ir[7:6])
            2'd0:    taken = fn == ir[5];
            2'd1:    taken = fv == ir[5];
            2'd2:    taken = fc == ir[5];
            default: taken = fz == ir[5];
        endcase

    wire [7:0]  idx    = d_mode == M_ZPY || d_mode == M_ABY || d_mode == M_IZY ? y : x;
    wire [8:0]  lo_sum = {1'b0, ad[7:0]} + {1'b0, idx};             // indexed low byte
    wire [15:0] target = pc + {{8{dl[7]}}, dl};                     // branch target
    wire [15:0] stack  = {8'h01, s};

    // ---- Cycle sequencer ----
    phase_t      n_phase;
    logic [2:0]  n_t;
    logic [15:0] n_pc, n_ad;
    logic [7:0]  n_s, n_dl, n_bal;
    logic        n_page_x, n_rc, n_int_go, n_int_snap, n_fi;
    int_t        n_int_src;
    logic        exec;       // apply the ALU's results at the end of this cycle
    logic        last;       // this is the instruction's last cycle
    logic        use_snap;   // a taken branch: decide interrupts from int_snap
    logic        n_nmi_vec;
    logic        nmi_done;   // the end of a sequence that served an NMI
    logic        no_poll;    // the end of an interrupt sequence: run one handler instruction first

    always_comb begin
        addr = pc;
        we   = 1'b0;
        dout = 8'h00;
        m    = din;
        cin  = fc;
        n_phase = phase;
        n_t = t + 3'd1;
        n_pc = pc;
        n_ad = ad;
        n_s = s;
        n_dl = dl;
        n_bal = bal;
        n_page_x = page_x;
        n_rc = rc;
        n_int_src = int_src;
        n_int_snap = int_snap;
        n_fi = fi;
        exec = 1'b0;
        last = 1'b0;
        use_snap = 1'b0;
        n_nmi_vec = nmi_vec;
        nmi_done = 1'b0;
        no_poll = 1'b0;

        // Data phase, shared by every memory addressing mode.
        // READ: t0 read. WRITE: t0 write. RMW: t0 read, t1 write back, t2 write.
        if (phase == P_DATA) begin
            addr = ad;
            case (d_kind)
                K_READ: begin exec = 1'b1; last = 1'b1; end
                K_WRITE: begin we = 1'b1; dout = store_val; last = 1'b1; end
                default:
                    case (t)
                        3'd0: n_dl = din;
                        3'd1: begin
                            we = 1'b1;
                            dout = dl;  // the original writes the unmodified value back first
                            {n_rc, n_dl} = rmw_calc(d_rmw, dl, fc);
                        end
                        default: begin
                            we = 1'b1;
                            dout = dl;
                            m = dl;
                            cin = rc;
                            exec = 1'b1;
                            last = 1'b1;
                        end
                    endcase
            endcase
        end else if (phase == P_FETCH) begin
            n_phase = P_ADDR;
            n_t = 3'd1;
        end else if (phase == P_ADDR) begin
            case (d_mode)
                M_IMP: begin exec = 1'b1; last = 1'b1; end  // dummy read of the next byte
                M_IMM: begin n_pc = pc + 16'd1; exec = 1'b1; last = 1'b1; end
                M_ZP: begin
                    n_ad = {8'h00, din};
                    n_pc = pc + 16'd1;
                    n_phase = P_DATA;
                    n_t = 3'd0;
                end
                M_ZPX, M_ZPY:
                    if (t == 3'd1) begin
                        n_ad = {8'h00, din};
                        n_pc = pc + 16'd1;
                    end else begin
                        addr = ad;  // dummy read before indexing
                        n_ad = {8'h00, lo_sum[7:0]};
                        n_phase = P_DATA;
                        n_t = 3'd0;
                    end
                M_ABS:
                    if (t == 3'd1) begin
                        n_ad[7:0] = din;
                        n_pc = pc + 16'd1;
                    end else begin
                        n_ad[15:8] = din;
                        n_pc = pc + 16'd1;
                        n_phase = P_DATA;
                        n_t = 3'd0;
                    end
                M_ABX, M_ABY, M_IZX, M_IZY: begin
                    // Steps to the effective address; `step` lines (zp,X) and (zp),Y up with abs,X.
                    case ({d_mode == M_IZX || d_mode == M_IZY, t})
                        // abs,X / abs,Y
                        4'b0_001: begin n_ad[7:0] = din; n_pc = pc + 16'd1; end
                        4'b0_010: begin
                            n_ad = {din, lo_sum[7:0]};
                            n_page_x = lo_sum[8];
                            n_pc = pc + 16'd1;
                        end
                        // (zp,X): t1 pointer, t2 dummy read and add X, t3/t4 address
                        // (zp),Y: t1 pointer, t2/t3 address and add Y
                        4'b1_001: begin n_bal = din; n_pc = pc + 16'd1; end
                        4'b1_010:
                            if (d_mode == M_IZX) begin
                                addr = {8'h00, bal};
                                n_bal = bal + x;
                            end else begin
                                addr = {8'h00, bal};
                                n_ad[7:0] = din;
                            end
                        4'b1_011:
                            if (d_mode == M_IZX) begin
                                addr = {8'h00, bal};
                                n_ad[7:0] = din;
                            end else begin
                                addr = {8'h00, bal + 8'd1};
                                n_ad = {din, lo_sum[7:0]};
                                n_page_x = lo_sum[8];
                            end
                        4'b1_100:
                            if (d_mode == M_IZX) begin
                                addr = {8'h00, bal + 8'd1};
                                n_ad[15:8] = din;
                                n_phase = P_DATA;
                                n_t = 3'd0;
                            end
                        default: ;
                    endcase
                    // The cycle after the index is added reads from the address
                    // before the carry into the high byte: the real access for a
                    // read that didn't page_x a page, a dummy read otherwise.
                    if ((d_mode != M_IZX) && ((d_mode == M_IZY) ? t == 3'd4 : t == 3'd3)) begin
                        addr = ad;
                        if (d_kind == K_READ && !page_x) begin
                            exec = 1'b1;
                            last = 1'b1;
                        end else begin
                            n_ad[15:8] = ad[15:8] + {7'b0, page_x};
                            n_phase = P_DATA;
                            n_t = 3'd0;
                        end
                    end
                end
                M_REL:
                    case (t)
                        3'd1: begin
                            n_dl = din;
                            n_pc = pc + 16'd1;
                            n_int_snap = int_now;
                            if (!taken) last = 1'b1;
                        end
                        3'd2: begin  // dummy read of the next opcode while adding the offset
                            n_pc = {pc[15:8], target[7:0]};
                            n_ad[15:8] = target[15:8];
                            if (target[15:8] == pc[15:8]) begin
                                last = 1'b1;
                                use_snap = 1'b1;  // no interrupt poll before this cycle
                            end
                        end
                        default: begin  // dummy read from the wrong page while fixing it
                            n_pc[15:8] = ad[15:8];
                            last = 1'b1;
                        end
                    endcase
                M_JMP:
                    if (t == 3'd1) begin
                        n_ad[7:0] = din;
                        n_pc = pc + 16'd1;
                    end else begin
                        n_pc = {din, ad[7:0]};
                        last = 1'b1;
                    end
                M_JMPI:
                    case (t)
                        3'd1: begin n_ad[7:0] = din; n_pc = pc + 16'd1; end
                        3'd2: begin n_ad[15:8] = din; n_pc = pc + 16'd1; end
                        3'd3: begin addr = ad; n_dl = din; end
                        default: begin
                            addr = {ad[15:8], ad[7:0] + 8'd1};  // the pointer doesn't carry into its high byte
                            n_pc = {din, dl};
                            last = 1'b1;
                        end
                    endcase
                M_JSR:
                    case (t)
                        3'd1: begin n_dl = din; n_pc = pc + 16'd1; end
                        3'd2: addr = stack;  // dummy read
                        3'd3: begin addr = stack; we = 1'b1; dout = pc[15:8]; n_s = s - 8'd1; end
                        3'd4: begin addr = stack; we = 1'b1; dout = pc[7:0]; n_s = s - 8'd1; end
                        default: begin n_pc = {din, dl}; last = 1'b1; end
                    endcase
                M_RTS:
                    case (t)
                        3'd1: ;  // dummy read
                        3'd2: begin addr = stack; n_s = s + 8'd1; end
                        3'd3: begin addr = stack; n_pc[7:0] = din; n_s = s + 8'd1; end
                        3'd4: begin addr = stack; n_pc[15:8] = din; end
                        default: begin n_pc = pc + 16'd1; last = 1'b1; end
                    endcase
                M_RTI:
                    case (t)
                        3'd1: ;
                        3'd2: begin addr = stack; n_s = s + 8'd1; end
                        3'd3: begin addr = stack; m = din; exec = 1'b1; n_s = s + 8'd1; end  // P
                        3'd4: begin addr = stack; n_pc[7:0] = din; n_s = s + 8'd1; end
                        default: begin addr = stack; n_pc[15:8] = din; last = 1'b1; end
                    endcase
                M_PUSH:
                    if (t == 3'd2) begin
                        addr = stack;
                        we = 1'b1;
                        dout = d_alu == A_PHA ? a : p_reg | 8'h30;
                        n_s = s - 8'd1;
                        last = 1'b1;
                    end
                M_PULL:
                    case (t)
                        3'd1: ;
                        3'd2: begin addr = stack; n_s = s + 8'd1; end
                        default: begin addr = stack; exec = 1'b1; last = 1'b1; end
                    endcase
                M_BRK:
                    case (t)
                        3'd1: if (int_src == I_NONE) n_pc = pc + 16'd1;  // BRK skips its padding byte
                        3'd2, 3'd3, 3'd4: begin
                            addr = stack;
                            we = int_src != I_RESET;  // reset goes through the motions, reading
                            dout = t == 3'd2 ? pc[15:8] : t == 3'd3 ? pc[7:0]
                                 : p_reg | {3'b001, int_src == I_NONE, 4'b0000};
                            n_s = s - 8'd1;
                            if (t == 3'd4) begin
                                // An NMI arriving by now takes over the vector.
                                n_nmi_vec = int_src != I_RESET && nmi_pend;
                                n_ad = int_src == I_RESET ? 16'hFFFC : nmi_pend ? 16'hFFFA : 16'hFFFE;
                            end
                        end
                        3'd5: begin addr = ad; n_dl = din; n_fi = 1'b1; end
                        default: begin
                            addr = {ad[15:8], ad[7:0] + 8'd1};
                            n_pc = {din, dl};
                            n_int_src = I_NONE;
                            n_nmi_vec = 1'b0;
                            nmi_done = nmi_vec;
                            last = 1'b1;
                            no_poll = 1'b1;
                        end
                    endcase
                default: ;  // M_HALT is caught when the opcode arrives
            endcase
        end else begin  // P_HALT
            addr = 16'hFFFF;
            n_t = t;
        end

        if (last) begin
            n_phase = P_FETCH;
            n_t = 3'd0;
        end
        // Interrupts are polled before an instruction's last cycle: the state
        // registered at the end of the cycle before this one decides.
        n_int_go = last ? !no_poll && (use_snap ? int_snap : int_now) : int_go;
    end

    // ---- State ----
    always_ff @(posedge clk) begin
        if (ce) begin
            irq_r <= !irq_n;
            nmi_r <= !nmi_n;
            // An NMI is served only at the end of its sequence: edges up to
            // then merge into it, and one seen on that last edge waits.
            if (nmi_done && (rdy || we))
                nmi_pend <= 1'b0;
            if (!nmi_n && !nmi_r)
                nmi_pend <= 1'b1;
        end

        if (ce && (rdy || we)) begin
            phase    <= n_phase;
            t        <= n_t;
            pc       <= n_pc;
            ad       <= n_ad;
            s        <= n_s;
            dl       <= n_dl;
            bal      <= n_bal;
            page_x    <= n_page_x;
            rc       <= n_rc;
            int_snap <= n_int_snap;
            int_src  <= n_int_src;
            int_go   <= n_int_go;
            fi       <= n_fi;
            nmi_vec  <= n_nmi_vec;

            if (phase == P_FETCH) begin
                if (int_go) begin
                    // An interrupt: the fetched opcode is dropped and the PC
                    // stays, then the BRK sequence runs.
                    ir <= 8'h00;
                    if (int_src == I_NONE)
                        int_src <= nmi_pend ? I_NMI : I_IRQ;
                    int_go <= 1'b0;
                end else begin
                    ir <= din;
                    pc <= pc + 16'd1;
                end
            end

            // An opcode that can't run stops the CPU: decode it as soon as it's in ir.
            if (phase == P_ADDR && t == 3'd1 && d_mode == M_HALT)
                phase <= P_HALT;

            if (exec) begin
                a  <= e_a;
                x  <= e_x;
                y  <= e_y;
                fn <= e_n;
                fv <= e_v;
                fd <= e_d;
                fz <= e_z;
                fc <= e_c;
                fi <= e_i;
                if (d_alu == A_TXS)
                    s <= e_s;
            end
        end

        if (SAVE_STATE && st_we)
            case (st_addr)
                2'd0: {a, x, y, s} <= st_wdata;
                2'd1: {pc, ad} <= st_wdata;
                2'd2: {ir, dl, bal, fn, fv, fd, fi, fz, fc, page_x, rc} <= st_wdata;
                default: begin
                    phase    <= phase_t'(st_wdata[1:0]);
                    t        <= st_wdata[4:2];
                    int_src  <= int_t'(st_wdata[6:5]);
                    {nmi_vec, nmi_pend, nmi_r, irq_r, int_snap, int_go} <= st_wdata[12:7];
                end
            endcase

        if (rst) begin
            phase    <= P_FETCH;
            t        <= '0;
            int_go   <= 1'b1;
            int_src  <= I_RESET;
            s        <= 8'h00;  // three dummy pushes later: $FD, as on a powered-up NES
            a        <= '0;
            x        <= '0;
            y        <= '0;
            {fn, fv, fd, fi, fz, fc} <= 6'b000100;
            pc       <= '0;
            ir       <= '0;
            irq_r    <= 1'b0;
            nmi_r    <= 1'b0;
            nmi_pend <= 1'b0;
            nmi_vec  <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        case (st_addr)
            2'd0:    st_rdata <= {a, x, y, s};
            2'd1:    st_rdata <= {pc, ad};
            2'd2:    st_rdata <= {ir, dl, bal, fn, fv, fd, fi, fz, fc, page_x, rc};
            default: st_rdata <= {19'b0, nmi_vec, nmi_pend, nmi_r, irq_r, int_snap, int_go, int_src, t, phase};
        endcase
        if (!SAVE_STATE)
            st_rdata <= '0;
    end
endmodule
