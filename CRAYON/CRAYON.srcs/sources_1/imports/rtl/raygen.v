`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// raygen -- FakePGA.GeneratePrimaries() for one pixel, resource-shared:
// ONE multiply, ONE add, ONE sqrt, ONE divide core (4 DSP48 total), driven by a
// fixed schedule. One ray every RAY_CYCLES (= 140 with 8/11/28/28 latencies).
//
//   deltax = (x - X_res/2) * fov ; deltay = (y - Y_res/2) * fov
//   d      = (deltax*right + deltay*up) + forward       (Unity Vector3 order)
//   n      = d / |d| ,  |d| = sqrt((x*x + y*y) + z*z)  (Vector3.normalized)
// The 0.001f jitter is applied afterwards by perturb.v (narrow mode).
//
// Handshake: a pixel is accepted when start && ready; out_valid pulses once
// with the normalized direction.
//////////////////////////////////////////////////////////////////////////////////
module raygen #(
    parameter integer TAG_W    = 12,
    parameter integer LAT_MUL  = 8,
    parameter integer LAT_ADD  = 11,
    parameter integer LAT_DIV  = 28,
    parameter integer LAT_SQRT = 28
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               start,
    output wire               ready,
    input  wire signed [17:0] ix,        // x - X_res/2
    input  wire signed [17:0] iy,        // y - Y_res/2
    input  wire [TAG_W-1:0]   in_tag,
    input  wire [31:0]        fov,
    input  wire [95:0]        fwd,
    input  wire [95:0]        right,
    input  wire [95:0]        up,

    output reg                out_valid,
    output reg  [95:0]        out_dir,
    output reg  [TAG_W-1:0]   out_tag
);
    localparam integer LM = LAT_MUL, LA = LAT_ADD;
    // issue cycles (a result issued at c is captured at c+L, usable at c+L+1)
    localparam integer C_DX   = 0;                     // fx*fov
    localparam integer C_DY   = 1;                     // fy*fov
    localparam integer C_XR   = C_DX + LM + 1;         // right.{x,y,z}*dx   (3 slots)
    localparam integer C_YU   = C_XR + 3;              // up.{x,y,z}*dy      (3 slots)
    localparam integer C_S1   = C_YU + LM + 1;         // xr + yu            (3 slots, add)
    localparam integer C_D    = C_S1 + LA + 1;         // s1 + fwd           (3 slots, add)
    localparam integer C_SQ   = C_D + LA + 1;          // d.{x,y,z}^2        (3 slots)
    localparam integer C_A1   = C_SQ + 1 + LM + 1;     // xx + yy            (add)
    localparam integer C_A2   = C_A1 + LA + 1;         // (xx+yy) + zz       (add)
    localparam integer C_RT   = C_A2 + LA + 1;         // sqrt
    localparam integer C_DV   = C_RT + LAT_SQRT + 1;   // d.{x,y,z} / mag    (3 slots)
    localparam integer C_DONE = C_DV + 2 + LAT_DIV + 1;
    localparam integer RAY_CYCLES = C_DONE + 1;

    reg        busy;
    reg [7:0]  c;
    assign ready = ~busy;

    reg [31:0] fx, fy, dx, dy, a1, m2, mag;
    reg [95:0] xr, yu, s1, d, sq, n;
    reg [TAG_W-1:0] tag;

    wire [31:0] fx_w, fy_w;
    int_to_fp cvx (.v(ix), .f(fx_w));
    int_to_fp cvy (.v(iy), .f(fy_w));

    // ---------------- shared multiplier ----------------------------------------
    reg        mv; reg [31:0] ma, mb;
    always @* begin
        mv = busy; ma = 32'd0; mb = 32'd0;
        if      (c == C_DX)     begin ma = fx;          mb = fov; end
        else if (c == C_DY)     begin ma = fy;          mb = fov; end
        else if (c == C_XR)     begin ma = right[31:0];  mb = dx; end
        else if (c == C_XR + 1) begin ma = right[63:32]; mb = dx; end
        else if (c == C_XR + 2) begin ma = right[95:64]; mb = dx; end
        else if (c == C_YU)     begin ma = up[31:0];     mb = dy; end
        else if (c == C_YU + 1) begin ma = up[63:32];    mb = dy; end
        else if (c == C_YU + 2) begin ma = up[95:64];    mb = dy; end
        else if (c == C_SQ)     begin ma = d[31:0];      mb = d[31:0];  end
        else if (c == C_SQ + 1) begin ma = d[63:32];     mb = d[63:32]; end
        else if (c == C_SQ + 2) begin ma = d[95:64];     mb = d[95:64]; end
        else mv = 1'b0;
    end
    wire [31:0] mr;
    multiply u_mul (.aclk(clk), .s_axis_a_tvalid(mv), .s_axis_a_tdata(ma),
        .s_axis_b_tvalid(mv), .s_axis_b_tdata(mb), .m_axis_result_tvalid(), .m_axis_result_tdata(mr));

    // ---------------- shared adder ---------------------------------------------
    reg        av; reg [31:0] aa, ab;
    always @* begin
        av = busy; aa = 32'd0; ab = 32'd0;
        if      (c == C_S1)     begin aa = xr[31:0];  ab = yu[31:0];  end
        else if (c == C_S1 + 1) begin aa = xr[63:32]; ab = yu[63:32]; end
        else if (c == C_S1 + 2) begin aa = xr[95:64]; ab = yu[95:64]; end
        else if (c == C_D)      begin aa = s1[31:0];  ab = fwd[31:0];  end
        else if (c == C_D + 1)  begin aa = s1[63:32]; ab = fwd[63:32]; end
        else if (c == C_D + 2)  begin aa = s1[95:64]; ab = fwd[95:64]; end
        else if (c == C_A1)     begin aa = sq[31:0];  ab = sq[63:32]; end
        else if (c == C_A2)     begin aa = a1;        ab = sq[95:64]; end
        else av = 1'b0;
    end
    wire [31:0] ar;
    add u_add (.aclk(clk), .s_axis_a_tvalid(av), .s_axis_a_tdata(aa),
        .s_axis_b_tvalid(av), .s_axis_b_tdata(ab), .m_axis_result_tvalid(), .m_axis_result_tdata(ar));

    // ---------------- sqrt and divide ------------------------------------------
    wire [31:0] rr;
    sqrt u_sqrt (.aclk(clk), .s_axis_a_tvalid(busy && c == C_RT), .s_axis_a_tdata(m2),
        .m_axis_result_tvalid(), .m_axis_result_tdata(rr));

    reg        dv; reg [31:0] da;
    always @* begin
        dv = busy; da = 32'd0;
        if      (c == C_DV)     da = d[31:0];
        else if (c == C_DV + 1) da = d[63:32];
        else if (c == C_DV + 2) da = d[95:64];
        else dv = 1'b0;
    end
    wire [31:0] dr;
    divide u_div (.aclk(clk), .s_axis_a_tvalid(dv), .s_axis_a_tdata(da),
        .s_axis_b_tvalid(dv), .s_axis_b_tdata(mag), .m_axis_result_tvalid(), .m_axis_result_tdata(dr));

    // ---------------- sequencer + result capture --------------------------------
    always @(posedge clk) begin
        out_valid <= 1'b0;
        if (rst) begin
            busy <= 1'b0; c <= 0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1'b1; c <= 0;
                fx <= fx_w; fy <= fy_w; tag <= in_tag;
            end
        end else begin
            c <= c + 1'b1;
            // multiplier results
            if (c == C_DX + LM)     dx         <= mr;
            if (c == C_DY + LM)     dy         <= mr;
            if (c == C_XR + LM)     xr[31:0]   <= mr;
            if (c == C_XR + 1 + LM) xr[63:32]  <= mr;
            if (c == C_XR + 2 + LM) xr[95:64]  <= mr;
            if (c == C_YU + LM)     yu[31:0]   <= mr;
            if (c == C_YU + 1 + LM) yu[63:32]  <= mr;
            if (c == C_YU + 2 + LM) yu[95:64]  <= mr;
            if (c == C_SQ + LM)     sq[31:0]   <= mr;
            if (c == C_SQ + 1 + LM) sq[63:32]  <= mr;
            if (c == C_SQ + 2 + LM) sq[95:64]  <= mr;
            // adder results
            if (c == C_S1 + LA)     s1[31:0]   <= ar;
            if (c == C_S1 + 1 + LA) s1[63:32]  <= ar;
            if (c == C_S1 + 2 + LA) s1[95:64]  <= ar;
            if (c == C_D + LA)      d[31:0]    <= ar;
            if (c == C_D + 1 + LA)  d[63:32]   <= ar;
            if (c == C_D + 2 + LA)  d[95:64]   <= ar;
            if (c == C_A1 + LA)     a1         <= ar;
            if (c == C_A2 + LA)     m2         <= ar;
            // sqrt / divide results
            if (c == C_RT + LAT_SQRT)    mag       <= rr;
            if (c == C_DV + LAT_DIV)     n[31:0]   <= dr;
            if (c == C_DV + 1 + LAT_DIV) n[63:32]  <= dr;
            if (c == C_DV + 2 + LAT_DIV) n[95:64]  <= dr;
            if (c == C_DONE) begin
                busy      <= 1'b0;
                out_valid <= 1'b1;
                out_dir   <= n;
                out_tag   <= tag;
            end
        end
    end
endmodule