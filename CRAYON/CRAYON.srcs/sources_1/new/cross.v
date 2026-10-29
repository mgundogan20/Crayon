`timescale 1ns / 1ps
// c = a x b, same expression order as Unity's Vector3.Cross:
//   c.x = a.y*b.z - a.z*b.y ; c.y = a.z*b.x - a.x*b.z ; c.z = a.x*b.y - a.y*b.x
// Vectors are packed {z, y, x}, x in [31:0].
// Latency: MUL + SUB = 8 + 11 = 19 cycles, II = 1.
module cross(
    input  wire        clk,
    input  wire        rst,
    input  wire        a_ready,
    input  wire [95:0] vec_a,
    input  wire        b_ready,
    input  wire [95:0] vec_b,
    output wire        c_ready,
    output wire [95:0] vec_c
);
    wire [31:0] ax = vec_a[31:0], ay = vec_a[63:32], az = vec_a[95:64];
    wire [31:0] bx = vec_b[31:0], by = vec_b[63:32], bz = vec_b[95:64];

    wire [5:0]  mv;
    wire [31:0] m0, m1, m2, m3, m4, m5;

    multiply mult_0 (.aclk(clk), .s_axis_a_tvalid(a_ready), .s_axis_a_tdata(ay),
        .s_axis_b_tvalid(b_ready), .s_axis_b_tdata(bz), .m_axis_result_tvalid(mv[0]), .m_axis_result_tdata(m0));
    multiply mult_1 (.aclk(clk), .s_axis_a_tvalid(a_ready), .s_axis_a_tdata(az),
        .s_axis_b_tvalid(b_ready), .s_axis_b_tdata(by), .m_axis_result_tvalid(mv[1]), .m_axis_result_tdata(m1));
    multiply mult_2 (.aclk(clk), .s_axis_a_tvalid(a_ready), .s_axis_a_tdata(az),
        .s_axis_b_tvalid(b_ready), .s_axis_b_tdata(bx), .m_axis_result_tvalid(mv[2]), .m_axis_result_tdata(m2));
    multiply mult_3 (.aclk(clk), .s_axis_a_tvalid(a_ready), .s_axis_a_tdata(ax),
        .s_axis_b_tvalid(b_ready), .s_axis_b_tdata(bz), .m_axis_result_tvalid(mv[3]), .m_axis_result_tdata(m3));
    multiply mult_4 (.aclk(clk), .s_axis_a_tvalid(a_ready), .s_axis_a_tdata(ax),
        .s_axis_b_tvalid(b_ready), .s_axis_b_tdata(by), .m_axis_result_tvalid(mv[4]), .m_axis_result_tdata(m4));
    multiply mult_5 (.aclk(clk), .s_axis_a_tvalid(a_ready), .s_axis_a_tdata(ay),
        .s_axis_b_tvalid(b_ready), .s_axis_b_tdata(bx), .m_axis_result_tvalid(mv[5]), .m_axis_result_tdata(m5));

    wire [2:0]  sv;
    wire [31:0] cx, cy, cz;
    subtract sub_0 (.aclk(clk), .s_axis_a_tvalid(mv[0]), .s_axis_a_tdata(m0),
        .s_axis_b_tvalid(mv[1]), .s_axis_b_tdata(m1), .m_axis_result_tvalid(sv[0]), .m_axis_result_tdata(cx));
    subtract sub_1 (.aclk(clk), .s_axis_a_tvalid(mv[2]), .s_axis_a_tdata(m2),
        .s_axis_b_tvalid(mv[3]), .s_axis_b_tdata(m3), .m_axis_result_tvalid(sv[1]), .m_axis_result_tdata(cy));
    subtract sub_2 (.aclk(clk), .s_axis_a_tvalid(mv[4]), .s_axis_a_tdata(m4),
        .s_axis_b_tvalid(mv[5]), .s_axis_b_tdata(m5), .m_axis_result_tvalid(sv[2]), .m_axis_result_tdata(cz));

    assign vec_c   = {cz, cy, cx};
    assign c_ready = sv[0];   // FIX: was undriven. All three lanes are aligned.
endmodule
/*`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/27/2026 09:25:10 PM
// Design Name: 
// Module Name: dot
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


module cross(
    input clk,
    input rst,
    input a_ready,
    input [95:0] vec_a,
    input b_ready,
    input [95:0] vec_b,
    output c_ready,
    output [95:0] vec_c
    );
    
    wire mult_0_done;
    wire [31:0] term_0;
    multiply mult_0(
        clk,
        a_ready,
        vec_a[63:32],
        b_ready,
        vec_b[95:64],
        mult_0_done,
        term_0
    );
    
    wire mult_1_done;
    wire [31:0] term_1;
    multiply mult_1(
        clk,
        a_ready,
        vec_a[95:64],
        b_ready,
        vec_b[63:32],
        mult_1_done,
        term_1
    );
    
    wire sub_0_done;
    wire [31:0] term_a;
    subtract sub_0(
      clk,
      mult_0_done,
      term_0,
      mult_1_done,
      term_1,
      sub_0_done,
      term_a
    );
    
    wire mult_2_done;
    wire [31:0] term_2;
    multiply mult_2(
        clk,
        a_ready,
        vec_a[95:64],
        b_ready,
        vec_b[31:0],
        mult_2_done,
        term_2
    );
    
    wire mult_3_done;
    wire [31:0] term_3;
    multiply mult_3(
        clk,
        a_ready,
        vec_a[31:0],
        b_ready,
        vec_b[95:64],
        mult_3_done,
        term_3
    );
    
    wire sub_1_done;
    wire [31:0] term_b;
    subtract sub_1(
      clk,
      mult_2_done,
      term_2,
      mult_3_done,
      term_3,
      sub_1_done,
      term_b
    );

    wire mult_4_done;
    wire [31:0] term_4;
    multiply mult_4(
        clk,
        a_ready,
        vec_a[31:0],
        b_ready,
        vec_b[63:32],
        mult_4_done,
        term_4
    );
    
    wire mult_5_done;
    wire [31:0] term_5;
    multiply mult_5(
        clk,
        a_ready,
        vec_a[63:32],
        b_ready,
        vec_b[31:0],
        mult_5_done,
        term_5
    );
    
    wire sub_2_done;
    wire [31:0] term_c;
    subtract sub_2(
      clk,
      mult_4_done,
      term_4,
      mult_5_done,
      term_5,
      sub_2_done,
      term_c
    );

    assign vec_c = {term_c,term_b,term_a};
endmodule*/
