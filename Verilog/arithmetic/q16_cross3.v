`timescale 1ns/1ps

// Three-component Q16.16 cross product using packed {z, y, x} vectors.
module q16_cross3 (
    input wire signed [95:0] left,
    input wire signed [95:0] right,
    output wire signed [95:0] result
);
    wire signed [31:0] xy;
    wire signed [31:0] yx;
    wire signed [31:0] yz;
    wire signed [31:0] zy;
    wire signed [31:0] zx;
    wire signed [31:0] xz;

    q16_mul multiply_xy (.left(left[63:32]), .right(right[95:64]), .product_q16(xy));
    q16_mul multiply_yx (.left(left[95:64]), .right(right[63:32]), .product_q16(yx));
    q16_mul multiply_yz (.left(left[95:64]), .right(right[31:0]), .product_q16(yz));
    q16_mul multiply_zy (.left(left[31:0]), .right(right[95:64]), .product_q16(zy));
    q16_mul multiply_zx (.left(left[31:0]), .right(right[63:32]), .product_q16(zx));
    q16_mul multiply_xz (.left(left[63:32]), .right(right[31:0]), .product_q16(xz));

    assign result = {
        zx - xz,
        yz - zy,
        xy - yx
    };
endmodule
