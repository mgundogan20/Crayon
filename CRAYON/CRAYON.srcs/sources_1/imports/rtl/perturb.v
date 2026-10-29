`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// perturb -- hardware version of FakePGA.PerturbDirection(dir, 1.5f).
//
// Same distribution as the Unity code (cosTheta uniform in [cos 1.5, 1),
// phi uniform in [0, 2pi), result is a unit vector around 'dir'), but using
// operations that map onto the FP cores:
//   r1, r2  = two xorshift32 steps per ray (every ray, hit or miss)
//   f       = 1.m  with m = r1[31:9]             -> f in [1, 2)
//   cosT    = f*K + C   (K = 1 - cos1.5, C = cos1.5 - K)
//   sinT    = sqrt(1 - cosT*cosT)
//   cos/sinPhi = LUT[r2[31:22]]                  (1024 entries)
//   T, B    = orthonormal basis around n (Duff et al. 2017, branch-free)
//   out     = (sinT*cosPhi*T + cosT*n) + sinT*sinPhi*B
// FromToRotation only uses the direction of 'dir'; like it, we assume |dir| = 1
// (true for every ray: primaries are unit and reflection preserves length).
// The rotation about 'dir' differs from Unity's quaternion, which only shifts
// phi -- statistically identical. FpgaReference.cs reproduces this bit-exactly.
//
// Applied only when (en && found); otherwise dir passes through unchanged.
// in_narrow selects the cone: 0.001f for primary-ray jitter, 1.5f after a bounce.
// Latency 105.
//////////////////////////////////////////////////////////////////////////////////
module perturb #(
    parameter integer TAG_W    = 12,
    parameter integer PAY_W    = 288,
    parameter integer LAT_DIV  = 28,
    parameter integer LAT_SQRT = 28
)(
    input  wire             clk,
    input  wire             rst,
    input  wire             seed_load,
    input  wire [31:0]      seed,
    input  wire             en,

    input  wire             in_valid,
    input  wire             in_narrow,    // 1: maxAngle 0.001f (primary jitter), 0: 1.5f (bounce)
    input  wire             in_found,
    input  wire [95:0]      in_dir,
    input  wire [TAG_W-1:0] in_tag,
    input  wire [PAY_W-1:0] in_payload,   // carried along (origin, ray_col, accum)

    output reg              out_valid,
    output reg  [95:0]      out_dir,
    output reg  [TAG_W-1:0] out_tag,
    output reg  [PAY_W-1:0] out_payload
);
    localparam [31:0] FP_ONE = 32'h3F80_0000, FP_NEG_ONE = 32'hBF80_0000;
    localparam [31:0] K_W    = 32'h3F6D_E42B;     // 1 - cos(1.5f)
    localparam [31:0] C_W    = 32'hBF5B_C856;     // cos(1.5f) - K_W
    localparam [31:0] K_N    = 32'h3500_0000;     // 1 - cos(0.001f)
    localparam [31:0] C_N    = 32'h3F7F_FFF0;     // cos(0.001f) - K_N
    localparam integer L_MUL = 8, L_ADD = 11;

    localparam integer T_CT  = L_MUL + L_ADD;              // 19 cosT
    localparam integer T_ST  = T_CT + L_MUL + L_ADD + LAT_SQRT; // 66 sinT
    localparam integer T_PQ  = T_ST + L_MUL;               // 74 p, q
    localparam integer T_A   = L_ADD + LAT_DIV;            // 39 a
    localparam integer T_B   = T_A + L_MUL;                // 47 b, xxa, yya
    localparam integer T_TB  = T_B + L_ADD;                // 58 T.x, B.y
    localparam integer T_M   = T_PQ + L_MUL;               // 82
    localparam integer T_END = T_M + 2*L_ADD;              // 104
    // the basis must be ready before p,q:
    // (T_TB <= T_PQ holds for any LAT_SQRT >= LAT_DIV - 14)

    wire [31:0] nx = in_dir[31:0], ny = in_dir[63:32], nz = in_dir[95:64];

    // ---- RNG -----------------------------------------------------------------
    reg  [31:0] state;
    wire [31:0] r1, r2;
    xorshift32 x1 (.s(state), .y(r1));
    xorshift32 x2 (.s(r1),    .y(r2));
    always @(posedge clk) begin
        if (rst)                state <= 32'd1;
        else if (seed_load)     state <= (seed == 32'd0) ? 32'd1 : seed;
        else if (in_valid)      state <= r2;
    end
    wire [31:0] f_rand = {9'b0_0111_1111, r1[31:9]};      // 1.m in [1,2)

    // ---- cosT, sinT ----------------------------------------------------------
    wire narrow_d8;
    delay #(.W(1), .N(L_MUL)) d_nar (.clk(clk), .d(in_narrow), .q(narrow_d8));
    wire [31:0] K_CT = in_narrow ? K_N : K_W;
    wire [31:0] C_CT = narrow_d8 ? C_N : C_W;
    wire ct_m_v; wire [31:0] ct_m;
    multiply u_ctm (.aclk(clk), .s_axis_a_tvalid(in_valid), .s_axis_a_tdata(f_rand),
        .s_axis_b_tvalid(in_valid), .s_axis_b_tdata(K_CT), .m_axis_result_tvalid(ct_m_v), .m_axis_result_tdata(ct_m));
    wire ct_v; wire [31:0] ct;
    add u_cta (.aclk(clk), .s_axis_a_tvalid(ct_m_v), .s_axis_a_tdata(ct_m),
        .s_axis_b_tvalid(ct_m_v), .s_axis_b_tdata(C_CT), .m_axis_result_tvalid(ct_v), .m_axis_result_tdata(ct));
    wire ct2_v; wire [31:0] ct2;
    multiply u_ct2 (.aclk(clk), .s_axis_a_tvalid(ct_v), .s_axis_a_tdata(ct),
        .s_axis_b_tvalid(ct_v), .s_axis_b_tdata(ct), .m_axis_result_tvalid(ct2_v), .m_axis_result_tdata(ct2));
    wire om_v; wire [31:0] om;
    subtract u_om (.aclk(clk), .s_axis_a_tvalid(ct2_v), .s_axis_a_tdata(FP_ONE),
        .s_axis_b_tvalid(ct2_v), .s_axis_b_tdata(ct2), .m_axis_result_tvalid(om_v), .m_axis_result_tdata(om));
    wire st_v; wire [31:0] st;
    sqrt u_st (.aclk(clk), .s_axis_a_tvalid(om_v), .s_axis_a_tdata(om),
        .m_axis_result_tvalid(st_v), .m_axis_result_tdata(st));                                   // @T_ST

    // ---- phi ---------------------------------------------------------------
    wire [31:0] cphi, sphi, cphi_d, sphi_d;
    phi_lut u_lut (.clk(clk), .idx(r2[31:22]), .cos_o(cphi), .sin_o(sphi));                      // @1
    delay #(.W(64), .N(T_ST - 1)) d_phi (.clk(clk), .d({cphi, sphi}), .q({cphi_d, sphi_d}));
    wire pq_v; wire [31:0] p, q;   // p = sinT*cosPhi, q = sinT*sinPhi
    multiply u_p (.aclk(clk), .s_axis_a_tvalid(st_v), .s_axis_a_tdata(st),
        .s_axis_b_tvalid(st_v), .s_axis_b_tdata(cphi_d), .m_axis_result_tvalid(pq_v), .m_axis_result_tdata(p));
    multiply u_q (.aclk(clk), .s_axis_a_tvalid(st_v), .s_axis_a_tdata(st),
        .s_axis_b_tvalid(st_v), .s_axis_b_tdata(sphi_d), .m_axis_result_tvalid(), .m_axis_result_tdata(q));  // @T_PQ

    // ---- orthonormal basis ---------------------------------------------------
    wire        neg   = nz[31];
    wire [31:0] sgn1  = neg ? FP_NEG_ONE : FP_ONE;
    wire sz_v; wire [31:0] sz;
    add u_sz (.aclk(clk), .s_axis_a_tvalid(in_valid), .s_axis_a_tdata(sgn1),
        .s_axis_b_tvalid(in_valid), .s_axis_b_tdata(nz), .m_axis_result_tvalid(sz_v), .m_axis_result_tdata(sz));
    wire a_v; wire [31:0] a;
    divide u_a (.aclk(clk), .s_axis_a_tvalid(sz_v), .s_axis_a_tdata(FP_NEG_ONE),
        .s_axis_b_tvalid(sz_v), .s_axis_b_tdata(sz), .m_axis_result_tvalid(a_v), .m_axis_result_tdata(a)); // @39

    wire [95:0] sq, sq_d;          // {yy, xx, xy}
    vec_mul3 u_sq (.clk(clk), .in_valid(in_valid), .a({ny, nx, nx}), .b({ny, nx, ny}), .out_valid(), .c(sq));
    delay #(.W(96), .N(T_A - L_MUL)) d_sq (.clk(clk), .d(sq), .q(sq_d));
    wire bxy_v; wire [95:0] bxy;   // {yya, xxa, b}
    vec_mul3 u_bxy (.clk(clk), .in_valid(a_v), .a(sq_d), .b({a, a, a}), .out_valid(bxy_v), .c(bxy));    // @47
    wire [31:0] b_f = bxy[31:0], xxa = bxy[63:32], yya = bxy[95:64];

    wire neg_47; wire [31:0] sgn1_47;
    delay #(.W(33), .N(T_B)) d_sg (.clk(clk), .d({neg, sgn1}), .q({neg_47, sgn1_47}));
    wire [31:0] tx, by;
    add u_tx (.aclk(clk), .s_axis_a_tvalid(bxy_v), .s_axis_a_tdata(FP_ONE),
        .s_axis_b_tvalid(bxy_v), .s_axis_b_tdata({xxa[31] ^ neg_47, xxa[30:0]}),
        .m_axis_result_tvalid(), .m_axis_result_tdata(tx));                                       // T.x = 1 + sign*xx*a
    add u_by (.aclk(clk), .s_axis_a_tvalid(bxy_v), .s_axis_a_tdata(sgn1_47),
        .s_axis_b_tvalid(bxy_v), .s_axis_b_tdata(yya),
        .m_axis_result_tvalid(), .m_axis_result_tdata(by));                                       // B.y = sign + yy*a

    // align basis to T_PQ
    wire [31:0] tx_d, by_d, ty_d, bx_d;
    delay #(.W(64), .N(T_PQ - T_TB)) d_txby (.clk(clk), .d({tx, by}), .q({tx_d, by_d}));
    delay #(.W(64), .N(T_PQ - T_B))  d_tybx (.clk(clk), .d({b_f[31] ^ neg_47, b_f[30:0], b_f}), .q({ty_d, bx_d}));
    wire [31:0] tz_d, bz_d;        // T.z = -sign*n.x , B.z = -n.y
    delay #(.W(64), .N(T_PQ)) d_tzbz (.clk(clk), .d({nx[31] ^ ~neg, nx[30:0], ~ny[31], ny[30:0]}), .q({tz_d, bz_d}));
    wire [95:0] n_d;
    delay #(.W(96), .N(T_PQ)) d_n (.clk(clk), .d(in_dir), .q(n_d));
    wire [31:0] ct_d;
    delay #(.W(32), .N(T_PQ - T_CT)) d_ct (.clk(clk), .d(ct), .q(ct_d));

    // ---- combine ---------------------------------------------------------------
    wire m_v; wire [95:0] m1, m2, m3;
    vec_mul3 u_m1 (.clk(clk), .in_valid(pq_v), .a({tz_d, ty_d, tx_d}), .b({p, p, p}), .out_valid(m_v), .c(m1));
    vec_mul3 u_m2 (.clk(clk), .in_valid(pq_v), .a(n_d),                .b({ct_d, ct_d, ct_d}), .out_valid(), .c(m2));
    vec_mul3 u_m3 (.clk(clk), .in_valid(pq_v), .a({bz_d, by_d, bx_d}), .b({q, q, q}), .out_valid(), .c(m3));
    wire s12_v; wire [95:0] s12, m3_d;
    vec_add3 u_s12 (.clk(clk), .in_valid(m_v), .a(m1), .b(m2), .out_valid(s12_v), .c(s12));
    delay #(.W(96), .N(L_ADD)) d_m3 (.clk(clk), .d(m3), .q(m3_d));
    wire [95:0] pdir;
    vec_add3 u_out (.clk(clk), .in_valid(s12_v), .a(s12), .b(m3_d), .out_valid(), .c(pdir));      // @T_END

    // ---- pass-through ----------------------------------------------------------
    wire v_e, use_e; wire [95:0] dir_e; wire [TAG_W-1:0] tag_e; wire [PAY_W-1:0] pay_e;
    valid_delay #(.N(T_END)) d_v (.clk(clk), .rst(rst), .d(in_valid), .q(v_e));
    delay #(.W(1 + 96 + TAG_W + PAY_W), .N(T_END)) d_pass (.clk(clk),
        .d({en & in_found, in_dir, in_tag, in_payload}), .q({use_e, dir_e, tag_e, pay_e}));

    always @(posedge clk) begin
        out_valid   <= rst ? 1'b0 : v_e;
        out_dir     <= use_e ? pdir : dir_e;
        out_tag     <= tag_e;
        out_payload <= pay_e;
    end
endmodule
