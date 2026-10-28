`timescale 1ns/1ps

// Three-component Q16.16 dot product using packed {z, y, x} vectors.
module q16_dot3 (
    input wire signed [95:0] left,
    input wire signed [95:0] right,
    output wire signed [31:0] result
);
    wire signed [31:0] x_product;
    wire signed [31:0] y_product;
    wire signed [31:0] z_product;

    q16_mul multiply_x (
        .left(left[31:0]),
        .right(right[31:0]),
        .product_q16(x_product)
    );

    q16_mul multiply_y (
        .left(left[63:32]),
        .right(right[63:32]),
        .product_q16(y_product)
    );

    q16_mul multiply_z (
        .left(left[95:64]),
        .right(right[95:64]),
        .product_q16(z_product)
    );

    assign result = x_product + y_product + z_product;
endmodule
