`timescale 1ns / 1ps
// Component-wise vector helpers, packed {z, y, x}.
// vec_mul3 also does scalar*vector: pass {s, s, s} as one operand
// (identical to Unity's float*Vector3, which is three scalar multiplies).
// vec_mul3: 8 cycles. vec_add3 / vec_sub3: 11 cycles. vec_div3: LAT of your divide IP.

module vec_mul3(input wire clk, input wire in_valid, input wire [95:0] a, input wire [95:0] b,
                output wire out_valid, output wire [95:0] c);
    wire [2:0] v;
    genvar i;
    generate for (i = 0; i < 3; i = i + 1) begin : g
        multiply u (.aclk(clk),
            .s_axis_a_tvalid(in_valid), .s_axis_a_tdata(a[32*i +: 32]),
            .s_axis_b_tvalid(in_valid), .s_axis_b_tdata(b[32*i +: 32]),
            .m_axis_result_tvalid(v[i]), .m_axis_result_tdata(c[32*i +: 32]));
    end endgenerate
    assign out_valid = v[0];
endmodule

module vec_add3(input wire clk, input wire in_valid, input wire [95:0] a, input wire [95:0] b,
                output wire out_valid, output wire [95:0] c);
    wire [2:0] v;
    genvar i;
    generate for (i = 0; i < 3; i = i + 1) begin : g
        add u (.aclk(clk),
            .s_axis_a_tvalid(in_valid), .s_axis_a_tdata(a[32*i +: 32]),
            .s_axis_b_tvalid(in_valid), .s_axis_b_tdata(b[32*i +: 32]),
            .m_axis_result_tvalid(v[i]), .m_axis_result_tdata(c[32*i +: 32]));
    end endgenerate
    assign out_valid = v[0];
endmodule

// c = a - b
module vec_sub3(input wire clk, input wire in_valid, input wire [95:0] a, input wire [95:0] b,
                output wire out_valid, output wire [95:0] c);
    wire [2:0] v;
    genvar i;
    generate for (i = 0; i < 3; i = i + 1) begin : g
        subtract u (.aclk(clk),
            .s_axis_a_tvalid(in_valid), .s_axis_a_tdata(a[32*i +: 32]),
            .s_axis_b_tvalid(in_valid), .s_axis_b_tdata(b[32*i +: 32]),
            .m_axis_result_tvalid(v[i]), .m_axis_result_tdata(c[32*i +: 32]));
    end endgenerate
    assign out_valid = v[0];
endmodule

// c = a / b (component-wise)
module vec_div3(input wire clk, input wire in_valid, input wire [95:0] a, input wire [95:0] b,
                output wire out_valid, output wire [95:0] c);
    wire [2:0] v;
    genvar i;
    generate for (i = 0; i < 3; i = i + 1) begin : g
        divide u (.aclk(clk),
            .s_axis_a_tvalid(in_valid), .s_axis_a_tdata(a[32*i +: 32]),
            .s_axis_b_tvalid(in_valid), .s_axis_b_tdata(b[32*i +: 32]),
            .m_axis_result_tvalid(v[i]), .m_axis_result_tdata(c[32*i +: 32]));
    end endgenerate
    assign out_valid = v[0];
endmodule
