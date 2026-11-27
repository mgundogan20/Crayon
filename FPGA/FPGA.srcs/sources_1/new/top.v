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
    parameter integer max_tri_count  = (2**11)-1,
    parameter integer node_bytes     = 4+4+4+4+(3*4)+(3*4),                  // int left, right, id, morton, float3 center, size
    parameter integer max_tree_depth = 12,
    parameter integer CLK_HZ             = 100_000_000, // shared by uart_rx/uart_tx
    parameter integer BAUD               = 3_000_000,
    parameter integer mat_address_bytes  = 1,
    parameter integer tri_address_bytes  = 2,
    parameter integer node_address_bytes = 2
)(
    input  wire clk,
    input  wire rst,
    input  wire uart_rx,
    output wire uart_tx,
    output wire load_done
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

    // UART receiver
    wire       rx_valid;
    wire [7:0] rx_data;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) uart_rx_inst(
        .clk(clk),
        .rst(rst),
        .uart_rx(uart_rx),
        .rx_valid(rx_valid),
        .rx_data(rx_data)
    );

    // UART transmitter
    wire       tx_start;
    wire [7:0] tx_data;
    wire       tx_ready;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) uart_tx_inst(
        .clk(clk),
        .rst(rst),
        .start(tx_start),
        .data(tx_data),
        .ready(tx_ready),
        .tx(uart_tx)
    );

    // UART protocol parser: bridges the byte streams above to the scene memories.
    // uart_parser's address outputs default to byte-granular widths (8/16/16 bits
    // for mat/tri/node) that can be wider than top's actual memory address widths,
    // so each is routed through a full-width wire and truncated down explicitly.
    wire [mat_address_bytes*8-1:0]  mat_address_full;
    wire [tri_address_bytes*8-1:0]  tri_address_full;
    wire [node_address_bytes*8-1:0] node_address_full;
    wire [2:0]  write_mat_tri_node;
    wire        load_done_w;

    uart_parser #(
        .mat_bytes(mat_bytes),
        .tri_bytes(tri_bytes),
        .node_bytes(node_bytes),
        .mat_address_bytes(mat_address_bytes),
        .tri_address_bytes(tri_address_bytes),
        .node_address_bytes(node_address_bytes)
    ) uart_parser (
        .clk(clk),
        .rst(rst),
        .rx_valid(rx_valid),
        .rx_data(rx_data),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx_ready(tx_ready),
        .mat_in(mat_in),
        .tri_in(tri_in),
        .node_in(node_in),
        .mat_out(mat_out),
        .tri_out(tri_out),
        .node_out(node_out),
        .mat_address(mat_address_full),
        .tri_address(tri_address_full),
        .node_address(node_address_full),
        .write_mat_tri_node(write_mat_tri_node),
        .load_done(load_done_w)
    );

    assign address_mat = mat_address_full[$clog2(max_mat_count)-1:0];
    assign address_tri = tri_address_full[$clog2(max_tri_count)-1:0];
    assign address_bvh = node_address_full[max_tree_depth-1:0];
    assign writing_mat = write_mat_tri_node[2];
    assign writing_tri = write_mat_tri_node[1];
    assign writing_bvh = write_mat_tri_node[0];
    assign load_done   = load_done_w;

endmodule
