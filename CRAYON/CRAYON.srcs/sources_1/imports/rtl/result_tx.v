`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// result_tx -- streams the final accum_col of every ray back to the PC:
//   A5 5D | count u16 | count x 3 float32 (accum_col x, y, z), little-endian
//////////////////////////////////////////////////////////////////////////////////
module result_tx #(
    parameter integer RAW = 12
)(
    input  wire           clk,
    input  wire           rst,
    input  wire           start,
    input  wire [15:0]    count,
    output reg            busy,

    output reg  [RAW-1:0] mem_addr,      // ray memory read port (1-cycle latency)
    input  wire [95:0]    mem_accum,

    output reg            tx_start,
    output reg  [7:0]     tx_data,
    input  wire           tx_ready
);
    localparam [2:0] S_IDLE = 3'd0, S_HDR = 3'd1, S_FETCH = 3'd2, S_WAIT = 3'd3, S_BYTES = 3'd4;
    reg [2:0]  state;
    reg [1:0]  hdr_i;
    reg [3:0]  byte_i;
    reg [95:0] acc;
    reg [15:0] n;
    reg        sent;      // a byte was handed over last cycle (ready drops one cycle later)

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0; tx_start <= 1'b0; sent <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            sent     <= tx_start;
            case (state)
                S_IDLE: if (start) begin
                    busy <= 1'b1; hdr_i <= 0; n <= 0; mem_addr <= 0; state <= S_HDR;
                end

                S_HDR: if (tx_ready && !tx_start && !sent) begin
                    tx_start <= 1'b1;
                    case (hdr_i)
                        2'd0: tx_data <= 8'hA5;
                        2'd1: tx_data <= 8'h5D;
                        2'd2: tx_data <= count[7:0];
                        2'd3: tx_data <= count[15:8];
                    endcase
                    hdr_i <= hdr_i + 1'b1;
                    if (hdr_i == 2'd3) state <= (count == 0) ? S_WAIT : S_FETCH;
                end

                S_FETCH: state <= S_WAIT;              // address applied, data next cycle

                S_WAIT: begin
                    if (n == count) begin              // all rays sent: wait for last byte
                        if (tx_ready && !tx_start && !sent) begin
                            busy <= 1'b0; state <= S_IDLE;
                        end
                    end else begin
                        acc <= mem_accum; byte_i <= 0; state <= S_BYTES;
                    end
                end

                S_BYTES: if (tx_ready && !tx_start && !sent) begin
                    tx_start <= 1'b1;
                    tx_data  <= acc[7:0];
                    acc      <= {8'd0, acc[95:8]};
                    byte_i   <= byte_i + 1'b1;
                    if (byte_i == 4'd11) begin
                        n        <= n + 1'b1;
                        mem_addr <= mem_addr + 1'b1;
                        state    <= (n + 1'b1 == count) ? S_WAIT : S_FETCH;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
