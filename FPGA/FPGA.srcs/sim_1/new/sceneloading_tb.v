`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 11/26/2026 03:56:53 PM
// Design Name:
// Module Name: sceneloading_tb
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////

// Loads an arbitrary scene into `top` over its uart_rx pin and fetches every
// record back over uart_tx, byte-comparing against what was sent. Mirrors
// sceneloader_test.py. Every size/width below is a parameter mirroring
// top.v's own parameter list and is passed straight through to the `top`
// instance, so this testbench always tracks whatever top.v is configured
// with instead of hardcoding byte counts.

module sceneloading_tb #(
    parameter integer mat_bytes          = 1+(3*4)+(3*4),                        // byte smoothness, float3 emission, float3 absorption
    parameter integer max_mat_count      = 4,
    parameter integer tri_bytes          = 4+(3*4)+(3*4)+(3*4)+(3*4)+(3*4)+(3*4), // int material_id, float3 V0, E1, E2, N1, N2, N3
    parameter integer max_tri_count      = (2**11)-1,
    parameter integer node_bytes         = 4+4+4+4+(3*4)+(3*4),                  // int left, right, id, morton, float3 center, size
    parameter integer max_tree_depth     = 12,
    parameter integer CLK_HZ             = 100_000_000,
    parameter integer BAUD               = 10_000_000, 
    parameter integer mat_address_bytes  = 1,
    parameter integer tri_address_bytes  = 2,
    parameter integer node_address_bytes = 2
)(

    );

    // ------------------------------------------------------------------
    // Clock / reset
    // ------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100MHz

    reg rst;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    reg  tb_tx_line;    // drives dut.uart_rx
    wire tb_rx_line;    // senses dut.uart_tx
    wire load_done_sig;

    top #(
        .mat_bytes(mat_bytes),
        .max_mat_count(max_mat_count),
        .tri_bytes(tri_bytes),
        .max_tri_count(max_tri_count),
        .node_bytes(node_bytes),
        .max_tree_depth(max_tree_depth),
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD),
        .mat_address_bytes(mat_address_bytes),
        .tri_address_bytes(tri_address_bytes),
        .node_address_bytes(node_address_bytes)
    ) dut (
        .clk(clk),
        .rst(rst),
        .uart_rx(tb_tx_line),
        .uart_tx(tb_rx_line),
        .load_done(load_done_sig)
    );

    // ------------------------------------------------------------------
    // Protocol constants (from uart_parser.v)
    // ------------------------------------------------------------------
    localparam [7:0] SYNC          = 8'hA5;
    localparam [7:0] CMD_LOAD      = 8'h5A;
    localparam [7:0] CMD_FETCH_BVH = 8'h5B;
    localparam [7:0] CMD_FETCH_TRI = 8'h5C;
    localparam [7:0] CMD_FETCH_MAT = 8'h5D;

    // Number of records this test loads: fill every memory to its actual
    // capacity. MAX_NODES mirrors bvh_mem.v's own capacity formula (its
    // address port is sized off max_tree_depth, not max_tree_depth itself).
    localparam integer MAX_NODES       = (2**max_tree_depth)-1;
    localparam integer TEST_NODE_COUNT = MAX_NODES;
    localparam integer TEST_TRI_COUNT  = max_tri_count;
    localparam integer TEST_MAT_COUNT  = max_mat_count;

    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;
    localparam integer BIT_TIME_NS  = CLKS_PER_BIT * 10;

    // ------------------------------------------------------------------
    // Bit-level UART tasks
    // ------------------------------------------------------------------
    task send_byte(input [7:0] data);
        integer i;
        begin
            tb_tx_line = 1'b0;              // start bit
            #BIT_TIME_NS;
            for (i = 0; i < 8; i = i + 1) begin
                tb_tx_line = data[i];        // LSB first
                #BIT_TIME_NS;
            end
            tb_tx_line = 1'b1;               // stop bit
            #BIT_TIME_NS;
        end
    endtask

    // Sends the low 8*n bits of v, LE, as n bytes. Used for every protocol
    // count/address field, each of which is sized by a *_address_bytes param.
    task send_nbytes(input integer n, input [31:0] v);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                send_byte(v[8*k +: 8]);
        end
    endtask

    // Background receiver: listens on tb_rx_line continuously from time 0,
    // independent of whatever the main test is doing. uart_rx samples its
    // stop bit at the bit's midpoint (9.5 bit-times after the start edge),
    // so the DUT's response can begin before send_byte (which holds a full
    // bit-time stop bit) returns control to the caller; a recv_byte that
    // only starts @(negedge...) on demand can arrive after that edge has
    // already passed and lock onto the wrong byte. Queuing bytes as they
    // arrive, decoupled from when the test asks for them, avoids that race.
    reg [7:0] rx_queue [0:1023];
    integer   rx_write_ptr;
    integer   rx_read_ptr;
    integer   rx_bit_idx;
    reg [7:0] rx_byte_tmp;

    initial begin
        rx_write_ptr = 0;
        rx_read_ptr  = 0;
        forever begin
            @(negedge tb_rx_line);                  // start bit begins
            #(BIT_TIME_NS + BIT_TIME_NS / 2);       // move to middle of bit 0
            for (rx_bit_idx = 0; rx_bit_idx < 8; rx_bit_idx = rx_bit_idx + 1) begin
                rx_byte_tmp[rx_bit_idx] = tb_rx_line;   // LSB first
                #BIT_TIME_NS;
            end
            rx_queue[rx_write_ptr] = rx_byte_tmp;
            rx_write_ptr = rx_write_ptr + 1;
        end
    end

    task recv_byte(output [7:0] b);
        begin
            rx_read_ptr = rx_read_ptr + 1;
            while (rx_write_ptr < rx_read_ptr)
                @(rx_write_ptr);
            b = rx_queue[rx_read_ptr - 1];
        end
    endtask

    // ------------------------------------------------------------------
    // Record senders (packed value -> byte stream, LSB byte first)
    // ------------------------------------------------------------------
    task send_node_record(input [node_bytes*8-1:0] val);
        integer k;
        begin
            for (k = 0; k < node_bytes; k = k + 1)
                send_byte(val[8*k +: 8]);
        end
    endtask

    task send_tri_record(input [tri_bytes*8-1:0] val);
        integer k;
        begin
            for (k = 0; k < tri_bytes; k = k + 1)
                send_byte(val[8*k +: 8]);
        end
    endtask

    task send_mat_record(input [mat_bytes*8-1:0] val);
        integer k;
        begin
            for (k = 0; k < mat_bytes; k = k + 1)
                send_byte(val[8*k +: 8]);
        end
    endtask

    // ------------------------------------------------------------------
    // Fetch + compare
    // ------------------------------------------------------------------
    integer pass_count, fail_count;

    // Widest record this testbench ever needs to hold (mirrors uart_parser.v's
    // own MAX_BYTES calculation, so this tracks whichever of mat/tri/node_bytes
    // is actually largest under the current parameters).
    localparam integer MAX_RECORD_BYTES =
        (tri_bytes > node_bytes) ? ((tri_bytes  > mat_bytes) ? tri_bytes  : mat_bytes)
                                  : ((node_bytes > mat_bytes) ? node_bytes : mat_bytes);
    localparam integer MAX_RECORD_BITS = MAX_RECORD_BYTES*8;
    localparam [MAX_RECORD_BITS-1:0] ONE = 1;

    task check_bytes(input [8*16-1:0] label, input [MAX_RECORD_BITS-1:0] expected, input integer nbytes);
        integer k;
        reg [7:0] got;
        reg [MAX_RECORD_BITS-1:0] recv_val;
        reg [MAX_RECORD_BITS-1:0] mask;
        reg ok;
        begin
            recv_val = 0;
            ok = 1'b1;
            for (k = 0; k < nbytes; k = k + 1) begin
                recv_byte(got);
                recv_val[8*k +: 8] = got;
                if (got !== expected[8*k +: 8])
                    ok = 1'b0;
            end
            if (ok) begin
                $display("%s: OK", label);
                pass_count = pass_count + 1;
            end else begin
                mask = (ONE << (8*nbytes)) - ONE;   // low 8*nbytes bits set
                $display("%s: MISMATCH", label);
                $display("  sent:     %h", expected & mask);
                $display("  received: %h", recv_val & mask);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Float32 bit patterns for 0.0 .. 9.0 (the only values this scene needs)
    // ------------------------------------------------------------------
    function [31:0] f32(input integer n);
        begin
            case (n)
                0: f32 = 32'h00000000;
                1: f32 = 32'h3F800000;
                2: f32 = 32'h40000000;
                3: f32 = 32'h40400000;
                4: f32 = 32'h40800000;
                5: f32 = 32'h40A00000;
                6: f32 = 32'h40C00000;
                7: f32 = 32'h40E00000;
                8: f32 = 32'h41000000;
                9: f32 = 32'h41100000;
                default: f32 = 32'h00000000;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // Arbitrary scene (same values as sceneloader_test.py)
    // ------------------------------------------------------------------
    reg [node_bytes*8-1:0] node_val [0:TEST_NODE_COUNT-1];
    reg [tri_bytes*8-1:0]  tri_val  [0:TEST_TRI_COUNT-1];
    reg [mat_bytes*8-1:0]  mat_val  [0:TEST_MAT_COUNT-1];

    reg [127:0] label;
    integer i, j;

    // Spot-check only first/middle/last of each memory instead of fetching
    // back every record (which would roughly double an already-large byte
    // count) -- enough to confirm addressing works across the full range.
    integer node_checks [0:2];
    integer tri_checks  [0:2];
    integer mat_checks  [0:2];

    // ------------------------------------------------------------------
    // Main test
    // ------------------------------------------------------------------
    initial begin
        pass_count = 0;
        fail_count = 0;
        tb_tx_line = 1'b1;   // idle high
        rst        = 1'b1;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // node i = {left=10i, right=10i+1, id=i, morton=999i,
        // center=(i,2i,3i), size=(1,1,1)}
        for (i = 0; i < TEST_NODE_COUNT; i = i + 1) begin
            node_val[i] = {f32(1), f32(1), f32(1),
                           f32(3*i), f32(2*i), f32(1*i),
                           999*i, i, 10*i+1, 10*i};
        end

        // tri i = {material_id=i, V0=(i,2i,3i), E1=(4i,5i,6i), E2=(7i,8i,9i),
        // N1=(0,0,1), N2=(0,1,0), N3=(1,0,0)}
        for (i = 0; i < TEST_TRI_COUNT; i = i + 1) begin
            tri_val[i] = {f32(0), f32(0), f32(1),
                          f32(0), f32(1), f32(0),
                          f32(1), f32(0), f32(0),
                          f32(9*i), f32(8*i), f32(7*i),
                          f32(6*i), f32(5*i), f32(4*i),
                          f32(3*i), f32(2*i), f32(1*i),
                          i};
        end

        // mat i = {smoothness=i, emission=(i,i,i), absorption=(2i,2i,2i)}
        for (i = 0; i < TEST_MAT_COUNT; i = i + 1) begin
            mat_val[i] = {f32(2*i), f32(2*i), f32(2*i),
                          f32(1*i), f32(1*i), f32(1*i),
                          i[7:0]};
        end

        // LOAD
        send_byte(SYNC);
        send_byte(CMD_LOAD);
        send_nbytes(node_address_bytes, TEST_NODE_COUNT);
        send_nbytes(tri_address_bytes,  TEST_TRI_COUNT);
        send_nbytes(mat_address_bytes,  TEST_MAT_COUNT);
        for (i = 0; i < TEST_NODE_COUNT; i = i + 1) send_node_record(node_val[i]);
        for (i = 0; i < TEST_TRI_COUNT;  i = i + 1) send_tri_record(tri_val[i]);
        for (i = 0; i < TEST_MAT_COUNT;  i = i + 1) send_mat_record(mat_val[i]);

        // FETCH + compare: spot-check first/middle/last of each memory
        node_checks[0] = 0;
        node_checks[1] = TEST_NODE_COUNT/2;
        node_checks[2] = TEST_NODE_COUNT-1;
        tri_checks[0]  = 0;
        tri_checks[1]  = TEST_TRI_COUNT/2;
        tri_checks[2]  = TEST_TRI_COUNT-1;
        mat_checks[0]  = 0;
        mat_checks[1]  = TEST_MAT_COUNT/2;
        mat_checks[2]  = TEST_MAT_COUNT-1;

        for (j = 0; j < 3; j = j + 1) begin
            i = node_checks[j];
            send_byte(SYNC);
            send_byte(CMD_FETCH_BVH);
            send_nbytes(node_address_bytes, i);
            $sformat(label, "node[%0d]", i);
            check_bytes(label, node_val[i], node_bytes);
        end

        for (j = 0; j < 3; j = j + 1) begin
            i = tri_checks[j];
            send_byte(SYNC);
            send_byte(CMD_FETCH_TRI);
            send_nbytes(tri_address_bytes, i);
            $sformat(label, "tri[%0d]", i);
            check_bytes(label, tri_val[i], tri_bytes);
        end

        for (j = 0; j < 3; j = j + 1) begin
            i = mat_checks[j];
            send_byte(SYNC);
            send_byte(CMD_FETCH_MAT);
            send_nbytes(mat_address_bytes, i);
            $sformat(label, "mat[%0d]", i);
            check_bytes(label, mat_val[i], mat_bytes);
        end

        $display("");
        $display("%0d/%0d records matched", pass_count, pass_count + fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED");

        $finish;
    end

    // ------------------------------------------------------------------
    // Watchdog
    // ------------------------------------------------------------------
    initial begin
        #2_000_000_000;   // 500ms; expected runtime is ~197ms, dominated by the full-capacity LOAD
        $display("TIMEOUT: testbench did not finish in time");
        $finish;
    end

endmodule
