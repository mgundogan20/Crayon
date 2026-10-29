`timescale 1ns / 1ps
// Simple dual-port block RAM: one write port, one registered read port.
// Ray record layout (W = 384):
//   [ 95:  0] origin   [191: 96] direction   [287:192] ray_col   [383:288] accum_col
// The intersect copy only needs W = 192 (origin, direction).
module ray_mem #(
    parameter integer W     = 384,
    parameter integer DEPTH = 4096,
    parameter integer AW    = 12
)(
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [W-1:0]  wdata,
    input  wire [AW-1:0] raddr,
    output reg  [W-1:0]  rdata
);
    (* ram_style = "block" *) reg [W-1:0] mem [0:DEPTH-1];
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
