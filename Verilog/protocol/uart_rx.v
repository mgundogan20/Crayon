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

// MIT-licensed UART receiver with an 8-bit ready/valid output stream.
module uart_rx #(
    parameter DATA_WIDTH = 8
) (
    input wire clk,
    input wire rst,
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    input wire rxd,
    output wire busy,
    output wire overrun_error,
    output wire frame_error,
    input wire [15:0] prescale
);
    reg [DATA_WIDTH-1:0] data_out;
    reg data_valid;
    reg rx_sync;
    reg busy_reg;
    reg overrun_reg;
    reg frame_reg;
    reg [DATA_WIDTH-1:0] shift_data;
    reg [18:0] prescale_count;
    reg [3:0] bit_count;

    wire [18:0] prescale_x4 = {3'b0, prescale} << 2;
    wire [18:0] prescale_x8 = {3'b0, prescale} << 3;

    assign m_axis_tdata = data_out;
    assign m_axis_tvalid = data_valid;
    assign busy = busy_reg;
    assign overrun_error = overrun_reg;
    assign frame_error = frame_reg;

    always @(posedge clk) begin
        if (rst) begin
            data_out <= 0;
            data_valid <= 0;
            rx_sync <= 1;
            prescale_count <= 0;
            bit_count <= 0;
            busy_reg <= 0;
            overrun_reg <= 0;
            frame_reg <= 0;
        end else begin
            rx_sync <= rxd;
            overrun_reg <= 0;
            frame_reg <= 0;

            if (data_valid && m_axis_tready)
                data_valid <= 0;

            if (prescale_count > 0) begin
                prescale_count <= prescale_count - 1'b1;
            end else if (bit_count > 0) begin
                if (bit_count > DATA_WIDTH + 1) begin
                    if (!rx_sync) begin
                        bit_count <= bit_count - 1'b1;
                        prescale_count <= prescale_x8 - 1'b1;
                    end else begin
                        bit_count <= 0;
                        prescale_count <= 0;
                    end
                end else if (bit_count > 1) begin
                    bit_count <= bit_count - 1'b1;
                    prescale_count <= prescale_x8 - 1'b1;
                    shift_data <= {rx_sync, shift_data[DATA_WIDTH-1:1]};
                end else begin
                    bit_count <= 0;
                    if (rx_sync) begin
                        data_out <= shift_data;
                        data_valid <= 1;
                        overrun_reg <= data_valid;
                    end else begin
                        frame_reg <= 1;
                    end
                end
            end else begin
                busy_reg <= 0;
                if (!rx_sync) begin
                    prescale_count <= prescale_x4 - 19'd2;
                    bit_count <= DATA_WIDTH + 2;
                    shift_data <= 0;
                    busy_reg <= 1;
                end
            end
        end
    end
endmodule
