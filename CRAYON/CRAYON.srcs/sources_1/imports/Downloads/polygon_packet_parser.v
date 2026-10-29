`timescale 1ns / 1ps
module polygon_packet_parser #(
    parameter integer MAX_TRIANGLES = 128
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    output reg         packet_done,
    output reg         packet_error,
    output reg [15:0]  triangle_count,
    input [11:0] index,
    output [7:0] triang
);

       localparam [2:0] S_SYNC_A5 = 3'd0,
        S_SYNC_5A = 3'd1,
        S_COUNT0  = 3'd2,
        S_COUNT1  = 3'd3,
        S_DATA    = 3'd4;

    reg [2:0] state;

    reg [7:0] count_lo;
    reg [1:0] byte_in_word;
    reg [31:0] word_shift;

    // 15 float32 words per polygon.
    // 64 polygons require 960 words.
    reg [9:0] word_index;
    reg [10:0] total_words;

    // Raw IEEE 754 bits. Convert to floating point in
    // a downstream FPGA floating-point processing module.
     (* ram_style = "block" *)
    (* KEEP = "TRUE" *) reg [31:0] polygon_mem [0:MAX_TRIANGLES*15-1];
assign triang = polygon_mem[index][index[1:0]*8+:8];
    always @(posedge clk) begin
        if (rst) begin
            state          <= S_SYNC_A5;
            count_lo       <= 8'd0;
            triangle_count <= 16'd0;
            byte_in_word   <= 2'd0;
            word_shift     <= 32'd0;
            word_index     <= 10'd0;
            total_words    <= 11'd0;
            packet_done    <= 1'b0;
            packet_error   <= 1'b0;
        end else begin
            packet_done  <= 1'b0;
            packet_error <= 1'b0;

            if (rx_valid) begin
                case (state)

                    S_SYNC_A5: begin
                        if (rx_data == 8'hA5)
                            state <= S_SYNC_5A;
                    end

                    S_SYNC_5A: begin
                        if (rx_data == 8'h5A)
                            state <= S_COUNT0;
                        else if (rx_data == 8'hA5)
                            state <= S_SYNC_5A;
                        else
                            state <= S_SYNC_A5;
                    end

                    S_COUNT0: begin
                        count_lo <= rx_data;
                        state <= S_COUNT1;
                    end

                    S_COUNT1: begin
                        triangle_count <= {rx_data, count_lo};

                        if ({rx_data, count_lo} > MAX_TRIANGLES) begin
                            packet_error <= 1'b1;
                            state <= S_SYNC_A5;
                        end else if ({rx_data, count_lo} == 0) begin
                            packet_done <= 1'b1;
                            state <= S_SYNC_A5;
                        end else begin
                            total_words <= {rx_data, count_lo} * 15;
                            word_index <= 0;
                            byte_in_word <= 0;
                            word_shift <= 0;
                            state <= S_DATA;
                        end
                    end

                    S_DATA: begin
                        // Little-endian byte order
                        case (byte_in_word)
                            2'd0: word_shift[7:0]   <= rx_data;
                            2'd1: word_shift[15:8]  <= rx_data;
                            2'd2: word_shift[23:16] <= rx_data;

                            2'd3: begin
                                polygon_mem[word_index] <=
                                    {rx_data, word_shift[23:0]};
                            end
                        endcase

                        if (byte_in_word == 3) begin
                            byte_in_word <= 0;

                            if (word_index == total_words - 1'b1) begin
                                packet_done <= 1'b1;
                                state <= S_SYNC_A5;
                            end else begin
                                word_index <= word_index + 1'b1;
                            end
                        end else begin
                            byte_in_word <= byte_in_word + 1'b1;
                        end
                    end

                    default: state <= S_SYNC_A5;

                endcase
            end
        end
    end

endmodule
