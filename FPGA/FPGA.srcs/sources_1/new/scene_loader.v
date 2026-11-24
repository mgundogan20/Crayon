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


endmodule
