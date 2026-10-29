`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// rt_core -- frame controller + datapath.
//
// Two ways to start a frame:
//  * ray packet    : rays come from the PC (<= MAX_RAYS), one batch.
//  * camera packet : rays are generated on the FPGA (raygen + perturb),
//                    any resolution up to 65535 x 65535, processed in batches
//                    of MAX_RAYS rays (the ray memory size).
//
//  IDLE -> [GEN -> GENWAIT] -> TRACE -> DRAIN (x bounces) -> SEND -> WAITTX
//          '------------- next batch (camera mode) ---------------------'
//
//  GEN    : feed pixels to raygen (one per ~140 clocks, 4 DSP48); rays are jittered by
//           perturb (narrow mode) and written into the ray memories.
//  TRACE  : one (ray, tri) pair per clock -> intersect -> closest_hit ->
//           shade -> perturb -> write back.  DRAIN waits for all write-backs.
//  SEND   : result packet (A5 5D) with this batch's accum_col values.
//
// Pixel order is x-major (x outer, y inner), like FakePGA.GeneratePrimaries,
// so batch b holds pixels b*MAX_RAYS ... in that order.
// RNG draws: per batch, first one draw-pair per generated ray, then one per
// ray per bounce (FpgaReference does the same).
//////////////////////////////////////////////////////////////////////////////////
module rt_core #(
    parameter integer MAX_TRIANGLES = 128,
    parameter integer TAW           = 7,
    parameter integer MAX_RAYS      = 4096,
    parameter integer RAW           = 12,
    parameter integer LAT_DIV       = 28,
    parameter integer LAT_SQRT      = 28
)(
    input  wire           clk,
    input  wire           rst,

    // from packet_parser
    input  wire           tri_we,
    input  wire [TAW-1:0] tri_idx,
    input  wire [3:0]     tri_slot,
    input  wire [31:0]    tri_wdata,
    input  wire [15:0]    tri_count,
    input  wire           ray_we,
    input  wire [RAW-1:0] ray_addr,
    input  wire [191:0]   ray_wdata,
    input  wire [15:0]    ray_count,
    input  wire           rays_done,
    input  wire [15:0]    cam_xres,
    input  wire [15:0]    cam_yres,
    input  wire [31:0]    cam_fov,
    input  wire [95:0]    cam_pos,
    input  wire [95:0]    cam_fwd,
    input  wire [95:0]    cam_right,
    input  wire [95:0]    cam_up,
    input  wire           cam_done,
    input  wire [7:0]     bounces,
    input  wire [7:0]     flags,
    input  wire [31:0]    seed,

    // to uart_tx
    output wire           tx_start,
    output wire [7:0]     tx_data,
    input  wire           tx_ready,

    // status
    output wire           busy,
    output reg            frame_done,
    output reg            overrun,
    output wire [7:0]     bounce_dbg
);
    localparam [31:0] FP_ONE = 32'h3F80_0000;
    localparam integer TAG_W = RAW + TAW + 3;   // {ray, tri, first, last, kill}

    localparam [2:0] S_IDLE = 3'd0, S_GEN = 3'd1, S_GENWAIT = 3'd2, S_TRACE = 3'd3,
                     S_DRAIN = 3'd4, S_SEND = 3'd5, S_WAITTX = 3'd6;
    reg [2:0] state;
    assign busy = (state != S_IDLE);

    // ---------------- frame / batch parameters ---------------------------------
    reg [15:0]    n_rays;            // rays in the current batch
    reg [RAW-1:0] last_ray;
    reg [TAW-1:0] last_tri;
    reg           no_tris;
    reg [7:0]     n_bounces, bounce;
    reg           perturb_en, jitter_en;
    reg           seed_load;
    reg           cam_mode;
    assign bounce_dbg = bounce;

    // camera (latched at frame start, the parser may be overwritten later)
    reg [15:0]    xres, yres;
    reg [31:0]    fov;
    reg [95:0]    c_pos, c_fwd, c_right, c_up;
    reg [15:0]    gx, gy;            // next pixel to generate
    reg           pix_done;          // every pixel of the frame has been generated
    reg [RAW:0]   gen_cnt;

    // ---------------- counters ------------------------------------------------
    reg           run;
    reg [RAW-1:0] cr;
    reg [TAW-1:0] ck;
    reg [15:0]    wb_count;
    reg           tx_go;
    wire          tx_busy;

    // ---------------- memories ------------------------------------------------
    wire           wb_valid;
    wire [RAW-1:0] wb_addr;
    wire [383:0]   wb_data;

    wire           rmem_we    = busy ? wb_valid : ray_we;
    wire [RAW-1:0] rmem_waddr = busy ? wb_addr  : ray_addr;
    wire [383:0]   rmem_wdata = busy ? wb_data
                              : {96'd0, FP_ONE, FP_ONE, FP_ONE, ray_wdata};   // accum = 0, ray_col = 1
    wire           tmem_we    = tri_we & ~busy;

    wire [479:0]   tri_i_q, tri_s_q;
    wire [191:0]   ray_i_q;
    wire [383:0]   ray_s_q;
    wire [TAW-1:0] tri_s_addr;
    wire [RAW-1:0] ray_s_addr;

    tri_mem #(.MAX_TRIANGLES(MAX_TRIANGLES), .AW(TAW)) u_tri_i (.clk(clk),
        .we(tmem_we), .w_tri(tri_idx), .w_slot(tri_slot), .w_data(tri_wdata), .r_tri(ck), .r_data(tri_i_q));
    tri_mem #(.MAX_TRIANGLES(MAX_TRIANGLES), .AW(TAW)) u_tri_s (.clk(clk),
        .we(tmem_we), .w_tri(tri_idx), .w_slot(tri_slot), .w_data(tri_wdata), .r_tri(tri_s_addr), .r_data(tri_s_q));
    ray_mem #(.W(192), .DEPTH(MAX_RAYS), .AW(RAW)) u_ray_i (.clk(clk),
        .we(rmem_we), .waddr(rmem_waddr), .wdata(rmem_wdata[191:0]), .raddr(cr), .rdata(ray_i_q));
    ray_mem #(.W(384), .DEPTH(MAX_RAYS), .AW(RAW)) u_ray_s (.clk(clk),
        .we(rmem_we), .waddr(rmem_waddr), .wdata(rmem_wdata), .raddr(ray_s_addr), .rdata(ray_s_q));

    // ---------------- FSM -----------------------------------------------------
    wire last_pix = (gx == xres - 1'b1) && (gy == yres - 1'b1);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; run <= 1'b0; frame_done <= 1'b0; overrun <= 1'b0;
            seed_load <= 1'b0; tx_go <= 1'b0; bounce <= 0; cam_mode <= 1'b0;
            wb_count <= 0; g_start <= 1'b0;
        end else begin
            seed_load <= 1'b0;
            tx_go     <= 1'b0;
            g_start   <= 1'b0;
            if (busy && (ray_we || tri_we)) overrun <= 1'b1;
            if (wb_valid) wb_count <= wb_count + 1'b1;       // resets below only happen when nothing is in flight

            case (state)
                S_IDLE: begin
                    no_tris   <= (tri_count == 0);
                    last_tri  <= (tri_count == 0) ? {TAW{1'b0}} : tri_count[TAW-1:0] - 1'b1;
                    n_bounces <= bounces;
                    perturb_en <= flags[0];
                    jitter_en  <= flags[1];
                    bounce    <= 0;
                    cr <= 0; ck <= 0; wb_count <= 0; gen_cnt <= 0;
                    if (rays_done) begin                      // rays from the PC
                        cam_mode   <= 1'b0;
                        n_rays     <= ray_count;
                        last_ray   <= ray_count[RAW-1:0] - 1'b1;
                        seed_load  <= 1'b1;
                        frame_done <= 1'b0; overrun <= 1'b0;
                        if (ray_count == 0 || bounces == 0) begin tx_go <= 1'b1; state <= S_SEND; end
                        else begin run <= 1'b1; state <= S_TRACE; end
                    end else if (cam_done) begin              // rays generated here
                        cam_mode <= 1'b1;
                        xres <= cam_xres; yres <= cam_yres; fov <= cam_fov;
                        c_pos <= cam_pos; c_fwd <= cam_fwd; c_right <= cam_right; c_up <= cam_up;
                        gx <= 0; gy <= 0;
                        pix_done   <= 1'b0;
                        seed_load  <= 1'b1;
                        frame_done <= 1'b0; overrun <= 1'b0;
                        if (cam_xres == 0 || cam_yres == 0) frame_done <= 1'b1;   // nothing to do
                        else state <= S_GEN;
                    end
                end

                S_GEN: if (g_ready && !g_start) begin        // one pixel per raygen slot
                    g_start  <= 1'b1;
                    g_ix     <= $signed({2'b00, gx}) - $signed({3'b000, xres[15:1]});   // x - X_res/2
                    g_iy     <= $signed({2'b00, gy}) - $signed({3'b000, yres[15:1]});   // y - Y_res/2
                    g_in_tag <= gen_cnt[RAW-1:0];
                    gen_cnt  <= gen_cnt + 1'b1;
                    if (gy == yres - 1'b1) begin gy <= 0; gx <= gx + 1'b1; end
                    else gy <= gy + 1'b1;
                    if (last_pix) pix_done <= 1'b1;
                    if (last_pix || gen_cnt == MAX_RAYS - 1) begin
                        n_rays   <= gen_cnt + 1'b1;
                        last_ray <= gen_cnt[RAW-1:0];
                        state    <= S_GENWAIT;
                    end
                end

                S_GENWAIT: if (wb_count == n_rays) begin
                    wb_count <= 0;
                    bounce   <= 0;
                    cr <= 0; ck <= 0;
                    if (n_bounces == 0) begin tx_go <= 1'b1; state <= S_SEND; end
                    else begin run <= 1'b1; state <= S_TRACE; end
                end

                S_TRACE: begin
                    if (ck == last_tri) begin
                        ck <= 0;
                        if (cr == last_ray) begin run <= 1'b0; state <= S_DRAIN; end
                        else cr <= cr + 1'b1;
                    end else
                        ck <= ck + 1'b1;
                end

                S_DRAIN: if (wb_count == n_rays) begin
                    wb_count <= 0;
                    cr <= 0; ck <= 0;
                    if (bounce + 1'b1 == n_bounces) begin tx_go <= 1'b1; state <= S_SEND; end
                    else begin bounce <= bounce + 1'b1; run <= 1'b1; state <= S_TRACE; end
                end

                S_SEND:   state <= S_WAITTX;
                S_WAITTX: if (!tx_busy) begin
                    if (cam_mode && !pix_done) begin           // next batch
                        gen_cnt <= 0; wb_count <= 0; bounce <= 0;
                        state <= S_GEN;
                    end else begin
                        frame_done <= 1'b1; state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------- ray generation (shared cores, 4 DSP48) -------------------
    reg               g_start;
    reg signed [17:0] g_ix, g_iy;
    reg [RAW-1:0]     g_in_tag;
    wire              g_ready, g_v;
    wire [95:0]       g_dir;
    wire [RAW-1:0]    g_tag;
    raygen #(.TAG_W(RAW), .LAT_DIV(LAT_DIV), .LAT_SQRT(LAT_SQRT)) u_gen (
        .clk(clk), .rst(rst), .start(g_start), .ready(g_ready),
        .ix(g_ix), .iy(g_iy), .in_tag(g_in_tag),
        .fov(fov), .fwd(c_fwd), .right(c_right), .up(c_up),
        .out_valid(g_v), .out_dir(g_dir), .out_tag(g_tag));

    // ---------------- issue stage ---------------------------------------------
    reg           iss_v, iss_first, iss_last;
    reg [RAW-1:0] iss_r;
    reg [TAW-1:0] iss_k;
    always @(posedge clk) begin
        iss_v     <= rst ? 1'b0 : run;
        iss_r     <= cr;
        iss_k     <= ck;
        iss_first <= (ck == 0);
        iss_last  <= (ck == last_tri);
    end

    // ---------------- intersect -----------------------------------------------
    wire             x_valid, x_hit;
    wire [31:0]      x_t;
    wire [TAG_W-1:0] x_tag;
    intersect #(.TAG_W(TAG_W), .LAT_DIV(LAT_DIV)) u_isect (
        .clk(clk), .rst(rst), .in_valid(iss_v),
        .ray_o(ray_i_q[95:0]), .ray_d(ray_i_q[191:96]),
        .v0(tri_i_q[95:0]), .e1(tri_i_q[191:96]), .e2(tri_i_q[287:192]),
        .in_tag({iss_r, iss_k, iss_first, iss_last, no_tris}),
        .out_valid(x_valid), .out_hit(x_hit), .out_t(x_t), .out_tag(x_tag));

    // ---------------- closest hit ---------------------------------------------
    wire           ch_valid, ch_found;
    wire [31:0]    ch_t;
    wire [TAW-1:0] ch_tri;
    wire [RAW-1:0] ch_ray;
    closest_hit #(.TRI_W(TAW), .RAY_W(RAW)) u_ch (
        .clk(clk), .rst(rst), .in_valid(x_valid),
        .in_hit(x_hit & ~x_tag[0]),
        .in_t(x_t), .in_tri(x_tag[TAW+2:3]), .in_ray(x_tag[TAG_W-1 -: RAW]),
        .in_first(x_tag[2]), .in_last(x_tag[1]),
        .out_valid(ch_valid), .out_found(ch_found), .out_t(ch_t), .out_tri(ch_tri), .out_ray(ch_ray));

    // ---------------- fetch ray + winning triangle ----------------------------
    wire [RAW-1:0] tx_addr;
    assign tri_s_addr = ch_tri;
    assign ray_s_addr = (state == S_SEND || state == S_WAITTX) ? tx_addr : ch_ray;

    reg            sh_v, sh_found;
    reg [31:0]     sh_t;
    reg [RAW-1:0]  sh_r;
    always @(posedge clk) begin
        sh_v     <= rst ? 1'b0 : ch_valid;
        sh_found <= ch_found;
        sh_t     <= ch_t;
        sh_r     <= ch_ray;
    end

    // ---------------- shade ---------------------------------------------------
    wire           s_valid, s_found;
    wire [RAW-1:0] s_tag;
    wire [95:0]    s_o, s_d, s_rc, s_ac;
    shade #(.TAG_W(RAW), .LAT_DIV(LAT_DIV), .LAT_SQRT(LAT_SQRT)) u_shade (
        .clk(clk), .rst(rst), .in_valid(sh_v), .in_tag(sh_r), .found(sh_found), .t(sh_t),
        .origin(ray_s_q[95:0]), .dir(ray_s_q[191:96]), .ray_col(ray_s_q[287:192]), .accum_col(ray_s_q[383:288]),
        .e1(tri_s_q[191:96]), .e2(tri_s_q[287:192]), .diffuse(tri_s_q[383:288]), .emission(tri_s_q[479:384]),
        .out_valid(s_valid), .out_tag(s_tag), .out_found(s_found),
        .out_origin(s_o), .out_dir(s_d), .out_ray_col(s_rc), .out_accum_col(s_ac));

    // ---------------- perturb (shared by raygen and shade) + write-back -------
    // raygen and shade are never active at the same time.
    wire [95:0]  p_dir;
    wire [287:0] p_pay;   // {accum, ray_col, origin}
    perturb #(.TAG_W(RAW), .PAY_W(288), .LAT_DIV(LAT_DIV), .LAT_SQRT(LAT_SQRT)) u_pert (
        .clk(clk), .rst(rst), .seed_load(seed_load), .seed(seed),
        .en(g_v ? jitter_en : perturb_en),
        .in_valid(g_v | s_valid),
        .in_narrow(g_v),
        .in_found(g_v | s_found),
        .in_dir(g_v ? g_dir : s_d),
        .in_tag(g_v ? g_tag : s_tag),
        .in_payload(g_v ? {96'd0, FP_ONE, FP_ONE, FP_ONE, c_pos} : {s_ac, s_rc, s_o}),
        .out_valid(wb_valid), .out_dir(p_dir), .out_tag(wb_addr), .out_payload(p_pay));
    assign wb_data = {p_pay[287:96], p_dir, p_pay[95:0]};

    // ---------------- result transmitter (one packet per batch) ---------------
    result_tx #(.RAW(RAW)) u_rtx (
        .clk(clk), .rst(rst), .start(tx_go), .count(n_rays), .busy(tx_busy),
        .mem_addr(tx_addr), .mem_accum(ray_s_q[383:288]),
        .tx_start(tx_start), .tx_data(tx_data), .tx_ready(tx_ready));
endmodule