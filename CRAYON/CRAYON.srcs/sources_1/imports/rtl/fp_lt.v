`timescale 1ns / 1ps
// y = (a < b) for IEEE-754 single, purely combinational (a few dozen LUTs).
// Same semantics as C#: any NaN -> false, +0 == -0, denormals ordered correctly.
// For "a > b" instantiate with the operands swapped.
module fp_lt(
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg         y
);
    wire a_nan = (&a[30:23]) & (|a[22:0]);
    wire b_nan = (&b[30:23]) & (|b[22:0]);
    always @* begin
        if (a_nan || b_nan)                    y = 1'b0;
        else if (a[30:0] == 0 && b[30:0] == 0) y = 1'b0;
        else if (a[31] != b[31])               y = a[31];
        else if (!a[31])                       y = (a[30:0] < b[30:0]);
        else                                   y = (a[30:0] > b[30:0]);
    end
endmodule

// y = 2 * a, combinational. Bit-identical to the Xilinx multiply core
// (which flushes denormal inputs to signed zero). Exact: only the exponent moves.
module fp_mul2(
    input  wire [31:0] a,
    output reg  [31:0] y
);
    always @* begin
        if (a[30:23] == 8'd0)        y = {a[31], 31'd0};             // zero / denormal -> 0
        else if (a[30:23] == 8'hFF)  y = a;                          // inf / NaN
        else if (a[30:23] == 8'hFE)  y = {a[31], 8'hFF, 23'd0};      // overflow -> inf
        else                         y = {a[31], a[30:23] + 8'd1, a[22:0]};
    end
endmodule
