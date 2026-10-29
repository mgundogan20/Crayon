`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// intersect -- fully pipelined Moller-Trumbore, one (ray, triangle) pair per
// clock. Mirrors FakePGA.CheckIntersection() + the "distance > EPSILON" test
// of Bounce() operation for operation (bit-identical, except that the Xilinx
// cores flush denormals to zero). Early returns become reject flags.
// Vectors packed {z, y, x}, x in [31:0].
//
// Schedule (cycle a value is ready, D = LAT_DIV = 28):
//     11 T = O - V0 | 19 P = D x E2 | 30 Q = T x E1
//     49 det = E1.P, T.P | 60 D.Q, E2.Q | 49+D 1/det | 57+D u,v,t | 68+D u+v
//     LATENCY = 69 + D = 97
//////////////////////////////////////////////////////////////////////////////////
module intersect #(
    parameter integer TAG_W   = 16,
    parameter integer LAT_DIV = 28
)(
    input  wire             clk,
    input  wire             rst,
    input  wire             in_valid,
    input  wire [95:0]      ray_o,
    input  wire [95:0]      ray_d,
    input  wire [95:0]      v0,
    input  wire [95:0]      e1,
    input  wire [95:0]      e2,
    input  wire [TAG_W-1:0] in_tag,

    output reg              out_valid,
    output reg              out_hit,    // valid intersection with t > EPSILON
    output reg  [31:0]      out_t,
    output reg  [TAG_W-1:0] out_tag
);
    localparam [31:0] FP_ZERO = 32'h0000_0000, FP_ONE = 32'h3F80_0000;
    localparam [31:0] FP_EPS  = 32'h33D6_BF95, FP_NEG_EPS = 32'hB3D6_BF95;   // +-1e-7f

    localparam integer L_MUL = 8, L_ADD = 11;
    localparam integer T_T   = L_ADD;                 // 11
    localparam integer T_P   = L_MUL + L_ADD;         // 19
    localparam integer T_Q   = T_T + T_P;             // 30
    localparam integer T_DET = T_P + L_MUL + 2*L_ADD; // 49
    localparam integer T_DQ  = T_Q + L_MUL + 2*L_ADD; // 60
    localparam integer T_INV = T_DET + LAT_DIV;
    localparam integer T_UVT = T_INV + L_MUL;
    localparam integer T_SUM = T_UVT + L_ADD;
    localparam integer LATENCY = T_SUM + 1;

    // T = O - V0
    wire t_v; wire [95:0] T;
    vec_sub3 u_T (.clk(clk), .in_valid(in_valid), .a(ray_o), .b(v0), .out_valid(t_v), .c(T));

    // P = D x E2
    wire p_v; wire [95:0] P;
    cross u_P (.clk(clk), .rst(rst), .a_ready(in_valid), .vec_a(ray_d),
               .b_ready(in_valid), .vec_b(e2), .c_ready(p_v), .vec_c(P));

    // Q = T x E1
    wire [95:0] e1_d11;
    delay #(.W(96), .N(T_T)) d_e1a (.clk(clk), .d(e1), .q(e1_d11));
    wire q_v; wire [95:0] Q;
    cross u_Q (.clk(clk), .rst(rst), .a_ready(t_v), .vec_a(T),
               .b_ready(t_v), .vec_b(e1_d11), .c_ready(q_v), .vec_c(Q));

    // det = E1 . P , dTP = T . P
    wire [95:0] e1_d19, T_d8;
    delay #(.W(96), .N(T_P))       d_e1b (.clk(clk), .d(e1), .q(e1_d19));
    delay #(.W(96), .N(T_P - T_T)) d_T   (.clk(clk), .d(T),  .q(T_d8));
    wire det_v; wire [31:0] det, dtp;
    dot u_det (.clk(clk), .rst(rst), .a_ready(p_v), .vec_a(e1_d19),
               .b_ready(p_v), .vec_b(P), .c_ready(det_v), .c(det));
    dot u_dtp (.clk(clk), .rst(rst), .a_ready(p_v), .vec_a(T_d8),
               .b_ready(p_v), .vec_b(P), .c_ready(), .c(dtp));

    // dDQ = D . Q , dEQ = E2 . Q
    wire [95:0] d_d30, e2_d30;
    delay #(.W(96), .N(T_Q)) d_d  (.clk(clk), .d(ray_d), .q(d_d30));
    delay #(.W(96), .N(T_Q)) d_e2 (.clk(clk), .d(e2),    .q(e2_d30));
    wire [31:0] ddq, deq;
    dot u_ddq (.clk(clk), .rst(rst), .a_ready(q_v), .vec_a(d_d30),
               .b_ready(q_v), .vec_b(Q), .c_ready(), .c(ddq));
    dot u_deq (.clk(clk), .rst(rst), .a_ready(q_v), .vec_a(e2_d30),
               .b_ready(q_v), .vec_b(Q), .c_ready(), .c(deq));

    // invDet = 1.0f / det  (Divide, so it is the correctly rounded quotient like C#)
    wire inv_v; wire [31:0] inv;
    divide u_inv (.aclk(clk),
        .s_axis_a_tvalid(det_v), .s_axis_a_tdata(FP_ONE),
        .s_axis_b_tvalid(det_v), .s_axis_b_tdata(det),
        .m_axis_result_tvalid(inv_v), .m_axis_result_tdata(inv));

    // parallel:  det > -EPS && det < EPS   (C# rejects when true)
    wire det_gt_neps, det_lt_eps, par_d;
    fp_lt c_det0 (.a(FP_NEG_EPS), .b(det), .y(det_gt_neps));
    fp_lt c_det1 (.a(det), .b(FP_EPS),     .y(det_lt_eps));
    delay #(.W(1), .N(T_SUM - T_DET)) d_par (.clk(clk), .d(det_gt_neps & det_lt_eps), .q(par_d));

    // u, v, t = * invDet
    wire [31:0] dtp_dl, ddq_dl, deq_dl;
    delay #(.W(32), .N(T_INV - T_DET)) d_dtp (.clk(clk), .d(dtp), .q(dtp_dl));
    delay #(.W(32), .N(T_INV - T_DQ))  d_ddq (.clk(clk), .d(ddq), .q(ddq_dl));
    delay #(.W(32), .N(T_INV - T_DQ))  d_deq (.clk(clk), .d(deq), .q(deq_dl));
    wire uvt_v; wire [95:0] uvt;   // {t, v, u}
    vec_mul3 u_uvt (.clk(clk), .in_valid(inv_v), .a({deq_dl, ddq_dl, dtp_dl}), .b({inv, inv, inv}),
                    .out_valid(uvt_v), .c(uvt));
    wire [31:0] u_f = uvt[31:0], v_f = uvt[63:32], t_f = uvt[95:64];

    // u + v
    wire [31:0] uv_sum;
    add u_uv (.aclk(clk),
        .s_axis_a_tvalid(uvt_v), .s_axis_a_tdata(u_f),
        .s_axis_b_tvalid(uvt_v), .s_axis_b_tdata(v_f),
        .m_axis_result_tvalid(), .m_axis_result_tdata(uv_sum));

    // reject flags at T_UVT
    wire u_lt0, u_gt1, v_lt0;
    fp_lt c_u0 (.a(u_f),    .b(FP_ZERO), .y(u_lt0));
    fp_lt c_u1 (.a(FP_ONE), .b(u_f),     .y(u_gt1));
    fp_lt c_v0 (.a(v_f),    .b(FP_ZERO), .y(v_lt0));
    wire rej_u_d, rej_v_d; wire [31:0] t_d;
    delay #(.W(34), .N(L_ADD)) d_uvt (.clk(clk), .d({u_lt0 | u_gt1, v_lt0, t_f}), .q({rej_u_d, rej_v_d, t_d}));

    // final flags at T_SUM
    wire uv_gt1, t_gt_eps;
    fp_lt c_uv (.a(FP_ONE), .b(uv_sum), .y(uv_gt1));
    fp_lt c_t  (.a(FP_EPS), .b(t_d),    .y(t_gt_eps));

    wire v_sum; wire [TAG_W-1:0] tag_sum;
    valid_delay #(.N(T_SUM))         d_valid (.clk(clk), .rst(rst), .d(in_valid), .q(v_sum));
    delay       #(.W(TAG_W), .N(T_SUM)) d_tag (.clk(clk), .d(in_tag), .q(tag_sum));

    always @(posedge clk) begin
        out_valid <= rst ? 1'b0 : v_sum;
        out_hit   <= ~par_d & ~rej_u_d & ~rej_v_d & ~uv_gt1 & t_gt_eps;
        out_t     <= t_d;
        out_tag   <= tag_sum;
    end
endmodule
