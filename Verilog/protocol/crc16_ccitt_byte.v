`timescale 1ns/1ps

// Combinational CRC-16/CCITT-FALSE update for one input byte.
module crc16_ccitt_byte (
    input wire [15:0] crc_in,
    input wire [7:0] data,
    output reg [15:0] crc_out
);
    integer bit_index;

    // Polynomial 0x1021, no reflection; caller supplies the initial CRC.
    always @* begin
        crc_out = crc_in ^ {data, 8'h00};
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            if (crc_out[15])
                crc_out = (crc_out << 1) ^ 16'h1021;
            else
                crc_out = crc_out << 1;
        end
    end
endmodule
