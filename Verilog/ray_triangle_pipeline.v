`timescale 1ns/1ps

// Four-stage ready/valid Möller-Trumbore intersection datapath.
module ray_triangle_pipeline (
    input wire clk,
    input wire reset,
    input wire in_valid,
    output wire in_ready,
    input wire [95:0] ray_origin,
    input wire [95:0] ray_direction,
    input wire [95:0] triangle_v0,
    input wire [95:0] triangle_e1,
    input wire [95:0] triangle_e2,
    output wire out_valid,
    input wire out_ready,
    output reg out_hit,
    output reg signed [31:0] out_distance_q16
);
    reg valid0;
    reg valid1;
    reg valid2;
    reg valid3;
    wire ready0;
    wire ready1;
    wire ready2;
    wire ready3;

    // Stage 0: form p = direction x E2 and t = origin - V0.
    reg signed [95:0] s0_p;
    reg signed [95:0] s0_t;
    reg signed [95:0] s0_direction;
    reg signed [95:0] s0_e1;
    reg signed [95:0] s0_e2;

    // Stage 1: determinant and q = t x E1; retain values needed later.
    reg signed [31:0] s1_determinant;
    reg signed [95:0] s1_q;
    reg signed [95:0] s1_p;
    reg signed [95:0] s1_t;
    reg signed [95:0] s1_direction;
    reg signed [95:0] s1_e2;

    // Stage 2: barycentric numerators and the distance numerator.
    reg signed [31:0] s2_determinant;
    reg signed [31:0] s2_u_numerator;
    reg signed [31:0] s2_v_numerator;
    reg signed [31:0] s2_t_numerator;

    wire signed [95:0] stage0_p;
    wire signed [95:0] stage0_t;
    wire signed [31:0] stage1_determinant;
    wire signed [95:0] stage1_q;
    wire signed [31:0] stage2_u_numerator;
    wire signed [31:0] stage2_v_numerator;
    wire signed [31:0] stage2_t_numerator;

    // Keep an extra sign bit so u + v comparisons cannot overflow at 32 bits.
    wire signed [32:0] uv_sum =
        {s2_u_numerator[31], s2_u_numerator} +
        {s2_v_numerator[31], s2_v_numerator};
    wire signed [31:0] distance_q16;
    wire barycentric_inside =
        (s2_determinant > 0)
            ? (s2_u_numerator >= 0 &&
               s2_u_numerator <= s2_determinant &&
               s2_v_numerator >= 0 &&
               uv_sum <= {s2_determinant[31], s2_determinant})
            : (s2_determinant < 0 &&
               s2_u_numerator <= 0 &&
               s2_u_numerator >= s2_determinant &&
               s2_v_numerator <= 0 &&
               uv_sum >= {s2_determinant[31], s2_determinant});

    // Backpressure propagates from output to input; occupied stages hold data.
    assign ready3 = !valid3 || out_ready;
    assign ready2 = !valid2 || ready3;
    assign ready1 = !valid1 || ready2;
    assign ready0 = !valid0 || ready1;
    assign in_ready = ready0;
    assign out_valid = valid3;

    // Arithmetic is factored into small combinational units for reuse and probing.
    q16_cross3 stage0_cross (
        .left(ray_direction),
        .right(triangle_e2),
        .result(stage0_p)
    );

    q16_sub3 stage0_subtract (
        .left(ray_origin),
        .right(triangle_v0),
        .result(stage0_t)
    );

    q16_dot3 stage1_dot (
        .left(s0_e1),
        .right(s0_p),
        .result(stage1_determinant)
    );

    q16_cross3 stage1_cross (
        .left(s0_t),
        .right(s0_e1),
        .result(stage1_q)
    );

    q16_dot3 stage2_u_dot (
        .left(s1_t),
        .right(s1_p),
        .result(stage2_u_numerator)
    );

    q16_dot3 stage2_v_dot (
        .left(s1_direction),
        .right(s1_q),
        .result(stage2_v_numerator)
    );

    q16_dot3 stage2_t_dot (
        .left(s1_e2),
        .right(s1_q),
        .result(stage2_t_numerator)
    );

    q16_div stage3_divide (
        .numerator(s2_t_numerator),
        .denominator(s2_determinant),
        .quotient_q16(distance_q16)
    );

    // Each stage advances only when downstream storage is available.
    always @(posedge clk) begin
        if (reset) begin
            valid0 <= 1'b0;
            valid1 <= 1'b0;
            valid2 <= 1'b0;
            valid3 <= 1'b0;
            out_hit <= 1'b0;
            out_distance_q16 <= 32'sd0;
        end else begin
            if (ready0) begin
                valid0 <= in_valid;
                if (in_valid) begin
                    s0_p <= stage0_p;
                    s0_t <= stage0_t;
                    s0_direction <= ray_direction;
                    s0_e1 <= triangle_e1;
                    s0_e2 <= triangle_e2;
                end
            end

            if (ready1) begin
                valid1 <= valid0;
                if (valid0) begin
                    s1_determinant <= stage1_determinant;
                    s1_q <= stage1_q;
                    s1_p <= s0_p;
                    s1_t <= s0_t;
                    s1_direction <= s0_direction;
                    s1_e2 <= s0_e2;
                end
            end

            if (ready2) begin
                valid2 <= valid1;
                if (valid1) begin
                    s2_u_numerator <= stage2_u_numerator;
                    s2_v_numerator <= stage2_v_numerator;
                    s2_t_numerator <= stage2_t_numerator;
                    s2_determinant <= s1_determinant;
                end
            end

            if (ready3) begin
                valid3 <= valid2;
                if (valid2) begin
                    out_hit <= barycentric_inside && distance_q16 > 0;
                    out_distance_q16 <= distance_q16;
                end
            end
        end
    end

endmodule
