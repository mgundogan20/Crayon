`timescale 1ns / 1ps
// 8N1 UART transmitter. 'ready' is high while idle; a byte is accepted when
// start && ready.
module uart_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data,
    output wire       ready,
    output reg        tx
);
    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;
    reg [15:0] cnt;
    reg [3:0]  bit_n;          // 0 = start, 1..8 data, 9 stop
    reg [8:0]  sh;
    reg        busy;
    assign ready = ~busy;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; tx <= 1'b1; cnt <= 0; bit_n <= 0; sh <= 9'h1FF;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                busy  <= 1'b1;
                tx    <= 1'b0;                 // start bit
                sh    <= {1'b1, data};         // data LSB first, then stop
                cnt   <= CLKS_PER_BIT - 1;
                bit_n <= 0;
            end
        end else if (cnt != 0) begin
            cnt <= cnt - 1'b1;
        end else if (bit_n == 4'd9) begin
            busy <= 1'b0;                      // stop bit done
        end else begin
            tx    <= sh[0];
            sh    <= {1'b1, sh[8:1]};
            bit_n <= bit_n + 1'b1;
            cnt   <= CLKS_PER_BIT - 1;
        end
    end
endmodule
