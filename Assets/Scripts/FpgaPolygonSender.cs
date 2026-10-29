using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Ports;
using UnityEngine;

/// <summary>
/// Serial link to the Nexys A7.
///   PC -> FPGA  triangles : A5 5A | count u16 | count x 15 float32
///   PC -> FPGA  rays      : A5 5B | count u16 | bounces u8 | flags u8 | seed u32 | count x 6 float32
///   PC -> FPGA  camera    : A5 5C | X_res u16 | Y_res u16 | bounces u8 | flags u8 | seed u32 |
///                           fov f32 | position 3f | forward 3f | right 3f | up 3f
///   FPGA -> PC  results   : A5 5D | count u16 | count x 3 float32 (accum_col), one packet per batch
/// flags: bit0 = perturb after bounces, bit1 = primary-ray jitter (camera packet only).
/// Everything little-endian. A ray or camera packet starts the frame.
/// </summary>
public class FpgaPolygonSender : MonoBehaviour
{
    [SerializeField] private string portName = "COM5";
    [SerializeField] private int baudRate = 115200;          // must match top.v BAUD

    public const int MaxTriangles = 128;                      // top.v MAX_TRIANGLES
    public const int MaxRays = 4096;                          // top.v MAX_RAYS = batch size of camera frames

    private SerialPort serialPort;

    public void Connect()
    {
        if (serialPort != null && serialPort.IsOpen)
            return;

        serialPort = new SerialPort(portName, baudRate, Parity.None, 8, StopBits.One);
        serialPort.Handshake = Handshake.None;
        serialPort.WriteTimeout = 5000;
        serialPort.ReadTimeout = 5000;
        serialPort.ReadBufferSize = 1 << 20;
        serialPort.WriteBufferSize = 1 << 20;
        serialPort.Open();
        serialPort.DiscardInBuffer();
    }

    public void Disconnect()
    {
        if (serialPort == null)
            return;
        if (serialPort.IsOpen)
            serialPort.Close();
        serialPort.Dispose();
        serialPort = null;
    }

    // ------------------------------------------------------------------ helpers
    private static void WriteFloatLE(BinaryWriter writer, float value)
    {
        byte[] bytes = BitConverter.GetBytes(value);
        if (!BitConverter.IsLittleEndian)
            Array.Reverse(bytes);
        writer.Write(bytes);
    }

    private static void WriteVector3LE(BinaryWriter writer, Vector3 value)
    {
        WriteFloatLE(writer, value.x);
        WriteFloatLE(writer, value.y);
        WriteFloatLE(writer, value.z);
    }

    private static void WriteU16LE(BinaryWriter w, int v) { w.Write((byte)(v & 0xFF)); w.Write((byte)((v >> 8) & 0xFF)); }

    private static void WriteU32LE(BinaryWriter w, uint v)
    {
        w.Write((byte)v); w.Write((byte)(v >> 8)); w.Write((byte)(v >> 16)); w.Write((byte)(v >> 24));
    }

    private int TimeoutFor(int bytes)
    {
        // 10 bits per byte, x2 margin, + 2 s
        return (int)(bytes * 10L * 1000L * 2L / baudRate) + 2000;
    }

    private void WritePacket(byte[] packet)
    {
        if (serialPort == null || !serialPort.IsOpen)
            throw new InvalidOperationException("Connect to the FPGA before sending.");
        serialPort.WriteTimeout = TimeoutFor(packet.Length);
        serialPort.Write(packet, 0, packet.Length);
    }

    // ------------------------------------------------------------------ triangles
    public static byte[] SerializePolygons(List<Polygon> tris)
    {
        if (tris == null)
            throw new ArgumentNullException(nameof(tris));
        if (tris.Count > MaxTriangles)
            throw new ArgumentException($"The FPGA supports at most {MaxTriangles} polygons (got {tris.Count}).");

        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream))
        {
            writer.Write((byte)0xA5);
            writer.Write((byte)0x5A);
            WriteU16LE(writer, tris.Count);
            foreach (Polygon p in tris)
            {
                WriteVector3LE(writer, p.V0);
                WriteVector3LE(writer, p.E1);
                WriteVector3LE(writer, p.E2);
                WriteVector3LE(writer, p.diffuseColor);
                WriteVector3LE(writer, p.emissionColor);
            }
            writer.Flush();
            return stream.ToArray();
        }
    }

    public void SendPolygons(List<Polygon> tris)
    {
        byte[] packet = SerializePolygons(tris);
        WritePacket(packet);
        Debug.Log($"Sent {tris.Count} polygons, {packet.Length} bytes.");
    }

    // ------------------------------------------------------------------ rays
    /// <summary>Only origin and direction are sent; the FPGA starts every ray with ray_col = 1, accum_col = 0.</summary>
    public static byte[] SerializeRays(RTRay[] rays, int bounces, bool perturb, uint seed)
    {
        if (rays == null)
            throw new ArgumentNullException(nameof(rays));
        if (rays.Length > MaxRays)
            throw new ArgumentException($"The FPGA supports at most {MaxRays} rays (got {rays.Length}).");
        if (bounces < 0 || bounces > 255)
            throw new ArgumentException("bounces must be 0..255");

        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream))
        {
            writer.Write((byte)0xA5);
            writer.Write((byte)0x5B);
            WriteU16LE(writer, rays.Length);
            writer.Write((byte)bounces);
            writer.Write((byte)(perturb ? 1 : 0));
            WriteU32LE(writer, seed);
            foreach (RTRay r in rays)
            {
                WriteVector3LE(writer, r.origin);
                WriteVector3LE(writer, r.direction);
            }
            writer.Flush();
            return stream.ToArray();
        }
    }

    /// <summary>Sending the ray packet starts the frame on the FPGA.</summary>
    public void SendRays(RTRay[] rays, int bounces, bool perturb, uint seed)
    {
        byte[] packet = SerializeRays(rays, bounces, perturb, seed);
        serialPort.DiscardInBuffer();               // drop anything stale before the result arrives
        WritePacket(packet);
        Debug.Log($"Sent {rays.Length} rays, {packet.Length} bytes.");
    }

    // ------------------------------------------------------------------ camera
    public static byte[] SerializeCamera(FpgaReference.CameraSetup cam, int bounces, bool perturb, bool jitter, uint seed)
    {
        if (cam.xRes < 0 || cam.xRes > 65535 || cam.yRes < 0 || cam.yRes > 65535)
            throw new ArgumentException("X_res / Y_res must be 0..65535");
        if (bounces < 0 || bounces > 255)
            throw new ArgumentException("bounces must be 0..255");

        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream))
        {
            writer.Write((byte)0xA5);
            writer.Write((byte)0x5C);
            WriteU16LE(writer, cam.xRes);
            WriteU16LE(writer, cam.yRes);
            writer.Write((byte)bounces);
            writer.Write((byte)((perturb ? 1 : 0) | (jitter ? 2 : 0)));
            WriteU32LE(writer, seed);
            WriteFloatLE(writer, cam.fov);
            WriteVector3LE(writer, cam.position);
            WriteVector3LE(writer, cam.forward);
            WriteVector3LE(writer, cam.right);
            WriteVector3LE(writer, cam.up);
            writer.Flush();
            return stream.ToArray();
        }
    }

    /// <summary>Starts a frame whose rays are generated on the FPGA.</summary>
    public void SendCamera(FpgaReference.CameraSetup cam, int bounces, bool perturb, bool jitter, uint seed)
    {
        byte[] packet = SerializeCamera(cam, bounces, perturb, jitter, seed);
        serialPort.DiscardInBuffer();
        WritePacket(packet);
        Debug.Log($"Sent camera {cam.xRes}x{cam.yRes}.");
    }

    /// <summary>
    /// Receives the result packets of a camera frame (one per batch of MaxRays pixels)
    /// and returns accum_col per pixel, index x*yRes + y.
    /// </summary>
    public Vector3[] ReceiveFrame(int totalRays)
    {
        Vector3[] all = new Vector3[totalRays];
        int got = 0;
        while (got < totalRays)
        {
            int expected = Math.Min(MaxRays, totalRays - got);
            Vector3[] part = ReceiveResults(expected);
            Array.Copy(part, 0, all, got, part.Length);
            got += part.Length;
        }
        return all;
    }

    // ------------------------------------------------------------------ results
    private void ReadExactly(byte[] buf, int count)
    {
        int got = 0;
        while (got < count)
        {
            int n = serialPort.Read(buf, got, count - got);   // throws TimeoutException
            if (n <= 0) throw new IOException("Serial port closed.");
            got += n;
        }
    }

    /// <summary>Blocks until the FPGA sends the accum_col of every ray (in the order sent).</summary>
    public Vector3[] ReceiveResults(int expectedCount)
    {
        if (serialPort == null || !serialPort.IsOpen)
            throw new InvalidOperationException("Connect to the FPGA before receiving.");

        serialPort.ReadTimeout = TimeoutFor(expectedCount * 12 + 4) + 5000;
        byte[] one = new byte[1];

        // sync on A5 5D
        int state = 0;
        while (state < 2)
        {
            ReadExactly(one, 1);
            if (state == 0) state = (one[0] == 0xA5) ? 1 : 0;
            else state = (one[0] == 0x5D) ? 2 : (one[0] == 0xA5 ? 1 : 0);
        }

        byte[] hdr = new byte[2];
        ReadExactly(hdr, 2);
        int count = hdr[0] | (hdr[1] << 8);
        if (count != expectedCount)
            throw new IOException($"FPGA returned {count} results, expected {expectedCount}.");

        byte[] data = new byte[count * 12];
        ReadExactly(data, data.Length);

        Vector3[] accum = new Vector3[count];
        for (int i = 0; i < count; i++)
        {
            accum[i] = new Vector3(ReadFloatLE(data, i * 12), ReadFloatLE(data, i * 12 + 4), ReadFloatLE(data, i * 12 + 8));
        }
        return accum;
    }

    private static float ReadFloatLE(byte[] b, int o)
    {
        uint u = (uint)(b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24));
        return FpgaReference.FromBits(u);
    }

    private void OnDestroy()
    {
        Disconnect();
    }
}