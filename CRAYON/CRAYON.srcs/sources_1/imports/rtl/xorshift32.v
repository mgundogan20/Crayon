`timescale 1ns / 1ps
// One xorshift32 step (13, 17, 5), combinational. Same as FpgaReference.XorShift().
module xorshift32(
    input  wire [31:0] s,
    output wire [31:0] y
);
    wire [31:0] a = s ^ (s << 13);
    wire [31:0] b = a ^ (a >> 17);
    assign y = b ^ (b << 5);
endmodule
