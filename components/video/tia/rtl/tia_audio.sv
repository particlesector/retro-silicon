// SPDX-License-Identifier: Apache-2.0
// One of the TIA's two sound channels, as Stella 7.0 runs it.
//
// A 5-bit divider counts the TIA's audio clocks up to AUDF (`div`); each time it reaches it, the
// channel steps its two shift registers, a 4-bit pulse counter and a 5-bit noise counter, whose
// feedback and holds AUDC picks. The TIA clocks the channel twice a line in two phases: `phase0`
// (colour clocks 9 and 81 of its audio counter) runs the divider and works out the noise counter's
// feedback and whether the pulse counter holds; `phase1` (37 and 149) shifts both counters. The output
// (`level`) is AUDV while the pulse counter's bit 0 is set, else 0.
//
// Writes land on the edge after their colour clock (`w_audc`, `w_audf`, `w_audv`, with `din`), after
// that colour clock's phase.

module tia_audio (
    input  logic       clk,
    input  logic       rst,
    input  logic       cc,
    input  logic       phase0,
    input  logic       phase1,
    input  logic       w_audc,
    input  logic       w_audf,
    input  logic       w_audv,
    input  logic [4:0] din,

    output logic [3:0] level,

    // Save state: one word, written while `cc` is low.
    input  logic        st_we,
    input  logic [31:0] st_wdata,
    output logic [31:0] st_word
);

    logic [3:0] audc, audv;
    logic [4:0] audf;
    logic       clk_en;      // the divider reached AUDF at the last phase 0
    logic       noise_fb;    // the noise counter's next bit 4
    logic       noise_b0;    // the noise counter's bit 0, at the last phase 0
    logic       hold;        // the pulse counter holds at the next phase 1
    logic [4:0] div;
    logic [3:0] pulse;
    logic [4:0] noise;

    assign level = pulse[0] ? audv : 4'd0;

    always_ff @(posedge clk) begin
        if (rst) begin
            audc     <= 4'd0;
            audf     <= 5'd0;
            audv     <= 4'd0;
            clk_en   <= 1'b0;
            noise_fb <= 1'b0;
            noise_b0 <= 1'b0;
            hold     <= 1'b0;
            div      <= 5'd0;
            pulse    <= 4'd0;
            noise    <= 5'd0;
        end else if (cc) begin
            if (phase0) begin
                if (clk_en) begin
                    noise_b0 <= noise[0];
                    case (audc[1:0])
                        2'd2:    hold <= noise[4:1] != 4'd1;
                        2'd3:    hold <= !noise[0];
                        default: hold <= 1'b0;
                    endcase
                    if (audc[1:0] == 2'd0)
                        noise_fb <= (pulse[0] ^ noise[0]) || !(noise != 5'd0 || pulse != 4'd10) ||
                                    audc[3:2] == 2'd0;
                    else
                        noise_fb <= (noise[2] ^ noise[0]) || noise == 5'd0;
                end
                clk_en <= div == audf;
                div    <= (div == audf || div == 5'd31) ? 5'd0 : div + 5'd1;
            end
            if (phase1 && clk_en) begin
                logic fb;
                case (audc[3:2])
                    2'd0:    fb = (pulse[1] ^ pulse[0]) && pulse != 4'd10 && audc[1:0] != 2'd0;
                    2'd1:    fb = !pulse[3];
                    2'd2:    fb = !noise_b0;
                    default: fb = !(pulse[1] || pulse[3:1] == 3'd0);
                endcase
                noise <= {noise_fb, noise[4:1]};
                if (!hold) pulse <= {fb, ~pulse[3:1]};
            end
            if (w_audc) audc <= din[3:0];
            if (w_audf) audf <= din;
            if (w_audv) audv <= din[3:0];
        end else if (st_we) begin
            {noise, pulse, div, hold, noise_b0, noise_fb, clk_en, audv, audf, audc} <= st_wdata[30:0];
        end
    end

    assign st_word = {1'b0, noise, pulse, div, hold, noise_b0, noise_fb, clk_en, audv, audf, audc};
    wire unused_st = st_wdata[31];

endmodule
