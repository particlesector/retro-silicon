// SPDX-License-Identifier: Apache-2.0
// The 2A03's audio processing unit (NTSC): two pulse channels, a triangle,
// noise, the delta modulation channel and the frame counter, at $4000-$4017
// (less $4014 and $4016, the system's). One CPU cycle per `ce`: that
// cycle's register access, then the next cycle's tick, so a $4015 read
// during a cycle sees the APU after that cycle's tick, as on the 2A03 and in
// MesenCE. The channels' outputs are raw levels; mixing is the system's.
//
// The DMC's DMA belongs to the system, which owns the bus: dma_req asks for
// a byte at dma_addr, dma_cancel withdraws it, dma_done returns it.
module apu_2a03 (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,        // one CPU cycle
    input  logic        odd,       // this cycle's count is odd: the CPU's cycle parity
    // The CPU's access in this cycle
    input  logic        wr,        // a write to $4000-$401F
    input  logic        rd_status, // a read of $4015
    input  logic [4:0]  addr,
    input  logic [7:0]  wdata,
    output logic [7:0]  status,    // $4015, bit 5 0 (open bus, the system's)
    output logic        irq_n,     // frame counter or DMC IRQ, active low
    // The DMC's DMA
    output logic        dma_req,
    output logic        dma_cancel,
    output logic [15:0] dma_addr,
    input  logic        dma_done,
    input  logic [7:0]  dma_data,
    // Raw channel levels
    output logic [3:0]  pulse1,
    output logic [3:0]  pulse2,
    output logic [3:0]  triangle,
    output logic [3:0]  noise,
    output logic [6:0]  dmc,
    // Save state: 17 words
    input  logic [4:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    logic wr_en, quarter, half, frame_irq_flag, frame_irq, dmc_irq;
    logic a1, a2, at, an, ad;
    logic [31:0] st_frame, st_p1, st_p2, st_tri, st_noise, st_dmc;

    assign wr_en = wr && addr == 5'h15;

    apu_frame u_frame (
        .clk, .rst, .ce, .odd, .wr(wr && addr == 5'h17), .wdata(wdata[7:6]), .rd_status,
        .quarter, .half, .irq_flag(frame_irq_flag), .irq(frame_irq),
        .st(st_frame), .st_we(st_we && st_addr == 5'd0), .st_wdata);

    apu_pulse #(.CH1(1'b1)) u_pulse1 (
        .clk, .rst, .ce, .wr(wr && addr[4:2] == 3'd0), .wreg(addr[1:0]), .wdata,
        .wr_en, .en_val(wdata[0]), .quarter, .half, .active(a1), .out(pulse1),
        .st_addr(st_addr[1:0] - 2'd1), .st_rdata(st_p1),
        .st_we(st_we && st_addr >= 5'd1 && st_addr <= 5'd3), .st_wdata);

    apu_pulse #(.CH1(1'b0)) u_pulse2 (
        .clk, .rst, .ce, .wr(wr && addr[4:2] == 3'd1), .wreg(addr[1:0]), .wdata,
        .wr_en, .en_val(wdata[1]), .quarter, .half, .active(a2), .out(pulse2),
        .st_addr(2'(st_addr - 5'd4)), .st_rdata(st_p2),
        .st_we(st_we && st_addr >= 5'd4 && st_addr <= 5'd6), .st_wdata);

    apu_triangle u_triangle (
        .clk, .rst, .ce, .wr(wr && addr[4:2] == 3'd2), .wreg(addr[1:0]), .wdata,
        .wr_en, .en_val(wdata[2]), .quarter, .half, .active(at), .out(triangle),
        .st_addr(2'(st_addr - 5'd7)), .st_rdata(st_tri),
        .st_we(st_we && st_addr >= 5'd7 && st_addr <= 5'd9), .st_wdata);

    apu_noise u_noise (
        .clk, .rst, .ce, .wr(wr && addr[4:2] == 3'd3), .wreg(addr[1:0]), .wdata,
        .wr_en, .en_val(wdata[3]), .quarter, .half, .active(an), .out(noise),
        .st_addr(2'(st_addr - 5'd10)), .st_rdata(st_noise),
        .st_we(st_we && st_addr >= 5'd10 && st_addr <= 5'd12), .st_wdata);

    apu_dmc u_dmc (
        .clk, .rst, .ce, .odd, .wr(wr && addr[4:2] == 3'd4), .wreg(addr[1:0]), .wdata,
        .wr_en, .en_val(wdata[4]), .dma_done, .dma_data, .dma_req, .dma_cancel, .dma_addr,
        .active(ad), .irq(dmc_irq), .out(dmc),
        .st_addr(2'(st_addr - 5'd13)), .st_rdata(st_dmc),
        .st_we(st_we && st_addr >= 5'd13 && st_addr <= 5'd16), .st_wdata);

    assign status = {dmc_irq, frame_irq_flag, 1'b0, ad, an, at, a2, a1};
    assign irq_n  = !(frame_irq || dmc_irq);

    always_ff @(posedge clk)
        if (st_addr == 5'd0)
            st_rdata <= st_frame;
        else if (st_addr <= 5'd3)
            st_rdata <= st_p1;
        else if (st_addr <= 5'd6)
            st_rdata <= st_p2;
        else if (st_addr <= 5'd9)
            st_rdata <= st_tri;
        else if (st_addr <= 5'd12)
            st_rdata <= st_noise;
        else if (st_addr <= 5'd16)
            st_rdata <= st_dmc;
        else
            st_rdata <= '0;
endmodule
