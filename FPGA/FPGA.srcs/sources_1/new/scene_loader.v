`timescale 1ns / 1ps

module scene_loader #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       uart_rx,
    output reg        rx_valid,
    output reg [7:0]  rx_data
);

    localparam IDLE  = 3'd0;
    localparam START = 3'd1;
    localparam COUNT  = 3'd2;
    localparam BVH  = 3'd3;
    localparam TRI  = 3'd4;
    localparam MAT  = 3'd5;
    localparam FETCH_BVH  = 3'd6; //temp state for debugging
    localparam FETCH_TRI  = 3'd7; //temp state for debugging

endmodule
