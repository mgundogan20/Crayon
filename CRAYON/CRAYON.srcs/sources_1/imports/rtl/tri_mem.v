`timescale 1ns / 1ps
// Triangle store with a 480-bit read port: one whole polygon per clock,
// which is what an II=1 intersect pipeline needs.
// 15 narrow banks (one per float), synchronous read (1-cycle latency) so
// Vivado can infer block RAM. Instantiate it twice (one for intersect, one
// for shade) and write both from the parser -- that's cheaper than muxing.
//
// r_data layout (word i of the packet at [32*i +: 32]):
//   [ 95:  0] V0  {z,y,x}
//   [191: 96] E1
//   [287:192] E2
//   [383:288] diffuseColor
//   [479:384] emissionColor
module tri_mem #(
    parameter integer MAX_TRIANGLES = 128,
    parameter integer AW            = 7       // clog2(MAX_TRIANGLES)
)(
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] w_tri,
    input  wire [3:0]    w_slot,                // 0..14
    input  wire [31:0]   w_data,
    input  wire [AW-1:0] r_tri,
    output wire [479:0]  r_data
);
    genvar i;
    generate for (i = 0; i < 15; i = i + 1) begin : bank
        (* ram_style = "block" *) reg [31:0] mem [0:MAX_TRIANGLES-1];
        reg [31:0] q;
        always @(posedge clk) begin
            if (we && w_slot == i) mem[w_tri] <= w_data;
            q <= mem[r_tri];
        end
        assign r_data[32*i +: 32] = q;
    end endgenerate
endmodule
