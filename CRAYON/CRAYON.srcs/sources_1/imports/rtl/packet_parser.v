`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// packet_parser -- one state machine for all packet types (payload bytes can
// never be mistaken for a header). All fields little-endian.
//
// Triangles: A5 5A | count u16 | count x 15 float32 (V0, E1, E2, diffuse, emission)
// Rays     : A5 5B | count u16 | bounces u8 | flags u8 | seed u32 |
//            count x 6 float32 (origin, direction)                -> starts a frame
// Camera   : A5 5C | X_res u16 | Y_res u16 | bounces u8 | flags u8 | seed u32 |
//            fov f32 | position 3f | forward 3f | right 3f | up 3f -> starts a frame
// flags: bit0 = perturb after each bounce, bit1 = primary-ray jitter (camera only)
//////////////////////////////////////////////////////////////////////////////////
module packet_parser #(
    parameter integer MAX_TRIANGLES = 128,
    parameter integer TAW           = 7,
    parameter integer MAX_RAYS      = 4096,
    parameter integer RAW           = 12
)(
    input  wire           clk,
    input  wire           rst,
    input  wire [7:0]     rx_data,
    input  wire           rx_valid,

    // triangles
    output reg            tri_we,
    output reg  [TAW-1:0] tri_idx,
    output reg  [3:0]     tri_slot,
    output reg  [31:0]    tri_wdata,
    output reg  [15:0]    tri_count,
    output reg            tris_done,

    // rays
    output reg            ray_we,
    output reg  [RAW-1:0] ray_addr,
    output reg  [191:0]   ray_wdata,     // {dir, origin}
    output reg  [15:0]    ray_count,
    output reg            rays_done,

    // camera
    output reg  [15:0]    cam_xres,
    output reg  [15:0]    cam_yres,
    output wire [31:0]    cam_fov,
    output wire [95:0]    cam_pos,
    output wire [95:0]    cam_fwd,
    output wire [95:0]    cam_right,
    output wire [95:0]    cam_up,
    output reg            cam_done,

    // shared by ray and camera packets
    output reg  [7:0]     bounces,
    output reg  [7:0]     flags,
    output reg  [31:0]    seed,

    output reg            packet_error
);
    localparam [2:0] S_SYNC = 3'd0, S_TYPE = 3'd1, S_HDR = 3'd2, S_HDRDONE = 3'd3,
                     S_TDATA = 3'd4, S_RDATA = 3'd5, S_CDATA = 3'd6;
    localparam [1:0] P_TRI = 2'd0, P_RAY = 2'd1, P_CAM = 2'd2;

    reg [2:0]   state;
    reg [1:0]   ptype;
    reg [3:0]   hdr_i, hdr_last;
    reg [79:0]  hbuf;
    reg [1:0]   byte_in_word;
    reg [23:0]  word_lo;
    reg [3:0]   slot;
    reg [15:0]  item;
    reg [159:0] ray_acc;
    reg [415:0] cam_buf;     // {up, right, fwd, pos, fov}
    reg         done_t, done_r, done_c;

    wire [31:0] word = {rx_data, word_lo};

    assign cam_fov   = cam_buf[31:0];
    assign cam_pos   = cam_buf[127:32];
    assign cam_fwd   = cam_buf[223:128];
    assign cam_right = cam_buf[319:224];
    assign cam_up    = cam_buf[415:320];

    always @(posedge clk) begin
        if (rst) begin
            state <= S_SYNC; tri_we <= 0; ray_we <= 0;
            tris_done <= 0; rays_done <= 0; cam_done <= 0; packet_error <= 0;
            done_t <= 0; done_r <= 0; done_c <= 0;
            tri_count <= 0; ray_count <= 0; cam_xres <= 0; cam_yres <= 0;
            bounces <= 0; flags <= 0; seed <= 0;
            byte_in_word <= 0; slot <= 0; item <= 0; hdr_i <= 0; hdr_last <= 0; ptype <= P_TRI;
        end else begin
            tri_we       <= 1'b0;
            ray_we       <= 1'b0;
            packet_error <= 1'b0;
            tris_done    <= done_t;  done_t <= 1'b0;   // one cycle after the last write
            rays_done    <= done_r;  done_r <= 1'b0;
            cam_done     <= done_c;  done_c <= 1'b0;

            if (state == S_HDRDONE) begin              // header complete (no byte consumed)
                byte_in_word <= 0; slot <= 0; item <= 0;
                case (ptype)
                    P_TRI: begin
                        tri_count <= hbuf[15:0];
                        if (hbuf[15:0] > MAX_TRIANGLES) begin packet_error <= 1'b1; state <= S_SYNC; end
                        else if (hbuf[15:0] == 16'd0)   begin done_t <= 1'b1;       state <= S_SYNC; end
                        else                                  state <= S_TDATA;
                    end
                    P_RAY: begin
                        ray_count <= hbuf[15:0];
                        bounces   <= hbuf[23:16];
                        flags     <= hbuf[31:24];
                        seed      <= hbuf[63:32];
                        if (hbuf[15:0] > MAX_RAYS)    begin packet_error <= 1'b1; state <= S_SYNC; end
                        else if (hbuf[15:0] == 16'd0) begin done_r <= 1'b1;       state <= S_SYNC; end
                        else                                state <= S_RDATA;
                    end
                    default: begin
                        cam_xres <= hbuf[15:0];
                        cam_yres <= hbuf[31:16];
                        bounces  <= hbuf[39:32];
                        flags    <= hbuf[47:40];
                        seed     <= hbuf[79:48];
                        state    <= S_CDATA;
                    end
                endcase
            end else if (rx_valid) begin
                case (state)
                    S_SYNC: if (rx_data == 8'hA5) state <= S_TYPE;

                    S_TYPE: begin
                        hdr_i <= 0;
                        if      (rx_data == 8'h5A) begin ptype <= P_TRI; hdr_last <= 4'd1; state <= S_HDR; end
                        else if (rx_data == 8'h5B) begin ptype <= P_RAY; hdr_last <= 4'd7; state <= S_HDR; end
                        else if (rx_data == 8'h5C) begin ptype <= P_CAM; hdr_last <= 4'd9; state <= S_HDR; end
                        else if (rx_data != 8'hA5) state <= S_SYNC;
                    end

                    S_HDR: begin
                        hbuf[8*hdr_i +: 8] <= rx_data;
                        hdr_i <= hdr_i + 1'b1;
                        if (hdr_i == hdr_last) state <= S_HDRDONE;
                    end

                    S_TDATA: begin
                        if (byte_in_word != 2'd3) begin
                            word_lo[8*byte_in_word +: 8] <= rx_data;
                            byte_in_word <= byte_in_word + 1'b1;
                        end else begin
                            byte_in_word <= 0;
                            tri_we    <= 1'b1;
                            tri_idx   <= item[TAW-1:0];
                            tri_slot  <= slot;
                            tri_wdata <= word;
                            if (slot == 4'd14) begin
                                slot <= 0;
                                if (item == tri_count - 1'b1) begin done_t <= 1'b1; state <= S_SYNC; end
                                else item <= item + 1'b1;
                            end else
                                slot <= slot + 1'b1;
                        end
                    end

                    S_RDATA: begin
                        if (byte_in_word != 2'd3) begin
                            word_lo[8*byte_in_word +: 8] <= rx_data;
                            byte_in_word <= byte_in_word + 1'b1;
                        end else begin
                            byte_in_word <= 0;
                            if (slot == 4'd5) begin
                                slot      <= 0;
                                ray_we    <= 1'b1;
                                ray_addr  <= item[RAW-1:0];
                                ray_wdata <= {word, ray_acc};
                                if (item == ray_count - 1'b1) begin done_r <= 1'b1; state <= S_SYNC; end
                                else item <= item + 1'b1;
                            end else begin
                                ray_acc <= {word, ray_acc[159:32]};
                                slot    <= slot + 1'b1;
                            end
                        end
                    end

                    S_CDATA: begin
                        if (byte_in_word != 2'd3) begin
                            word_lo[8*byte_in_word +: 8] <= rx_data;
                            byte_in_word <= byte_in_word + 1'b1;
                        end else begin
                            byte_in_word <= 0;
                            cam_buf <= {word, cam_buf[415:32]};
                            if (slot == 4'd12) begin done_c <= 1'b1; state <= S_SYNC; end
                            else slot <= slot + 1'b1;
                        end
                    end

                    default: state <= S_SYNC;
                endcase
            end
        end
    end
endmodule
