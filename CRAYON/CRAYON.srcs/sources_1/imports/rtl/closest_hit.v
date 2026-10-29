`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// closest_hit -- the foreach(Polygon) reduction of Bounce().
//   best = 1e10f; take if (hit && t < best)  (strict: ties keep the earlier tri)
//   found = best < 1e9f
// Triangles of a ray arrive in list order, marked first/last; rays back-to-back.
//////////////////////////////////////////////////////////////////////////////////
module closest_hit #(
    parameter integer TRI_W = 7,
    parameter integer RAY_W = 12
)(
    input  wire             clk,
    input  wire             rst,
    input  wire             in_valid,
    input  wire             in_hit,
    input  wire [31:0]      in_t,
    input  wire [TRI_W-1:0] in_tri,
    input  wire [RAY_W-1:0] in_ray,
    input  wire             in_first,
    input  wire             in_last,

    output reg              out_valid,
    output reg              out_found,
    output reg  [31:0]      out_t,
    output reg  [TRI_W-1:0] out_tri,
    output reg  [RAY_W-1:0] out_ray
);
    localparam [31:0] FP_1E9 = 32'h4E6E_6B28, FP_1E10 = 32'h5015_02F9;

    reg [31:0]      best_t;
    reg [TRI_W-1:0] best_tri;

    wire [31:0]      cur_t   = in_first ? FP_1E10       : best_t;
    wire [TRI_W-1:0] cur_tri = in_first ? {TRI_W{1'b0}} : best_tri;
    wire t_lt;
    fp_lt c_t (.a(in_t), .b(cur_t), .y(t_lt));
    wire             take    = in_hit & t_lt;
    wire [31:0]      nxt_t   = take ? in_t   : cur_t;
    wire [TRI_W-1:0] nxt_tri = take ? in_tri : cur_tri;
    wire nxt_found;
    fp_lt c_f (.a(nxt_t), .b(FP_1E9), .y(nxt_found));

    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            best_t    <= FP_1E10;
            best_tri  <= {TRI_W{1'b0}};
        end else begin
            out_valid <= in_valid & in_last;
            if (in_valid) begin
                best_t   <= nxt_t;
                best_tri <= nxt_tri;
            end
        end
        out_found <= nxt_found;
        out_t     <= nxt_t;
        out_tri   <= nxt_tri;
        out_ray   <= in_ray;
    end
endmodule
