`timescale 1ns/1ps

module tb_rt_uart_endpoint;
    localparam integer CLKS_PER_BIT = 8;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg uart_rx_pin = 1'b1;
    wire uart_tx_pin;

    reg [7:0] scene_data [0:59];
    reg [7:0] ray_data [0:23];
    reg [7:0] response [0:9];
    reg [15:0] crc;
    reg [7:0] received_byte;
    integer i;

    always #5 clk = ~clk;

    rt_uart_endpoint #(
        .CLKS_PER_BIT(CLKS_PER_BIT),
        .MAX_TRIANGLES(256),
        .MAX_RAYS(256)
    ) dut (
        .clk(clk),
        .reset(reset),
        .uart_rx_pin(uart_rx_pin),
        .uart_tx_pin(uart_tx_pin)
    );

    task send_uart_byte;
        input [7:0] data;
        integer bit_index;
        begin
            @(negedge clk);
            uart_rx_pin = 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                @(negedge clk);
                uart_rx_pin = data[bit_index];
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            @(negedge clk);
            uart_rx_pin = 1'b1;
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    task receive_uart_byte;
        output [7:0] data;
        integer bit_index;
        begin
            @(negedge uart_tx_pin);
            repeat (CLKS_PER_BIT / 2) @(posedge clk);
            if (uart_tx_pin !== 1'b0) begin
                $display("FAIL: invalid UART start bit");
                $fatal(1);
            end

            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                repeat (CLKS_PER_BIT) @(posedge clk);
                data[bit_index] = uart_tx_pin;
            end

            repeat (CLKS_PER_BIT) @(posedge clk);
            if (uart_tx_pin !== 1'b1) begin
                $display("FAIL: invalid UART stop bit");
                $fatal(1);
            end
        end
    endtask

    task send_header;
        input [7:0] command;
        input [15:0] item_count;
        reg [15:0] header_crc;
        begin
            header_crc = 16'hFFFF;
            header_crc = crc16_update(header_crc, 8'hA5);
            header_crc = crc16_update(header_crc, command);
            header_crc = crc16_update(header_crc, item_count[7:0]);
            header_crc = crc16_update(header_crc, item_count[15:8]);
            send_uart_byte(8'hA5);
            send_uart_byte(command);
            send_uart_byte(item_count[7:0]);
            send_uart_byte(item_count[15:8]);
            send_uart_byte(header_crc[7:0]);
            send_uart_byte(header_crc[15:8]);
        end
    endtask

    function [15:0] crc16_update;
        input [15:0] crc_in;
        input [7:0] data_byte;
        integer bit_index;
        reg [15:0] value;
        begin
            value = crc_in ^ {data_byte, 8'h00};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (value[15])
                    value = (value << 1) ^ 16'h1021;
                else
                    value = value << 1;
            end
            crc16_update = value;
        end
    endfunction

    initial begin
        #1000000;
        $display("FAIL: timed out waiting for UART endpoint response");
        $fatal(1);
    end

    initial begin
        repeat (5) @(negedge clk);
        reset = 1'b0;

        for (i = 0; i < 60; i = i + 1)
            scene_data[i] = 0;
        scene_data[22] = 8'h01;
        scene_data[30] = 8'h01;

        send_header(8'h10, 16'd1);
        crc = 16'hFFFF;
        for (i = 0; i < 60; i = i + 1) begin
            send_uart_byte(scene_data[i]);
            crc = crc16_update(crc, scene_data[i]);
        end
        send_uart_byte(crc[7:0]);
        send_uart_byte(crc[15:8]);

        receive_uart_byte(received_byte);
        if (received_byte !== 8'h5A)
            $fatal(1, "Invalid scene-upload response sync: %02x", received_byte);
        receive_uart_byte(received_byte);
        if (received_byte !== 8'h00)
            $fatal(1, "Scene upload returned error status: %02x", received_byte);
        receive_uart_byte(received_byte);
        receive_uart_byte(received_byte);

        for (i = 0; i < 24; i = i + 1)
            ray_data[i] = 0;
        ray_data[2] = 8'h01;
        ray_data[5] = 8'h40;
        ray_data[9] = 8'h40;
        ray_data[12] = 8'h00;
        ray_data[13] = 8'h00;
        ray_data[14] = 8'hFF;
        ray_data[15] = 8'hFF;

        send_header(8'h20, 16'd1);
        crc = 16'hFFFF;
        for (i = 0; i < 24; i = i + 1) begin
            send_uart_byte(ray_data[i]);
            crc = crc16_update(crc, ray_data[i]);
        end
        send_uart_byte(crc[7:0]);
        send_uart_byte(crc[15:8]);

        for (i = 0; i < 10; i = i + 1)
            receive_uart_byte(response[i]);

        if (response[0] !== 8'h5A ||
            response[1] !== 8'h01 ||
            response[2] !== 8'h00 ||
            response[3] !== 8'h00 ||
            response[4] !== 8'h00 ||
            response[5] !== 8'h00 ||
            response[6] !== 8'h01 ||
            response[7] !== 8'h00) begin
            $display(
                "FAIL: unexpected ray response %02x %02x %02x %02x %02x %02x %02x %02x",
                response[0], response[1], response[2], response[3],
                response[4], response[5], response[6], response[7]
            );
            $fatal(1);
        end

        crc = 16'hFFFF;
        for (i = 0; i < 8; i = i + 1)
            crc = crc16_update(crc, response[i]);
        if (response[8] !== crc[7:0] || response[9] !== crc[15:8]) begin
            $display("FAIL: invalid response CRC");
            $fatal(1);
        end

        $display("PASS: UART scene upload and nearest-hit ray batch");
        $finish;
    end
endmodule
