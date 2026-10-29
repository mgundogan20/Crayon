`timescale 1ns / 1ps
// Data delay line (no reset -> maps onto SRL16/SRLC32, very cheap).
module delay #(
    parameter integer W = 32,
    parameter integer N = 1
)(
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    generate
        if (N == 0) begin : g_wire
            assign q = d;
        end else begin : g_sr
            reg [W-1:0] sr [0:N-1];
            integer i;
            always @(posedge clk) begin
                sr[0] <= d;
                for (i = 1; i < N; i = i + 1) sr[i] <= sr[i-1];
            end
            assign q = sr[N-1];
        end
    endgenerate
endmodule

// Valid-bit delay line with synchronous reset (flip-flops).
module valid_delay #(
    parameter integer N = 1
)(
    input  wire clk,
    input  wire rst,
    input  wire d,
    output wire q
);
    generate
        if (N == 0) begin : g_wire
            assign q = d;
        end else if (N == 1) begin : g_one
            reg r;
            always @(posedge clk) r <= rst ? 1'b0 : d;
            assign q = r;
        end else begin : g_sr
            reg [N-1:0] sr;
            always @(posedge clk) sr <= rst ? {N{1'b0}} : {sr[N-2:0], d};
            assign q = sr[N-1];
        end
    endgenerate
endmodule
