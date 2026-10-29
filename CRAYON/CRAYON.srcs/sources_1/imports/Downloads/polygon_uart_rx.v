`timescale 1ns / 1ps

module polygon_uart_rx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       uart_rx,
    output reg        rx_valid,
    output reg [7:0]  rx_data
);

    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;

    reg [1:0] rx_sync;
    reg [15:0] baud_count;
    reg [2:0] bit_index;
    reg [7:0] rx_shift;
    reg rx_busy;

    localparam IDLE  = 2'd0;
    localparam START = 2'd1;
    localparam DATA  = 2'd2;
    localparam STOP  = 2'd3;

    reg [1:0] state;

    always @(posedge clk) begin
        if (rst)
            rx_sync <= 2'b11;
        else
            rx_sync <= {rx_sync[0], uart_rx};
    end

    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            baud_count <= 0;
            bit_index  <= 0;
            rx_shift   <= 0;
            rx_data    <= 0;
            rx_valid   <= 0;
            rx_busy    <= 0;
        end else begin
            rx_valid <= 1'b0;

            case (state)

                IDLE: begin
                    rx_busy <= 1'b0;

                    if (rx_sync[1] == 1'b0) begin
                        // Wait half a bit to verify start bit.
                        baud_count <= (CLKS_PER_BIT / 2) - 1;
                        state <= START;
                        rx_busy <= 1'b1;
                    end
                end

                START: begin
                    if (baud_count != 0)
                        baud_count <= baud_count - 1'b1;
                    else if (rx_sync[1] == 1'b0) begin
                        // Start confirmed; next sample is bit 0.
                        baud_count <= CLKS_PER_BIT - 1;
                        bit_index <= 0;
                        state <= DATA;
                    end else begin
                        // False start.
                        state <= IDLE;
                    end
                end

                DATA: begin
                    if (baud_count != 0)
                        baud_count <= baud_count - 1'b1;
                    else begin
                        rx_shift[bit_index] <= rx_sync[1];
                        baud_count <= CLKS_PER_BIT - 1;

                        if (bit_index == 7)
                            state <= STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end
                end

                STOP: begin
                    if (baud_count != 0)
                        baud_count <= baud_count - 1'b1;
                    else begin
                        if (rx_sync[1]) begin
                            rx_data <= rx_shift;
                            rx_valid <= 1'b1;
                        end

                        state <= IDLE;
                        rx_busy <= 1'b0;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
