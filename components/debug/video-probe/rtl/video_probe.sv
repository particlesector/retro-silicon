// SPDX-License-Identifier: Apache-2.0
// Checks and captures a video stream for the test shell: a CRC-32 of each
// frame and of each line, and a capture of one chosen line at a time, which
// holds the system until the host has read it. Holding the system's clock
// enables leaves its behaviour unchanged, so a frame dumped line by line is
// the frame the system would have shown.
//
// Pixels go into the CRCs as 2 bytes each, low byte first, in raster order.
// They must be at least 3 clocks apart.
module video_probe #(
    parameter int W = 256,
    parameter int H = 240
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        pix_valid,
    input  logic [15:0] pix,
    input  logic [7:0]  pix_x,
    input  logic [7:0]  pix_y,
    input  logic [31:0] frame,      // the index of the frame these pixels belong to

    output logic [31:0] frame_crc,  // CRC of the last whole frame
    output logic [31:0] crc_frame,  // ...and its index
    output logic        crc_valid,  // a whole frame has been seen since reset

    // CRC of each line of the last frame, by line; registered read. A line's
    // entry changes as the next frame passes it, so read it while the system
    // is stopped.
    input  logic [$clog2(H)-1:0] line_raddr,
    output logic [31:0] line_rdata,

    // Capture: line cap_line of frame cap_frame goes into the buffer, and
    // cap_held stays high from then until cap_line, cap_frame or cap_en change.
    input  logic        cap_en,
    input  logic [31:0] cap_frame,
    input  logic [7:0]  cap_line,
    output logic        cap_held,
    input  logic [$clog2(W)-1:0] buf_raddr,
    output logic [15:0] buf_rdata
);
    localparam int XW = $clog2(W), YW = $clog2(H);

    // ---- CRCs: a pixel's two bytes go in on the two clocks after it ----
    logic [7:0]  hi;
    logic [1:0]  n;          // bytes left of the current pixel
    logic        last_px, last_line, store;
    logic [YW-1:0] y_q;
    logic [31:0] frame_q;
    logic [31:0] f_crc, l_crc;
    logic [7:0]  data;

    crc32 u_frame (.clk, .rst(rst || (pix_valid && pix_x == '0 && pix_y == '0)), .en(n != '0), .data, .crc(f_crc));
    crc32 u_line  (.clk, .rst(rst || (pix_valid && pix_x == '0)), .en(n != '0), .data, .crc(l_crc));

    logic [31:0] line_crc[H];
    logic [15:0] cap_buf[W];
    logic [31:0] done_frame;
    logic [7:0]  done_line;
    logic        done;

    always_ff @(posedge clk) begin
        store <= 1'b0;
        if (pix_valid) begin
            data      <= pix[7:0];
            hi        <= pix[15:8];
            n         <= 2'd2;
            last_px   <= pix_x == 8'(W - 1);
            last_line <= pix_y == 8'(H - 1);
            y_q       <= pix_y[YW-1:0];
            frame_q   <= frame;
            if (cap_en && frame == cap_frame && pix_y == cap_line) begin
                cap_buf[pix_x[XW-1:0]] <= pix;
                if (pix_x == 8'(W - 1)) begin
                    done       <= 1'b1;
                    done_frame <= frame;
                    done_line  <= pix_y;
                end
            end
        end else if (n != '0) begin
            data <= hi;
            n    <= n - 2'd1;
            if (n == 2'd1 && last_px)
                store <= 1'b1;  // the line's CRC is final on the next clock
        end
        if (store) begin
            line_crc[y_q] <= l_crc;
            if (last_line) begin
                frame_crc <= f_crc;
                crc_frame <= frame_q;
                crc_valid <= 1'b1;
            end
        end
        if (rst) begin
            n         <= '0;
            store     <= 1'b0;
            crc_valid <= 1'b0;
            done      <= 1'b0;
        end
    end

    assign cap_held = cap_en && done && done_frame == cap_frame && done_line == cap_line;

    always_ff @(posedge clk) begin
        line_rdata <= line_raddr < YW'(H) ? line_crc[line_raddr] : '0;
        buf_rdata  <= cap_buf[buf_raddr];
    end
endmodule
