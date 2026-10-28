`timescale 1ns/1ps

// Turns the UART byte stream into CRC-verified scene writes and ray batches.
module rt_request_decoder #(
    parameter integer MAX_TRIANGLES = 256,
    parameter integer MAX_RAYS = 256
) (
    input wire clk,
    input wire reset,
    input wire byte_valid,
    input wire [7:0] byte_data,
    output reg scene_clear,
    output reg scene_write_valid,
    output reg [287:0] scene_write_data,
    output reg ray_write_valid,
    output reg [7:0] ray_write_index,
    output reg [191:0] ray_write_data,
    output reg scene_upload_done,
    output reg batch_start,
    output reg [15:0] batch_ray_count
);
    // Receive protocol: 6-byte header, then fixed-size records with their own CRC.
    localparam WAIT_SYNC = 4'd0;
    localparam READ_COMMAND = 4'd1;
    localparam READ_COUNT_LOW = 4'd2;
    localparam READ_COUNT_HIGH = 4'd3;
    localparam READ_HEADER_CRC_LOW = 4'd4;
    localparam READ_HEADER_CRC_HIGH = 4'd5;
    localparam READ_SCENE_DATA = 4'd6;
    localparam READ_SCENE_CRC_LOW = 4'd7;
    localparam READ_SCENE_CRC_HIGH = 4'd8;
    localparam READ_RAY_DATA = 4'd9;
    localparam READ_RAY_CRC_LOW = 4'd10;
    localparam READ_RAY_CRC_HIGH = 4'd11;

    localparam [7:0] SYNC = 8'hA5;
    localparam [7:0] UPLOAD_SCENE = 8'h10;
    localparam [7:0] TRACE_BATCH = 8'h20;
    localparam [15:0] MAX_TRIANGLE_COUNT = 16'(MAX_TRIANGLES);
    localparam [15:0] MAX_RAY_COUNT = 16'(MAX_RAYS);

    reg [3:0] state;
    reg [7:0] command;
    reg [7:0] count_low;
    reg [15:0] remaining;
    reg [15:0] ray_count;
    reg [7:0] record_byte_index;
    reg [7:0] crc_low;
    reg [15:0] crc;
    // Record buffers are little-endian; each vector's x component is the low word.
    reg [287:0] scene_record;
    reg [191:0] ray_record;

    wire [15:0] crc_next;
    wire [15:0] initial_crc;
    wire [15:0] received_crc = {byte_data, crc_low};
    wire valid_crc = received_crc == crc;

    crc16_ccitt_byte crc_for_input (
        .crc_in(crc),
        .data(byte_data),
        .crc_out(crc_next)
    );

    crc16_ccitt_byte crc_for_sync (
        .crc_in(16'hFFFF),
        .data(SYNC),
        .crc_out(initial_crc)
    );

    // Output strobes are one-cycle pulses, emitted only after the record CRC passes.
    always @(posedge clk) begin
        if (reset) begin
            state <= WAIT_SYNC;
            command <= 0;
            count_low <= 0;
            remaining <= 0;
            ray_count <= 0;
            record_byte_index <= 0;
            crc_low <= 0;
            crc <= 16'hFFFF;
            scene_clear <= 1'b0;
            scene_write_valid <= 1'b0;
            scene_write_data <= 0;
            ray_write_valid <= 1'b0;
            ray_write_index <= 0;
            ray_write_data <= 0;
            scene_upload_done <= 1'b0;
            batch_start <= 1'b0;
            batch_ray_count <= 0;
        end else begin
            scene_clear <= 1'b0;
            scene_write_valid <= 1'b0;
            ray_write_valid <= 1'b0;
            scene_upload_done <= 1'b0;
            batch_start <= 1'b0;

            if (byte_valid) begin
                case (state)
                    WAIT_SYNC: begin
                        if (byte_data == SYNC) begin
                            crc <= initial_crc;
                            state <= READ_COMMAND;
                        end
                    end

                    READ_COMMAND: begin
                        command <= byte_data;
                        crc <= crc_next;
                        state <= READ_COUNT_LOW;
                    end

                    READ_COUNT_LOW: begin
                        count_low <= byte_data;
                        crc <= crc_next;
                        state <= READ_COUNT_HIGH;
                    end

                    READ_COUNT_HIGH: begin
                        remaining <= {byte_data, count_low};
                        crc <= crc_next;
                        state <= READ_HEADER_CRC_LOW;
                    end

                    READ_HEADER_CRC_LOW: begin
                        crc_low <= byte_data;
                        state <= READ_HEADER_CRC_HIGH;
                    end

                    // Counts are range-checked before data is accepted or stored.
                    READ_HEADER_CRC_HIGH: begin
                        if (valid_crc && command == UPLOAD_SCENE &&
                            remaining <= MAX_TRIANGLE_COUNT) begin
                            scene_clear <= 1'b1;
                            if (remaining == 0) begin
                                scene_upload_done <= 1'b1;
                                state <= WAIT_SYNC;
                            end else begin
                                crc <= 16'hFFFF;
                                record_byte_index <= 0;
                                state <= READ_SCENE_DATA;
                            end
                        end else if (valid_crc && command == TRACE_BATCH &&
                            remaining <= MAX_RAY_COUNT &&
                            remaining != 0) begin
                            ray_count <= remaining;
                            ray_write_index <= 0;
                            crc <= 16'hFFFF;
                            record_byte_index <= 0;
                            state <= READ_RAY_DATA;
                        end else begin
                            state <= WAIT_SYNC;
                        end
                    end

                    READ_SCENE_DATA: begin
                        if (record_byte_index < 36)
                            scene_record[record_byte_index * 8 +: 8] <= byte_data;
                        crc <= crc_next;
                        if (record_byte_index == 59)
                            state <= READ_SCENE_CRC_LOW;
                        else
                            record_byte_index <= record_byte_index + 1'b1;
                    end

                    READ_SCENE_CRC_LOW: begin
                        crc_low <= byte_data;
                        state <= READ_SCENE_CRC_HIGH;
                    end

                    READ_SCENE_CRC_HIGH: begin
                        if (valid_crc) begin
                            scene_write_data <= scene_record;
                            scene_write_valid <= 1'b1;
                            remaining <= remaining - 1'b1;
                            if (remaining == 1) begin
                                scene_upload_done <= 1'b1;
                                state <= WAIT_SYNC;
                            end else begin
                                crc <= 16'hFFFF;
                                record_byte_index <= 0;
                                state <= READ_SCENE_DATA;
                            end
                        end else begin
                            scene_clear <= 1'b1;
                            state <= WAIT_SYNC;
                        end
                    end

                    READ_RAY_DATA: begin
                        ray_record[record_byte_index * 8 +: 8] <= byte_data;
                        crc <= crc_next;
                        if (record_byte_index == 23)
                            state <= READ_RAY_CRC_LOW;
                        else
                            record_byte_index <= record_byte_index + 1'b1;
                    end

                    READ_RAY_CRC_LOW: begin
                        crc_low <= byte_data;
                        state <= READ_RAY_CRC_HIGH;
                    end

                    READ_RAY_CRC_HIGH: begin
                        if (valid_crc) begin
                            ray_write_data <= ray_record;
                            ray_write_valid <= 1'b1;
                            remaining <= remaining - 1'b1;
                            if (remaining == 1) begin
                                batch_ray_count <= ray_count;
                                batch_start <= 1'b1;
                                state <= WAIT_SYNC;
                            end else begin
                                ray_write_index <= ray_write_index + 1'b1;
                                crc <= 16'hFFFF;
                                record_byte_index <= 0;
                                state <= READ_RAY_DATA;
                            end
                        end else begin
                            state <= WAIT_SYNC;
                        end
                    end

                    default: state <= WAIT_SYNC;
                endcase
            end
        end
    end

endmodule
