/*
Copyright (c) 2014-2017 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.
*/

`timescale 1ns/1ps

// MIT-licensed UART transmitter with an 8-bit ready/valid input stream.
module uart_tx #(
    parameter DATA_WIDTH = 8
) (
    input wire clk,
    input wire rst,
    input wire [DATA_WIDTH-1:0] s_axis_tdata,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    output wire txd,
    output wire busy,
    input wire [15:0] prescale
);
    reg source_ready;
    reg tx_serial;
    reg busy_reg;
    reg [DATA_WIDTH:0] shift_data;
    reg [18:0] prescale_count;
    reg [3:0] bit_count;

    assign s_axis_tready = source_ready;
    assign txd = tx_serial;
    assign busy = busy_reg;

    always @(posedge clk) begin
        if (rst) begin
            source_ready <= 0;
            tx_serial <= 1;
            prescale_count <= 0;
            bit_count <= 0;
            busy_reg <= 0;
        end else if (prescale_count > 0) begin
            source_ready <= 0;
            prescale_count <= prescale_count - 1'b1;
        end else if (bit_count == 0) begin
            source_ready <= 1;
            busy_reg <= 0;

            if (s_axis_tvalid && source_ready) begin
                source_ready <= 0;
                prescale_count <= (prescale << 3) - 1'b1;
                bit_count <= DATA_WIDTH + 1;
                shift_data <= {1'b1, s_axis_tdata};
                tx_serial <= 0;
                busy_reg <= 1;
            end
        end else if (bit_count > 1) begin
            bit_count <= bit_count - 1'b1;
            prescale_count <= (prescale << 3) - 1'b1;
            {shift_data, tx_serial} <= {1'b0, shift_data};
        end else begin
            bit_count <= 0;
            prescale_count <= prescale << 3;
            tx_serial <= 1;
        end
    end
endmodule
