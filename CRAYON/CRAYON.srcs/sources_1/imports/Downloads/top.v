`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// top -- Nexys A7-100T
//   PC -> FPGA : triangle packet (A5 5A ...), then ray packet (A5 5B ...)
//                or camera packet (A5 5C ...): rays generated on the FPGA
//   FPGA -> PC : one result packet (A5 5D ...) per batch of MAX_RAYS rays
// LEDs: 0 triangles loaded, 1 rays loaded, 2 busy, 3 frame done,
//       4 packet error, 5 overrun (data sent while busy), 7:6 bounce index
//////////////////////////////////////////////////////////////////////////////////
module top #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 3_000_000,         // must match FpgaPolygonSender.baudRate
    parameter integer MAX_RAYS = 4096,         // ray-memory size = batch size (FpgaPolygonSender.MaxRays)
    parameter integer RAW      = 12            // clog2(MAX_RAYS)
)(
    input  wire       clk,
    input  wire       rst,        // BTNC, active high
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [7:0] led
);
    localparam integer MAX_TRIANGLES = 128, TAW = 7;

    // reset synchronizer
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk) rst_sync <= {rst_sync[0], rst};
    wire srst = rst_sync[1];

    wire [7:0] rx_data; wire rx_valid;
    polygon_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(srst), .uart_rx(uart_rx), .rx_valid(rx_valid), .rx_data(rx_data));

    wire tri_we, tris_done, ray_we, rays_done, pkt_err;
    wire [TAW-1:0] tri_idx; wire [3:0] tri_slot; wire [31:0] tri_wdata; wire [15:0] tri_count;
    wire [RAW-1:0] ray_addr; wire [191:0] ray_wdata; wire [15:0] ray_count;
    wire [7:0] bounces, flags; wire [31:0] seed;
    wire [15:0] cam_xres, cam_yres; wire [31:0] cam_fov; wire [95:0] cam_pos, cam_fwd, cam_right, cam_up;
    wire cam_done;
    packet_parser #(.MAX_TRIANGLES(MAX_TRIANGLES), .TAW(TAW), .MAX_RAYS(MAX_RAYS), .RAW(RAW)) u_parse (
        .clk(clk), .rst(srst), .rx_data(rx_data), .rx_valid(rx_valid),
        .tri_we(tri_we), .tri_idx(tri_idx), .tri_slot(tri_slot), .tri_wdata(tri_wdata),
        .tri_count(tri_count), .tris_done(tris_done),
        .ray_we(ray_we), .ray_addr(ray_addr), .ray_wdata(ray_wdata), .ray_count(ray_count),
        .rays_done(rays_done),
        .cam_xres(cam_xres), .cam_yres(cam_yres), .cam_fov(cam_fov), .cam_pos(cam_pos),
        .cam_fwd(cam_fwd), .cam_right(cam_right), .cam_up(cam_up), .cam_done(cam_done),
        .bounces(bounces), .flags(flags), .seed(seed),
        .packet_error(pkt_err));

    wire tx_start, tx_ready; wire [7:0] tx_data;
    wire busy, frame_done, overrun; wire [7:0] bounce_dbg;
    rt_core #(.MAX_TRIANGLES(MAX_TRIANGLES), .TAW(TAW), .MAX_RAYS(MAX_RAYS), .RAW(RAW),
              .LAT_DIV(28), .LAT_SQRT(28)) u_core (
        .clk(clk), .rst(srst),
        .tri_we(tri_we), .tri_idx(tri_idx), .tri_slot(tri_slot), .tri_wdata(tri_wdata), .tri_count(tri_count),
        .ray_we(ray_we), .ray_addr(ray_addr), .ray_wdata(ray_wdata), .ray_count(ray_count),
        .rays_done(rays_done),
        .cam_xres(cam_xres), .cam_yres(cam_yres), .cam_fov(cam_fov), .cam_pos(cam_pos),
        .cam_fwd(cam_fwd), .cam_right(cam_right), .cam_up(cam_up), .cam_done(cam_done),
        .bounces(bounces), .flags(flags), .seed(seed),
        .tx_start(tx_start), .tx_data(tx_data), .tx_ready(tx_ready),
        .busy(busy), .frame_done(frame_done), .overrun(overrun), .bounce_dbg(bounce_dbg));

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(srst), .start(tx_start), .data(tx_data), .ready(tx_ready), .tx(uart_tx));

    // status LEDs
    reg tris_loaded, rays_loaded, err_seen;
    always @(posedge clk) begin
        if (srst) begin tris_loaded <= 0; rays_loaded <= 0; err_seen <= 0; end
        else begin
            if (tris_done) tris_loaded <= 1'b1;
            if (rays_done | cam_done) rays_loaded <= 1'b1;
            if (pkt_err)   err_seen    <= 1'b1;
        end
    end
    assign led = {bounce_dbg[1:0], overrun, err_seen, frame_done, busy, rays_loaded, tris_loaded};
endmodule
