`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/24/2026 02:04:04 PM
// Design Name: 
// Module Name: mat_mem
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module mat_mem #(
    parameter integer mat_bytes = 1+(3*4)+(3*4), // byte smoothness, float3 emission, float3 absorption
    parameter integer max_mat_count = 4
)(
    input wire clk,
    input wire [mat_bytes*8-1:0] mat_in,
    input wire writing,
    input wire [$clog2(max_mat_count)-1:0] address,
    output reg [mat_bytes*8-1:0] mat_out
    );
    

    reg [mat_bytes*8-1:0] memory [0:max_mat_count-1];

    always @(posedge clk) begin
        if (writing)
            memory[address] <= mat_in;
        else
            mat_out <= memory[address];
    end
endmodule
