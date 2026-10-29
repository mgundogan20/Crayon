`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/27/2026 08:49:44 PM
// Design Name: 
// Module Name: bounce
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


module bounce(
    input clk,
    input rst,
    input [32*3*2-1:0] ray, // We assum accum_col and ray_col are pre-initialized and not loaded/generated
    input [15*32-1:0] triang,
    input [1:0] state,
    output [32*3*2-1:0] out_ray
    );
    //HIT[15:0]: distance;
    //HIT[79:16]: Vector3 position;
    //HIT[143:80]: Vector3 surface_normal;
    //HIT[207:144]: Vector3 diffuseColor;
    //HIT[271:208]: Vector3 emissionColor;
    wire [13*32-1:0] hit;
    reg [13*32-1:0] firsthit;
    intersect check_intersection(clk,rst,ray,triang,hit);
    
    wire first_hit_greater;
    
    wire first_hit_valid;
    // COMPARATOR with hit
    // COMPARATOR with 1 billion
    
    
    wire [95:0] accum_col;
    wire [95:0] ray_col;
    
    
    always @ (posedge clk) begin
        if(rst) begin
            firsthit <= 416'd0;
        end else begin
            if(state == 0 && first_hit_greater) begin
                firsthit <= hit;
            end
            if(state == 1) begin
                if(first_hit_valid) begin
                    out_ray <= {accum_col,ray_col};// FIX THIS
                end else begin
                    out_ray <= {0,ray_col};// FIX THIS
                end
            
            end
        end
    
    
    
    end
     
    
    
    
    
endmodule
