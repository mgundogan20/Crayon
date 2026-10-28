`timescale 1ns/1ps

// Signed Q16.16 multiply; discard the low 16 fractional product bits.
module q16_mul (
    input wire signed [31:0] left,
    input wire signed [31:0] right,
    output wire signed [31:0] product_q16
);
    wire signed [63:0] full_product = left * right;
    assign product_q16 = 32'(full_product >>> 16);
endmodule
