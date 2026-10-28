`timescale 1ns/1ps

// Component-wise subtraction of packed signed Q16.16 vectors.
module q16_sub3 (
    input wire signed [95:0] left,
    input wire signed [95:0] right,
    output wire signed [95:0] result
);
    assign result = {
        left[95:64] - right[95:64],
        left[63:32] - right[63:32],
        left[31:0] - right[31:0]
    };
endmodule
