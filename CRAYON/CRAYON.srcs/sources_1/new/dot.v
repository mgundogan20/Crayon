`timescale 1ns / 1ps
// c = a.x*b.x + a.y*b.y + a.z*b.z, evaluated as (x + y) + z, which is the
// same order as Unity's Vector3.Dot -> bit-identical rounding.
// Vectors are packed {z, y, x}, x in [31:0].
// Latency: MUL + 2*ADD = 8 + 11 + 11 = 30 cycles, II = 1.
module dot(
    input  wire        clk,
    input  wire        rst,
    input  wire        a_ready,
    input  wire [95:0] vec_a,
    input  wire        b_ready,
    input  wire [95:0] vec_b,
    output wire        c_ready,
    output wire [31:0] c
);
    localparam integer LAT_ADD = 11;

    wire        m0_v, m1_v, m2_v;
    wire [31:0] m0,   m1,   m2;

    multiply mult_0 (.aclk(clk),
        .s_axis_a_tvalid(a_ready), .s_axis_a_tdata(vec_a[31:0]),
        .s_axis_b_tvalid(b_ready), .s_axis_b_tdata(vec_b[31:0]),
        .m_axis_result_tvalid(m0_v), .m_axis_result_tdata(m0));
    multiply mult_1 (.aclk(clk),
        .s_axis_a_tvalid(a_ready), .s_axis_a_tdata(vec_a[63:32]),
        .s_axis_b_tvalid(b_ready), .s_axis_b_tdata(vec_b[63:32]),
        .m_axis_result_tvalid(m1_v), .m_axis_result_tdata(m1));
    multiply mult_2 (.aclk(clk),
        .s_axis_a_tvalid(a_ready), .s_axis_a_tdata(vec_a[95:64]),
        .s_axis_b_tvalid(b_ready), .s_axis_b_tdata(vec_b[95:64]),
        .m_axis_result_tvalid(m2_v), .m_axis_result_tdata(m2));

    wire        s01_v;
    wire [31:0] s01;
    add add_0 (.aclk(clk),
        .s_axis_a_tvalid(m0_v), .s_axis_a_tdata(m0),
        .s_axis_b_tvalid(m1_v), .s_axis_b_tdata(m1),
        .m_axis_result_tvalid(s01_v), .m_axis_result_tdata(s01));

    // FIX: z*z is ready 11 cycles before (x*x + y*y). In NonBlocking mode the
    // core only fires when both TVALIDs are high in the SAME cycle, so the
    // z term (data AND valid) has to wait for add_0.
    wire        m2_v_d;
    wire [31:0] m2_d;
    delay #(.W(33), .N(LAT_ADD)) dly_z (.clk(clk), .d({m2_v, m2}), .q({m2_v_d, m2_d}));

    add add_1 (.aclk(clk),
        .s_axis_a_tvalid(s01_v),  .s_axis_a_tdata(s01),
        .s_axis_b_tvalid(m2_v_d), .s_axis_b_tdata(m2_d),
        .m_axis_result_tvalid(c_ready), .m_axis_result_tdata(c));
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


module dot(
    input clk,
    input rst,
    input a_ready,
    input [95:0] vec_a,
    input b_ready,
    input [95:0] vec_b,
    output c_ready,
    output [31:0] c
    );
    
    wire mult_0_done;
    wire [31:0] term_0;
    multiply mult_0(
        clk,
        a_ready,
        vec_a[31:0],
        b_ready,
        vec_b[31:0],
        mult_0_done,
        term_0
    );
    
    wire mult_1_done;
    wire [31:0] term_1;
    multiply mult_1(
        clk,
        a_ready,
        vec_a[63:32],
        b_ready,
        vec_b[63:32],
        mult_1_done,
        term_1
    );
    
    wire mult_2_done;
    wire [31:0] term_2;
    multiply mult_2(
        clk,
        a_ready,
        vec_a[95:64],
        b_ready,
        vec_b[95:64],
        mult_2_done,
        term_2
    );
    
    wire add_0_done;
    wire [31:0] term_a;
    add add_0(
      clk,
      mult_0_done,
      term_0,
      mult_1_done,
      term_1,
      add_0_done,
      term_a
    );
    
    
    
    add add_1(
      clk,
      add_0_done,
      term_a,
      mult_2_done,
      term_2,
      c_ready,
      c
    );

endmodule
*/
