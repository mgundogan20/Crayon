`timescale 1ns/1ps

// Frames acknowledgements/results, buffers batch replies, and sends bytes in ray order.
module rt_response_sender #(
    parameter integer MAX_RAYS = 256
) (
    input wire clk,
    input wire reset,
    input wire scene_upload_done,
    input wire batch_start,
    input wire [15:0] batch_ray_count,
    input wire result_valid,
    output wire result_ready,
    input wire result_hit,
    input wire [15:0] result_triangle_index,
    input wire signed [31:0] result_distance_q16,
    output wire tx_valid,
    input wire tx_ready,
    input wire tx_busy,
    output wire [7:0] tx_data
);
    // A trace result is consumed, checksummed, stored, then sent after the batch completes.
    localparam WAITING = 3'd0;
    localparam COLLECT_RESULT = 3'd1;
    localparam BUILD_PACKET = 3'd2;
    localparam STORE_RESULT = 3'd3;
    localparam SEND_ACK = 3'd4;
    localparam SEND_BATCH = 3'd5;
    localparam RESULT_BYTES = 10;

    reg [2:0] state;
    reg [15:0] batch_count;
    reg [15:0] result_index;
    reg [15:0] send_ray_index;
    reg [3:0] byte_index;
    reg [3:0] packet_length;
    reg [3:0] build_index;
    reg [15:0] packet_crc;
    reg [7:0] packet [0:9];
    // Buffering lets the host send the entire batch before it reads any replies.
    reg [7:0] batch_response [0:MAX_RAYS*RESULT_BYTES-1];
    integer response_byte;

    wire [11:0] batch_address =
        send_ray_index[7:0] * 12'd10 + {8'b0, byte_index};
    wire [15:0] crc_next;

    // Accept a result only when the packet builder is ready to copy its fields.
    assign result_ready = state == COLLECT_RESULT;
    assign tx_valid =
        (state == SEND_ACK || state == SEND_BATCH) && !tx_busy;
    assign tx_data = state == SEND_BATCH
        ? batch_response[batch_address]
        : packet[byte_index];

    crc16_ccitt_byte response_crc (
        .crc_in(packet_crc),
        .data(packet[build_index]),
        .crc_out(crc_next)
    );

    always @(posedge clk) begin
        if (reset) begin
            state <= WAITING;
            batch_count <= 0;
            result_index <= 0;
            send_ray_index <= 0;
            byte_index <= 0;
            packet_length <= 0;
            build_index <= 0;
            packet_crc <= 16'hFFFF;
        end else begin
            case (state)
                WAITING: begin
                    if (scene_upload_done) begin
                        packet[0] <= 8'h5A;
                        packet[1] <= 0;
                        packet_length <= 2;
                        build_index <= 0;
                        packet_crc <= 16'hFFFF;
                        state <= BUILD_PACKET;
                    end else if (batch_start) begin
                        batch_count <= batch_ray_count;
                        result_index <= 0;
                        state <= COLLECT_RESULT;
                    end
                end

                COLLECT_RESULT: begin
                    if (result_valid) begin
                        packet[0] <= 8'h5A;
                        packet[1] <= {7'b0, result_hit};
                        packet[2] <= result_triangle_index[7:0];
                        packet[3] <= result_triangle_index[15:8];
                        packet[4] <= result_distance_q16[7:0];
                        packet[5] <= result_distance_q16[15:8];
                        packet[6] <= result_distance_q16[23:16];
                        packet[7] <= result_distance_q16[31:24];
                        packet_length <= 8;
                        build_index <= 0;
                        packet_crc <= 16'hFFFF;
                        state <= BUILD_PACKET;
                    end
                end

                // CRC is accumulated over packet bytes 0..7 (or 0..1 for an ACK).
                BUILD_PACKET: begin
                    packet_crc <= crc_next;
                    if (build_index + 1 >= packet_length) begin
                        packet[packet_length] <= crc_next[7:0];
                        packet[packet_length + 1'b1] <= crc_next[15:8];
                        byte_index <= 0;
                        packet_length <= packet_length + 2;
                        if (batch_count != 0)
                            state <= STORE_RESULT;
                        else
                            state <= SEND_ACK;
                    end else begin
                        build_index <= build_index + 1'b1;
                    end
                end

                // Store all 10 bytes, including CRC, at ray_index * 10.
                STORE_RESULT: begin
                    for (response_byte = 0; response_byte < RESULT_BYTES; response_byte = response_byte + 1)
                        batch_response[result_index * RESULT_BYTES + response_byte] <= packet[response_byte];

                    if (result_index + 1 >= batch_count) begin
                        send_ray_index <= 0;
                        byte_index <= 0;
                        state <= SEND_BATCH;
                    end else begin
                        result_index <= result_index + 1'b1;
                        state <= COLLECT_RESULT;
                    end
                end

                SEND_ACK: begin
                    if (tx_valid && tx_ready) begin
                        if (byte_index + 1 >= packet_length) begin
                            batch_count <= 0;
                            state <= WAITING;
                        end else begin
                            byte_index <= byte_index + 1'b1;
                        end
                    end
                end

                // UART backpressure pauses the byte index until tx_ready is asserted.
                SEND_BATCH: begin
                    if (tx_valid && tx_ready) begin
                        if (byte_index == RESULT_BYTES - 1) begin
                            byte_index <= 0;
                            if (send_ray_index + 1 >= batch_count) begin
                                batch_count <= 0;
                                state <= WAITING;
                            end else begin
                                send_ray_index <= send_ray_index + 1'b1;
                            end
                        end else begin
                            byte_index <= byte_index + 1'b1;
                        end
                    end
                end

                default: state <= WAITING;
            endcase
        end
    end
endmodule
