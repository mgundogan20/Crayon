`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/25/2026 01:09:19 PM
// Design Name: 
// Module Name: uart_parser
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


module uart_parser #(
    parameter integer mat_bytes      = 1+(3*4)+(3*4),                        // byte smoothness, float3 emission, float3 absorption
    parameter integer mat_address_bytes  = 1,
    parameter integer tri_bytes      = 4+(3*4)+(3*4)+(3*4)+(3*4)+(3*4)+(3*4), // int material_id, float3 V0, E1, E2, N1, N2, N3
    parameter integer tri_address_bytes  = 2,
    parameter integer node_bytes     = 4+4+4+4+(3*4)+(3*4),                  // int left, right, id, morton, float3 center, size
    parameter integer node_address_bytes  = 2
)(
    input  wire                            clk,
    input  wire                            rst,
    input  wire                            rx_valid,
    input  wire [7:0]                      rx_data,
    output reg                             tx_start,
    output reg  [7:0]                      tx_data,
    input  wire                            tx_ready,
    output reg  [mat_bytes*8-1:0]          mat_in,
    output reg  [tri_bytes*8-1:0]          tri_in,
    output reg  [node_bytes*8-1:0]         node_in,
    input  wire [mat_bytes*8-1:0]          mat_out,
    input  wire [tri_bytes*8-1:0]          tri_out,
    input  wire [node_bytes*8-1:0]         node_out,
    output reg  [mat_address_bytes*8-1:0]  mat_address,
    output reg  [tri_address_bytes*8-1:0]  tri_address,
    output reg  [node_address_bytes*8-1:0] node_address,
    output reg  [2:0]                      write_mat_tri_node, // [2]=mat, [1]=tri, [0]=node
    output reg                             load_done
);

    // ------------------------------------------------------------------
    // Sizes
    // ------------------------------------------------------------------
    localparam integer MAX_BYTES =
        (tri_bytes > node_bytes) ? ((tri_bytes  > mat_bytes) ? tri_bytes  : mat_bytes)
                                 : ((node_bytes > mat_bytes) ? node_bytes : mat_bytes);
    localparam integer IDX_W = $clog2(MAX_BYTES);

    localparam integer MAX_ADDR_BYTES =
        (tri_address_bytes > node_address_bytes)
            ? ((tri_address_bytes  > mat_address_bytes) ? tri_address_bytes  : mat_address_bytes)
            : ((node_address_bytes > mat_address_bytes) ? node_address_bytes : mat_address_bytes);
    localparam integer REC_W = 8*MAX_ADDR_BYTES;

    // ------------------------------------------------------------------
    // Commands and states
    // ------------------------------------------------------------------
    localparam [7:0] CMD_LOAD      = 8'h5A;
    localparam [7:0] CMD_FETCH_BVH = 8'h5B;
    localparam [7:0] CMD_FETCH_TRI = 8'h5C;
    localparam [7:0] CMD_FETCH_MAT = 8'h5D;

    localparam IDLE       = 4'd0;
    localparam START      = 4'd1;
    localparam COUNT_BVH  = 4'd2;
    localparam COUNT_TRI  = 4'd3;
    localparam COUNT_MAT  = 4'd4;
    localparam BVH        = 4'd5;
    localparam TRI        = 4'd6;
    localparam MAT        = 4'd7;
    localparam FETCH_BVH  = 4'd8;  // receive node address
    localparam FETCH_TRI  = 4'd9;  // receive tri address
    localparam FETCH_MAT  = 4'd10; // receive mat address
    localparam FETCH_WAIT = 4'd11; // wait for memory read
    localparam FETCH_SEND = 4'd12; // send record bytes

    localparam [1:0] SEL_BVH = 2'd0;
    localparam [1:0] SEL_TRI = 2'd1;
    localparam [1:0] SEL_MAT = 2'd2;

    reg [3:0] state;

    reg [8*MAX_BYTES-1:0]        data_buffer;  // record being received, or being sent back
    reg [IDX_W-1:0]              byte_index;   // which byte of the field/record is next
    reg [REC_W-1:0]              rec_index;    // which record of the section is next

    reg [node_address_bytes*8-1:0] node_count;
    reg [tri_address_bytes*8-1:0]  tri_count;
    reg [mat_address_bytes*8-1:0]  mat_count;

    reg [1:0]       fetch_sel;    // which memory the fetch reads
    reg [IDX_W-1:0] fetch_last;   // index of the last byte to send
    reg             mem_wait;     // memory read latency counter

    // ------------------------------------------------------------------
    // Parser
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state              <= IDLE;
            data_buffer        <= 0;
            byte_index         <= 0;
            rec_index          <= 0;
            node_count         <= 0;
            tri_count          <= 0;
            mat_count          <= 0;
            mat_in             <= 0;
            tri_in             <= 0;
            node_in            <= 0;
            mat_address        <= 0;
            tri_address        <= 0;
            node_address       <= 0;
            write_mat_tri_node <= 3'b000;
            load_done          <= 1'b0;
            tx_start           <= 1'b0;
            tx_data            <= 8'h00;
            fetch_sel          <= SEL_BVH;
            fetch_last         <= 0;
            mem_wait           <= 1'b0;
        end else begin
            // Pulses default low; set for one clock below.
            write_mat_tri_node <= 3'b000;
            load_done          <= 1'b0;

            case (state)

                IDLE: begin
                    if (rx_valid && rx_data == 8'hA5)
                        state <= START;
                end

                START: begin
                    if (rx_valid) begin
                        byte_index <= 0;
                        rec_index  <= 0;
                        case (rx_data)
                            CMD_LOAD:      state <= COUNT_BVH;
                            CMD_FETCH_BVH: state <= FETCH_BVH;
                            CMD_FETCH_TRI: state <= FETCH_TRI;
                            CMD_FETCH_MAT: state <= FETCH_MAT;
                            8'hA5:         state <= START;   // A5 A5 5A still syncs
                            default:       state <= IDLE;
                        endcase
                    end
                end

                // ---- counts ------------------------------------------------
                COUNT_BVH: begin
                    if (rx_valid) begin
                        node_count[8*byte_index +: 8] <= rx_data;
                        if (byte_index == node_address_bytes-1) begin
                            byte_index <= 0;
                            state      <= COUNT_TRI;
                        end else
                            byte_index <= byte_index + 1'b1;
                    end
                end

                COUNT_TRI: begin
                    if (rx_valid) begin
                        tri_count[8*byte_index +: 8] <= rx_data;
                        if (byte_index == tri_address_bytes-1) begin
                            byte_index <= 0;
                            state      <= COUNT_MAT;
                        end else
                            byte_index <= byte_index + 1'b1;
                    end
                end

                COUNT_MAT: begin
                    if (rx_valid) begin
                        mat_count[8*byte_index +: 8] <= rx_data;
                        if (byte_index == mat_address_bytes-1) begin
                            byte_index <= 0;
                            state      <= BVH;
                        end else
                            byte_index <= byte_index + 1'b1;
                    end
                end

                // ---- records -----------------------------------------------
                // Every section is guaranteed to hold at least one record.
                BVH: begin
                    if (rx_valid) begin
                        if (byte_index == node_bytes-1) begin
                            // Last byte: assemble the record directly so it is
                            // ready on the same edge as the write pulse.
                            node_in            <= {rx_data, data_buffer[8*(node_bytes-1)-1:0]};
                            node_address       <= rec_index[node_address_bytes*8-1:0];
                            write_mat_tri_node <= 3'b001;
                            byte_index         <= 0;
                            if (rec_index == node_count - 1) begin
                                rec_index <= 0;
                                state     <= TRI;
                            end else
                                rec_index <= rec_index + 1'b1;
                        end else begin
                            data_buffer[8*byte_index +: 8] <= rx_data;
                            byte_index <= byte_index + 1'b1;
                        end
                    end
                end

                TRI: begin
                    if (rx_valid) begin
                        if (byte_index == tri_bytes-1) begin
                            tri_in             <= {rx_data, data_buffer[8*(tri_bytes-1)-1:0]};
                            tri_address        <= rec_index[tri_address_bytes*8-1:0];
                            write_mat_tri_node <= 3'b010;
                            byte_index         <= 0;
                            if (rec_index == tri_count - 1) begin
                                rec_index <= 0;
                                state     <= MAT;
                            end else
                                rec_index <= rec_index + 1'b1;
                        end else begin
                            data_buffer[8*byte_index +: 8] <= rx_data;
                            byte_index <= byte_index + 1'b1;
                        end
                    end
                end

                MAT: begin
                    if (rx_valid) begin
                        if (byte_index == mat_bytes-1) begin
                            mat_in             <= {rx_data, data_buffer[8*(mat_bytes-1)-1:0]};
                            mat_address        <= rec_index[mat_address_bytes*8-1:0];
                            write_mat_tri_node <= 3'b100;
                            byte_index         <= 0;
                            if (rec_index == mat_count - 1) begin
                                rec_index <= 0;
                                load_done <= 1'b1;
                                state     <= IDLE;
                            end else
                                rec_index <= rec_index + 1'b1;
                        end else begin
                            data_buffer[8*byte_index +: 8] <= rx_data;
                            byte_index <= byte_index + 1'b1;
                        end
                    end
                end

                // ---- fetch: receive address --------------------------------
                FETCH_BVH: begin
                    if (rx_valid) begin
                        node_address[8*byte_index +: 8] <= rx_data;
                        if (byte_index == node_address_bytes-1) begin
                            fetch_sel  <= SEL_BVH;
                            fetch_last <= node_bytes-1;
                            mem_wait   <= 1'b1;
                            state      <= FETCH_WAIT;
                        end else
                            byte_index <= byte_index + 1'b1;
                    end
                end

                FETCH_TRI: begin
                    if (rx_valid) begin
                        tri_address[8*byte_index +: 8] <= rx_data;
                        if (byte_index == tri_address_bytes-1) begin
                            fetch_sel  <= SEL_TRI;
                            fetch_last <= tri_bytes-1;
                            mem_wait   <= 1'b1;
                            state      <= FETCH_WAIT;
                        end else
                            byte_index <= byte_index + 1'b1;
                    end
                end

                FETCH_MAT: begin
                    if (rx_valid) begin
                        mat_address[8*byte_index +: 8] <= rx_data;
                        if (byte_index == mat_address_bytes-1) begin
                            fetch_sel  <= SEL_MAT;
                            fetch_last <= mat_bytes-1;
                            mem_wait   <= 1'b1;
                            state      <= FETCH_WAIT;
                        end else
                            byte_index <= byte_index + 1'b1;
                    end
                end

                // ---- fetch: read memory ------------------------------------
                // Clock 1: the memory registers *_out from the new address.
                // Clock 2: *_out is valid; copy it into the buffer.
                FETCH_WAIT: begin
                    if (mem_wait)
                        mem_wait <= 1'b0;
                    else begin
                        case (fetch_sel)
                            SEL_BVH: data_buffer <= node_out;
                            SEL_TRI: data_buffer <= tri_out;
                            default: data_buffer <= mat_out;
                        endcase
                        byte_index <= 0;
                        state      <= FETCH_SEND;
                    end
                end

                // ---- fetch: send bytes -------------------------------------
                // Present a byte with tx_start high, hold it until the
                // transmitter accepts it (tx_start && tx_ready), then move on.
                FETCH_SEND: begin
                    if (!tx_start) begin
                        tx_data  <= data_buffer[8*byte_index +: 8];
                        tx_start <= 1'b1;
                    end else if (tx_ready) begin
                        // Accepted on this edge.
                        tx_start <= 1'b0;
                        if (byte_index == fetch_last) begin
                            byte_index <= 0;
                            state      <= IDLE;
                        end else
                            byte_index <= byte_index + 1'b1;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule