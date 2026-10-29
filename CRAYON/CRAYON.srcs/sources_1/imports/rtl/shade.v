`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// shade -- the per-ray update at the end of Bounce() (II = 1):
//   hit : accum += ray_col*emission; ray_col *= diffuse; origin += t*dir;
//         n = normalize(E1 x E2); dir -= (n*2) * Dot(dir, n)
//   miss: accum += ray_col*0.2f;     ray_col = 0
// PerturbDirection is done afterwards by perturb.v.
// Latency = 49 + LAT_SQRT + LAT_DIV + 49 + 1 = 155 with 28/28 cores.
//////////////////////////////////////////////////////////////////////////////////
module shade #(
    parameter integer TAG_W    = 12,
    parameter integer LAT_DIV  = 28,
    parameter integer LAT_SQRT = 28
)(
    input  wire             clk,
    input  wire             rst,
    input  wire             in_valid,
    input  wire [TAG_W-1:0] in_tag,
    input  wire             found,
    input  wire [31:0]      t,
    input  wire [95:0]      origin,
    input  wire [95:0]      dir,
    input  wire [95:0]      ray_col,
    input  wire [95:0]      accum_col,
    input  wire [95:0]      e1,
    input  wire [95:0]      e2,
    input  wire [95:0]      diffuse,
    input  wire [95:0]      emission,

    output reg              out_valid,
    output reg  [TAG_W-1:0] out_tag,
    output reg              out_found,
    output reg  [95:0]      out_origin,
    output reg  [95:0]      out_dir,
    output reg  [95:0]      out_ray_col,
    output reg  [95:0]      out_accum_col
);
    localparam [31:0] FP_SKY = 32'h3E4C_CCCD;   // 0.2f
    localparam integer L_MUL = 8;
    localparam integer T_N   = 49 + LAT_SQRT + LAT_DIV;
    localparam integer T_END = T_N + 49;

    // ---- colours -----------------------------------------------------------
    wire em_v; wire [95:0] em_prod, dif_prod;
    vec_mul3 u_em  (.clk(clk), .in_valid(in_valid), .a(ray_col),
                    .b(found ? emission : {FP_SKY, FP_SKY, FP_SKY}), .out_valid(em_v), .c(em_prod));
    vec_mul3 u_dif (.clk(clk), .in_valid(in_valid), .a(ray_col), .b(diffuse), .out_valid(), .c(dif_prod));
    wire [95:0] accum_d8, accum_new;
    delay #(.W(96), .N(L_MUL)) d_acc (.clk(clk), .d(accum_col), .q(accum_d8));
    vec_add3 u_acc (.clk(clk), .in_valid(em_v), .a(accum_d8), .b(em_prod), .out_valid(), .c(accum_new));   // @19

    // ---- hit position --------------------------------------------------------
    wire [95:0] td, origin_d8, pos;
    vec_mul3 u_td (.clk(clk), .in_valid(in_valid), .a(dir), .b({t, t, t}), .out_valid(), .c(td));
    delay #(.W(96), .N(L_MUL)) d_org (.clk(clk), .d(origin), .q(origin_d8));
    vec_add3 u_pos (.clk(clk), .in_valid(em_v), .a(origin_d8), .b(td), .out_valid(), .c(pos));             // @19

    // ---- surface normal ------------------------------------------------------
    wire n_v; wire [95:0] n;
    cross u_n (.clk(clk), .rst(rst), .a_ready(in_valid), .vec_a(e1),
               .b_ready(in_valid), .vec_b(e2), .c_ready(n_v), .vec_c(n));                                 // @19
    wire n2_v; wire [31:0] n2;
    dot u_n2 (.clk(clk), .rst(rst), .a_ready(n_v), .vec_a(n), .b_ready(n_v), .vec_b(n),
              .c_ready(n2_v), .c(n2));                                                                    // @49
    wire mag_v; wire [31:0] mag;
    sqrt u_sqrt (.aclk(clk), .s_axis_a_tvalid(n2_v), .s_axis_a_tdata(n2),
                 .m_axis_result_tvalid(mag_v), .m_axis_result_tdata(mag));                               // @49+S
    wire [95:0] n_dl;
    delay #(.W(96), .N(30 + LAT_SQRT)) d_n (.clk(clk), .d(n), .q(n_dl));
    wire nh_v; wire [95:0] nhat;
    vec_div3 u_nh (.clk(clk), .in_valid(mag_v), .a(n_dl), .b({mag, mag, mag}), .out_valid(nh_v), .c(nhat)); // @T_N

    // ---- reflection: dir - (n*2)*Dot(dir,n) ---------------------------------
    wire [95:0] dir_dn;
    delay #(.W(96), .N(T_N)) d_dir1 (.clk(clk), .d(dir), .q(dir_dn));
    wire dd_v; wire [31:0] dd;
    dot u_dd (.clk(clk), .rst(rst), .a_ready(nh_v), .vec_a(dir_dn), .b_ready(nh_v), .vec_b(nhat),
              .c_ready(dd_v), .c(dd));                                                                    // @T_N+30
    wire [95:0] n_x2, n_x2_d;     // *2 is exact: exponent+1, identical to the core
    fp_mul2 m2x (.a(nhat[31:0]),  .y(n_x2[31:0]));
    fp_mul2 m2y (.a(nhat[63:32]), .y(n_x2[63:32]));
    fp_mul2 m2z (.a(nhat[95:64]), .y(n_x2[95:64]));
    delay #(.W(96), .N(30)) d_nx2 (.clk(clk), .d(n_x2), .q(n_x2_d));
    wire refl_v; wire [95:0] refl;
    vec_mul3 u_refl (.clk(clk), .in_valid(dd_v), .a(n_x2_d), .b({dd, dd, dd}), .out_valid(refl_v), .c(refl)); // @T_N+38
    wire [95:0] dir_d38, new_dir;
    delay #(.W(96), .N(38)) d_dir2 (.clk(clk), .d(dir_dn), .q(dir_d38));
    vec_sub3 u_nd (.clk(clk), .in_valid(refl_v), .a(dir_d38), .b(refl), .out_valid(), .c(new_dir));       // @T_END

    // ---- align to T_END ------------------------------------------------------
    wire [95:0] accum_e, pos_e, dif_e, org_e, dir_e;
    delay #(.W(96), .N(T_END - 19))    d_a2 (.clk(clk), .d(accum_new), .q(accum_e));
    delay #(.W(96), .N(T_END - 19))    d_p2 (.clk(clk), .d(pos),       .q(pos_e));
    delay #(.W(96), .N(T_END - L_MUL)) d_c2 (.clk(clk), .d(dif_prod),  .q(dif_e));
    delay #(.W(96), .N(T_END))         d_o3 (.clk(clk), .d(origin),    .q(org_e));
    delay #(.W(96), .N(11))            d_d3 (.clk(clk), .d(dir_d38),   .q(dir_e));

    wire v_e, found_e; wire [TAG_W-1:0] tag_e;
    valid_delay #(.N(T_END)) d_v (.clk(clk), .rst(rst), .d(in_valid), .q(v_e));
    delay #(.W(1 + TAG_W), .N(T_END)) d_ctl (.clk(clk), .d({found, in_tag}), .q({found_e, tag_e}));

    always @(posedge clk) begin
        out_valid     <= rst ? 1'b0 : v_e;
        out_tag       <= tag_e;
        out_found     <= found_e;
        out_accum_col <= accum_e;
        out_ray_col   <= found_e ? dif_e   : 96'd0;
        out_origin    <= found_e ? pos_e   : org_e;
        out_dir       <= found_e ? new_dir : dir_e;
    end
endmodule
