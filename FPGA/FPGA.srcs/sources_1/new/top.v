`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/24/2026 12:54:20 PM
// Design Name: 
// Module Name: top
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

module top #(
    parameter integer mat_bytes      = 1+(3*4)+(3*4),                        // byte smoothness, float3 emission, float3 absorption
    parameter integer max_mat_count  = 4,
    parameter integer tri_bytes      = 4+(3*4)+(3*4)+(3*4)+(3*4)+(3*4)+(3*4), // int material_id, float3 V0, E1, E2, N1, N2, N3
    parameter integer max_tri_count  = (2**16)-1,
    parameter integer node_bytes     = 4+4+4+4+(3*4)+(3*4),                  // int left, right, id, morton, float3 center, size
    parameter integer max_tree_depth = 16
)(
    input  wire clk,
    input  wire rst,
    input  wire uart_rx,
    output wire uart_tx
);

    // Material Memory
    wire [mat_bytes*8-1:0]           mat_in;
    wire [$clog2(max_mat_count)-1:0] address_mat;
    wire [mat_bytes*8-1:0]           mat_out;
    wire                             writing_mat;

    mat_mem #(.mat_bytes(mat_bytes), .max_mat_count(max_mat_count)) mat_mem(
        .clk(clk),
        .mat_in(mat_in),
        .writing(writing_mat),
        .address(address_mat),
        .mat_out(mat_out)
    );

    // Triangles Memory
    wire [tri_bytes*8-1:0]           tri_in;
    wire [$clog2(max_tri_count)-1:0] address_tri;
    wire [tri_bytes*8-1:0]           tri_out;
    wire                             writing_tri;

    tri_mem #(.tri_bytes(tri_bytes), .max_tri_count(max_tri_count)) tri_mem(
        .clk(clk),
        .tri_in(tri_in),
        .writing(writing_tri),
        .address(address_tri),
        .tri_out(tri_out)
    );

    // BVH nodes Memory
    wire [node_bytes*8-1:0]          node_in;
    wire [max_tree_depth-1:0]        address_bvh;
    wire [node_bytes*8-1:0]          node_out;
    wire                             writing_bvh;

    bvh_mem #(.node_bytes(node_bytes), .max_tree_depth(max_tree_depth)) bvh_mem(
        .clk(clk),
        .node_in(node_in),
        .writing(writing_bvh),
        .address(address_bvh),
        .node_out(node_out)
    );

    assign uart_tx = 1'b1;   // idle high until a UART transmitter is connected

endmodule
