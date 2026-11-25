`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/24/2026 02:04:04 PM
// Design Name: 
// Module Name: bvh_mem
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


module bvh_mem #(
    parameter integer node_bytes = 4+4+4+4+(3*4)+(3*4), // int left, int right, int id, int morton, float3 center, float3 size
    parameter integer max_tree_depth = 16
)(
    input wire clk,
    input wire [node_bytes*8-1:0] node_in,
    input wire writing,
    input wire [$clog2(2**max_tree_depth)-1:0] address,
    output reg [node_bytes*8-1:0] node_out
    );
    
    localparam integer max_nodes = (2**max_tree_depth)-1;
    

    reg [node_bytes*8-1:0] memory [0:max_nodes-1];

    always @(posedge clk) begin
        if (writing)
            memory[address] <= node_in;
        else
            node_out <= memory[address];
    end
endmodule
