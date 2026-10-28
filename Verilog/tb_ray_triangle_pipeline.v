`timescale 1ns/1ps

module tb_ray_triangle_pipeline;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg in_valid = 1'b0;
    wire in_ready;
    reg [95:0] ray_origin = 0;
    reg [95:0] ray_direction = 0;
    reg [95:0] triangle_v0 = 0;
    reg [95:0] triangle_e1 = 0;
    reg [95:0] triangle_e2 = 0;
    wire out_valid;
    reg out_ready = 1'b1;
    wire out_hit;
    wire signed [31:0] out_distance_q16;
    integer failures = 0;

    always #5 clk = ~clk;

    ray_triangle_pipeline dut (
        .clk(clk),
        .reset(reset),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .ray_origin(ray_origin),
        .ray_direction(ray_direction),
        .triangle_v0(triangle_v0),
        .triangle_e1(triangle_e1),
        .triangle_e2(triangle_e2),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_hit(out_hit),
        .out_distance_q16(out_distance_q16)
    );

    task send_case;
        input [95:0] origin;
        input [95:0] direction;
        input expected_hit;
        input signed [31:0] expected_distance;
        begin
            @(negedge clk);
            while (!in_ready)
                @(negedge clk);
            ray_origin = origin;
            ray_direction = direction;
            triangle_v0 = {32'sd0, 32'sd0, 32'sd0};
            triangle_e1 = {32'sd65536, 32'sd0, 32'sd0};
            triangle_e2 = {32'sd0, 32'sd65536, 32'sd0};
            in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
            wait (out_valid);
            #1;
            if (out_hit !== expected_hit ||
                (expected_hit && out_distance_q16 !== expected_distance)) begin
                $display(
                    "FAIL expected hit=%0d distance=%0d, got hit=%0d distance=%0d",
                    expected_hit,
                    expected_distance,
                    out_hit,
                    out_distance_q16
                );
                failures = failures + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 1'b0;

        send_case(
            {32'sd16384, 32'sd16384, 32'sd65536},
            {32'sd0, 32'sd0, -32'sd65536},
            1'b1,
            32'sd65536
        );
        send_case(
            {32'sd16384, 32'sd16384, -32'sd65536},
            {32'sd0, 32'sd0, 32'sd65536},
            1'b1,
            32'sd65536
        );
        send_case(
            {32'sd81920, 32'sd16384, 32'sd65536},
            {32'sd0, 32'sd0, -32'sd65536},
            1'b0,
            32'sd0
        );
        send_case(
            {32'sd16384, 32'sd16384, -32'sd131072},
            {32'sd0, 32'sd0, 32'sd65536},
            1'b1,
            32'sd131072
        );
        send_case(
            {32'sd16384, 32'sd16384, 32'sd65536},
            {32'sd65536, 32'sd0, 32'sd0},
            1'b0,
            32'sd0
        );
        send_case(
            {32'sd16384, 32'sd16384, -32'sd65536},
            {32'sd0, 32'sd0, -32'sd65536},
            1'b0,
            32'sd0
        );

        if (failures == 0) begin
            $display("PASS: ray_triangle_pipeline vectors");
            $finish;
        end else begin
            $display("FAIL: %0d vector(s) failed", failures);
            $fatal(1);
        end
    end
endmodule
