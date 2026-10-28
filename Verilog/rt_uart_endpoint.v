`timescale 1ns/1ps

// FPGA-facing wrapper: UART bytes -> decoded requests -> traced results -> UART bytes.
module rt_uart_endpoint #(
    parameter integer CLKS_PER_BIT = 434,
    parameter integer MAX_TRIANGLES = 256,
    parameter integer MAX_RAYS = 256
) (
    input wire clk,
    input wire reset,
    input wire uart_rx_pin,
    output wire uart_tx_pin
);
    // verilog-uart expects clocks per bit divided by eight.
    localparam integer UART_PRESCALE = (CLKS_PER_BIT + 4) / 8;

    // Byte-stream signals between the UART and protocol modules.
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_overrun_error;
    wire rx_frame_error;
    wire tx_ready;
    wire tx_busy;
    wire [7:0] tx_data;
    wire tx_valid;

    // Decoded request signals shared by the decoder, trace engine, and sender.
    wire scene_clear;
    wire scene_write_valid;
    wire [287:0] scene_write_data;
    wire ray_write_valid;
    wire [7:0] ray_write_index;
    wire [191:0] ray_write_data;
    wire scene_upload_done;
    wire batch_start;
    wire [15:0] batch_ray_count;

    // One result at a time flows from the trace engine to the response sender.
    wire result_valid;
    wire result_ready;
    wire result_hit;
    wire [15:0] result_triangle_index;
    wire signed [31:0] result_distance_q16;

    // UART IP exposes an AXI-stream-like byte interface; this endpoint is always ready.
    uart_rx #(
        .DATA_WIDTH(8)
    ) receiver (
        .clk(clk),
        .rst(reset),
        .m_axis_tdata(rx_data),
        .m_axis_tvalid(rx_valid),
        .m_axis_tready(1'b1),
        .rxd(uart_rx_pin),
        .busy(),
        // A framing or overrun error discards the partial request.
        .overrun_error(rx_overrun_error),
        .frame_error(rx_frame_error),
        .prescale(16'(UART_PRESCALE))
    );

    uart_tx #(
        .DATA_WIDTH(8)
    ) transmitter (
        .clk(clk),
        .rst(reset),
        .s_axis_tdata(tx_data),
        .s_axis_tvalid(tx_valid),
        .s_axis_tready(tx_ready),
        .txd(uart_tx_pin),
        .busy(tx_busy),
        .prescale(16'(UART_PRESCALE))
    );

    // Parse and CRC-check the incoming command before exposing records to the engine.
    rt_request_decoder #(
        .MAX_TRIANGLES(MAX_TRIANGLES),
        .MAX_RAYS(MAX_RAYS)
    ) request_decoder (
        .clk(clk),
        .reset(reset | rx_overrun_error | rx_frame_error),
        .byte_valid(rx_valid),
        .byte_data(rx_data),
        .scene_clear(scene_clear),
        .scene_write_valid(scene_write_valid),
        .scene_write_data(scene_write_data),
        .ray_write_valid(ray_write_valid),
        .ray_write_index(ray_write_index),
        .ray_write_data(ray_write_data),
        .scene_upload_done(scene_upload_done),
        .batch_start(batch_start),
        .batch_ray_count(batch_ray_count)
    );

    // Geometry is isolated from UART framing and packet checksums.
    scene_trace_engine #(
        .MAX_TRIANGLES(MAX_TRIANGLES),
        .MAX_RAYS(MAX_RAYS)
    ) scene_engine (
        .clk(clk),
        .reset(reset),
        .scene_clear(scene_clear),
        .scene_write_valid(scene_write_valid),
        .scene_write_data(scene_write_data),
        .ray_write_valid(ray_write_valid),
        .ray_write_index(ray_write_index),
        .ray_write_data(ray_write_data),
        .batch_start(batch_start),
        .batch_ray_count(batch_ray_count),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_hit(result_hit),
        .result_triangle_index(result_triangle_index),
        .result_distance_q16(result_distance_q16)
    );

    // Build checksummed replies, buffer batch results, and serialize in ray order.
    rt_response_sender #(
        .MAX_RAYS(MAX_RAYS)
    ) response_sender (
        .clk(clk),
        .reset(reset),
        .scene_upload_done(scene_upload_done),
        .batch_start(batch_start),
        .batch_ray_count(batch_ray_count),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_hit(result_hit),
        .result_triangle_index(result_triangle_index),
        .result_distance_q16(result_distance_q16),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_busy(tx_busy),
        .tx_data(tx_data)
    );
endmodule
