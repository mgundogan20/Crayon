`timescale 1ns/1ps

// Computes (numerator << 16) / denominator; zero denominator returns zero.
module q16_div (
    input wire signed [31:0] numerator,
    input wire signed [31:0] denominator,
    output wire signed [31:0] quotient_q16
);
    wire signed [63:0] scaled_numerator =
        {{32{numerator[31]}}, numerator} <<< 16;
    wire signed [63:0] extended_denominator =
        {{32{denominator[31]}}, denominator};
    assign quotient_q16 = denominator == 0
        ? 32'sd0
        : 32'(scaled_numerator / extended_denominator);
endmodule
