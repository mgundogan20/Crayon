`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/24/2026 02:04:04 PM
// Design Name: 
// Module Name: tri_mem
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


module tri_mem #(
    parameter integer tri_bytes = 4+(3*4)+(3*4)+(3*4)+(3*4)+(3*4)+(3*4), // int material_id, float3 V0, float3 E1, float3 E2, float3 N1, float3 N2, float3 N3
    parameter integer max_tri_count = (2048)
)(
    input wire clk,
    input wire [tri_bytes*8-1:0] tri_in,
    input wire writing,
    input wire [$clog2(max_tri_count)-1:0] address,
    output reg [tri_bytes*8-1:0] tri_out
    );
    

    reg [tri_bytes*8-1:0] memory [0:max_tri_count-1];

    always @(posedge clk) begin
        if (writing)
            memory[address] <= tri_in;
        else
            tri_out <= memory[address];
    end
endmodule
