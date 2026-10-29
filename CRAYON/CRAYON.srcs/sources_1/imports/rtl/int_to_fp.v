`timescale 1ns / 1ps
// Exact conversion of a signed 18-bit integer to IEEE-754 single (|v| < 2^17,
// always exact). Combinational: sign/magnitude + leading-one detect + shift.
// Same result as C#'s implicit int -> float conversion.
module int_to_fp(
    input  wire signed [17:0] v,
    output reg         [31:0] f
);
    wire        s   = v[17];
    wire [17:0] mag = s ? -v : v;
    integer i;
    reg [4:0]  msb;
    reg [17:0] norm;
    always @* begin
        msb = 0;
        for (i = 0; i < 18; i = i + 1)
            if (mag[i]) msb = i;
        norm = mag << (5'd17 - msb);           // leading one moves to bit 17
        if (mag == 0) f = 32'd0;
        else          f = {s, 8'd127 + {3'd0, msb}, norm[16:0], 6'd0};
    end
endmodule
