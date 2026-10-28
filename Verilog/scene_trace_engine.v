`timescale 1ns/1ps

// Stores uploaded Q16.16 geometry/rays and traces one ray against the scene at a time.
module scene_trace_engine #(
    parameter integer MAX_TRIANGLES = 256,
    parameter integer MAX_RAYS = 256
) (
    input wire clk,
    input wire reset,
    input wire scene_clear,
    input wire scene_write_valid,
    input wire [287:0] scene_write_data,
    input wire ray_write_valid,
    input wire [7:0] ray_write_index,
    input wire [191:0] ray_write_data,
    input wire batch_start,
    input wire [15:0] batch_ray_count,
    output reg result_valid,
    input wire result_ready,
    output reg result_hit,
    output reg [15:0] result_triangle_index,
    output reg signed [31:0] result_distance_q16
);
    localparam WAIT_BATCH = 3'd0;
    localparam START_RAY = 3'd1;
    localparam SEND_INTERSECTION = 3'd2;
    localparam WAIT_INTERSECTION = 3'd3;
    localparam PRESENT_RESULT = 3'd4;
    localparam [15:0] MAX_TRIANGLE_COUNT = 16'(MAX_TRIANGLES);
    localparam [15:0] MAX_RAY_COUNT = 16'(MAX_RAYS);

    reg [2:0] state;
    reg [15:0] scene_count;
    reg [15:0] ray_count;
    reg [15:0] ray_index;
    reg [15:0] triangle_index;
    reg best_hit;
    reg signed [31:0] best_distance;
    reg [15:0] best_triangle_index;

    // Vectors are packed {z, y, x}; x occupies bits [31:0].
    reg signed [95:0] ray_origin_mem [0:MAX_RAYS-1];
    reg signed [95:0] ray_direction_mem [0:MAX_RAYS-1];
    reg signed [95:0] triangle_v0 [0:MAX_TRIANGLES-1];
    reg signed [95:0] triangle_e1 [0:MAX_TRIANGLES-1];
    reg signed [95:0] triangle_e2 [0:MAX_TRIANGLES-1];

    reg core_in_valid;
    reg signed [95:0] core_ray_origin;
    reg signed [95:0] core_ray_direction;
    wire core_in_ready;
    wire core_out_valid;
    wire core_out_hit;
    wire signed [31:0] core_out_distance_q16;

    // A hit is eligible only when it is positive and nearer than the saved hit.
    wire candidate_is_better =
        core_out_hit &&
        core_out_distance_q16 > 0 &&
        core_out_distance_q16 < best_distance;
    wire final_triangle = triangle_index + 1 >= scene_count;

    // The engine issues one triangle per ray, waiting for each pipelined result.
    ray_triangle_pipeline intersection_pipeline (
        .clk(clk),
        .reset(reset),
        .in_valid(core_in_valid),
        .in_ready(core_in_ready),
        .ray_origin(core_ray_origin),
        .ray_direction(core_ray_direction),
        .triangle_v0(triangle_v0[triangle_index[7:0]]),
        .triangle_e1(triangle_e1[triangle_index[7:0]]),
        .triangle_e2(triangle_e2[triangle_index[7:0]]),
        .out_valid(core_out_valid),
        .out_ready(1'b1),
        .out_hit(core_out_hit),
        .out_distance_q16(core_out_distance_q16)
    );

    always @(posedge clk) begin
        if (reset) begin
            state <= WAIT_BATCH;
            scene_count <= 0;
            ray_count <= 0;
            ray_index <= 0;
            triangle_index <= 0;
            best_hit <= 1'b0;
            best_distance <= 0;
            best_triangle_index <= 0;
            core_in_valid <= 1'b0;
            core_ray_origin <= 0;
            core_ray_direction <= 0;
            result_valid <= 1'b0;
            result_hit <= 1'b0;
            result_triangle_index <= 0;
            result_distance_q16 <= 0;
        end else begin
            if (core_in_valid && core_in_ready)
                core_in_valid <= 1'b0;

            // Scene upload starts a new snapshot; valid records append in order.
            if (scene_clear)
                scene_count <= 0;

            if (scene_write_valid && scene_count < MAX_TRIANGLE_COUNT) begin
                triangle_v0[scene_count[7:0]] <= scene_write_data[95:0];
                triangle_e1[scene_count[7:0]] <= scene_write_data[191:96];
                triangle_e2[scene_count[7:0]] <= scene_write_data[287:192];
                scene_count <= scene_count + 1;
            end

            if (ray_write_valid && {8'b0, ray_write_index} < MAX_RAY_COUNT) begin
                ray_origin_mem[ray_write_index] <= ray_write_data[95:0];
                ray_direction_mem[ray_write_index] <= ray_write_data[191:96];
            end

            // Batch FSM: start a ray, visit all triangles, hold its result until accepted.
            case (state)
                WAIT_BATCH: begin
                    if (batch_start && batch_ray_count != 0) begin
                        ray_count <= batch_ray_count;
                        ray_index <= 0;
                        state <= START_RAY;
                    end
                end

                START_RAY: begin
                    core_ray_origin <= ray_origin_mem[ray_index[7:0]];
                    core_ray_direction <= ray_direction_mem[ray_index[7:0]];
                    triangle_index <= 0;
                    best_hit <= 1'b0;
                    best_distance <= 32'sh7FFFFFFF;
                    best_triangle_index <= 0;
                    if (scene_count == 0) begin
                        result_valid <= 1'b1;
                        result_hit <= 1'b0;
                        result_triangle_index <= 0;
                        result_distance_q16 <= 0;
                        state <= PRESENT_RESULT;
                    end else begin
                        core_in_valid <= 1'b1;
                        state <= SEND_INTERSECTION;
                    end
                end

                // Keep valid asserted until the pipeline accepts the input pair.
                SEND_INTERSECTION: begin
                    if (core_in_valid && core_in_ready)
                        state <= WAIT_INTERSECTION;
                end

                // Only update the best hit between accepted pipeline results.
                WAIT_INTERSECTION: begin
                    if (core_out_valid) begin
                        if (final_triangle) begin
                            result_valid <= 1'b1;
                            result_hit <= candidate_is_better || best_hit;
                            if (candidate_is_better) begin
                                result_triangle_index <= triangle_index;
                                result_distance_q16 <= core_out_distance_q16;
                            end else if (best_hit) begin
                                result_triangle_index <= best_triangle_index;
                                result_distance_q16 <= best_distance;
                            end else begin
                                result_triangle_index <= 0;
                                result_distance_q16 <= 0;
                            end
                            state <= PRESENT_RESULT;
                        end else begin
                            if (candidate_is_better) begin
                                best_hit <= 1'b1;
                                best_distance <= core_out_distance_q16;
                                best_triangle_index <= triangle_index;
                            end
                            triangle_index <= triangle_index + 1;
                            core_in_valid <= 1'b1;
                            state <= SEND_INTERSECTION;
                        end
                    end
                end

                // Ready/valid contract: result fields remain stable while not ready.
                PRESENT_RESULT: begin
                    if (result_valid && result_ready) begin
                        result_valid <= 1'b0;
                        if (ray_index + 1 >= ray_count) begin
                            state <= WAIT_BATCH;
                        end else begin
                            ray_index <= ray_index + 1;
                            state <= START_RAY;
                        end
                    end
                end

                default: state <= WAIT_BATCH;
            endcase
        end
    end
endmodule
