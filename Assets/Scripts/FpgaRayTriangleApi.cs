using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.ComponentModel;
using UnityEngine;

public sealed class FpgaRayTriangleApi : IDisposable
{
    private const byte RequestSync = 0xA5;
    private const byte UploadSceneCommand = 0x10;
    private const byte TraceBatchCommand = 0x20;
    private const byte ResponseSync = 0x5A;
    private const int TriangleRecordLength = 62;
    private const int RayRecordLength = 26;
    private const int ResponseLength = 10;
    private const float FixedPointScale = RayTraceBatch.FixedPointScale;

    private readonly Stream stream;
    private readonly object streamLock = new object();
    private byte[] uploadedScene;

    public FpgaRayTriangleApi(string portName, int baudRate, int timeoutMilliseconds)
    {
        stream = WindowsSerialStream.Open(portName, baudRate, timeoutMilliseconds);
    }

    public void UploadScene(IReadOnlyList<RayTraceTriangle> triangles)
    {
        if (triangles == null)
            throw new ArgumentNullException(nameof(triangles));
        if (triangles.Count > RayTraceBatch.MaxTriangles)
            throw new ArgumentOutOfRangeException(nameof(triangles), "The current FPGA scene limit is 256 triangles.");

        lock (streamLock)
        {
            byte[] sceneData = new byte[triangles.Count * 60];
            byte[] sceneRecords = new byte[triangles.Count * TriangleRecordLength];
            for (int i = 0; i < triangles.Count; i++)
            {
                int offset = i * 60;
                RayTraceTriangle triangle = triangles[i];
                WriteVector(sceneData, offset, triangle.v0);
                WriteVector(sceneData, offset + 12, triangle.e1);
                WriteVector(sceneData, offset + 24, triangle.e2);
                WriteVector(sceneData, offset + 36, triangle.diffuseColor);
                WriteVector(sceneData, offset + 48, triangle.emissionColor);

                int recordOffset = i * TriangleRecordLength;
                Array.Copy(sceneData, offset, sceneRecords, recordOffset, 60);
                WriteCrc(sceneRecords, recordOffset, 60);
            }

            if (uploadedScene != null && ByteArraysEqual(uploadedScene, sceneData))
                return;

            byte[] header = { RequestSync, UploadSceneCommand, 0, 0, 0, 0 };
            header[2] = (byte)triangles.Count;
            header[3] = (byte)(triangles.Count >> 8);
            WriteCrc(header, 4);
            stream.Write(header, 0, header.Length);
            stream.Write(sceneRecords, 0, sceneRecords.Length);
            stream.Flush();
            ReadAcknowledgement();
            uploadedScene = sceneData;
        }
    }

    public RayTraceHit[] TraceBatch(IReadOnlyList<RayTraceRay> rays)
    {
        if (rays == null)
            throw new ArgumentNullException(nameof(rays));
        if (uploadedScene == null)
            throw new InvalidOperationException("Upload a scene before tracing a ray batch.");
        if (rays.Count > RayTraceBatch.MaxRays)
            throw new ArgumentOutOfRangeException(nameof(rays), "The current FPGA ray-batch limit is 256 rays.");

        RayTraceHit[] results = new RayTraceHit[rays.Count];
        byte[] rayRecords = new byte[rays.Count * RayRecordLength];
        for (int i = 0; i < rays.Count; i++)
        {
            int recordOffset = i * RayRecordLength;
            WriteVector(rayRecords, recordOffset, rays[i].origin);
            WriteVector(rayRecords, recordOffset + 12, rays[i].direction);
            WriteCrc(rayRecords, recordOffset, 24);
        }

        lock (streamLock)
        {
            byte[] header = { RequestSync, TraceBatchCommand, 0, 0, 0, 0 };
            header[2] = (byte)rays.Count;
            header[3] = (byte)(rays.Count >> 8);
            WriteCrc(header, 4);
            stream.Write(header, 0, header.Length);
            stream.Write(rayRecords, 0, rayRecords.Length);
            stream.Flush();

            for (int i = 0; i < rays.Count; i++)
            {
                byte[] response = new byte[ResponseLength];
                ReadExactly(stream, response);
                if (response[0] != ResponseSync ||
                    response[1] > 1 ||
                ReadUInt16(response, 8) != CalculateCrc(response, 0, 8))
                {
                    throw new InvalidDataException("The FPGA returned an invalid ray-batch result.");
                }

                int triangleIndex = response[1] == 1 ? ReadUInt16(response, 2) : -1;
                if (triangleIndex >= uploadedScene.Length / 60)
                    throw new InvalidDataException("The FPGA returned a triangle index outside the uploaded scene.");

                results[i] = new RayTraceHit
                {
                    hit = response[1] == 1,
                    triangleIndex = triangleIndex,
                    distanceQ16 = response[1] == 1 ? ReadInt32(response, 4) : 0
                };
            }
        }

        return results;
    }

    private void ReadAcknowledgement()
    {
        byte[] response = new byte[4];
        ReadExactly(stream, response);
        if (response[0] != ResponseSync ||
            response[1] != 0 ||
            ReadUInt16(response, 2) != CalculateCrc(response, 0, 2))
        {
            throw new InvalidDataException("The FPGA rejected the uploaded scene.");
        }
    }

    private static bool ByteArraysEqual(byte[] left, byte[] right)
    {
        if (left.Length != right.Length)
            return false;
        for (int i = 0; i < left.Length; i++)
        {
            if (left[i] != right[i])
                return false;
        }
        return true;
    }

    public void Dispose()
    {
        stream.Dispose();
    }

    private static void WriteVector(byte[] destination, int offset, Vector3 value)
    {
        WriteInt32(destination, offset, ToFixedPoint(value.x));
        WriteInt32(destination, offset + 4, ToFixedPoint(value.y));
        WriteInt32(destination, offset + 8, ToFixedPoint(value.z));
    }

    private static int ToFixedPoint(float value)
    {
        if (float.IsNaN(value) || float.IsInfinity(value))
        {
            throw new ArgumentOutOfRangeException(nameof(value), "Coordinates must be finite.");
        }

        double scaled = Math.Round(value * (double)FixedPointScale, MidpointRounding.AwayFromZero);
        if (scaled > int.MaxValue || scaled < int.MinValue)
        {
            throw new ArgumentOutOfRangeException(nameof(value), "A coordinate is outside the signed Q16.16 range.");
        }

        return (int)scaled;
    }

    private static void WriteInt32(byte[] destination, int offset, int value)
    {
        uint bits = unchecked((uint)value);
        destination[offset] = (byte)bits;
        destination[offset + 1] = (byte)(bits >> 8);
        destination[offset + 2] = (byte)(bits >> 16);
        destination[offset + 3] = (byte)(bits >> 24);
    }

    private static int ReadInt32(byte[] source, int offset)
    {
        uint bits = (uint)source[offset]
            | ((uint)source[offset + 1] << 8)
            | ((uint)source[offset + 2] << 16)
            | ((uint)source[offset + 3] << 24);
        return unchecked((int)bits);
    }

    private static ushort ReadUInt16(byte[] source, int offset)
    {
        return (ushort)(source[offset] | (source[offset + 1] << 8));
    }

    private static void WriteCrc(byte[] frame, int crcOffset)
    {
        WriteCrc(frame, 0, crcOffset);
    }

    private static void WriteCrc(byte[] frame, int dataOffset, int dataLength)
    {
        int crcOffset = dataOffset + dataLength;
        ushort crc = CalculateCrc(frame, dataOffset, dataLength);
        frame[crcOffset] = (byte)crc;
        frame[crcOffset + 1] = (byte)(crc >> 8);
    }

    private static ushort CalculateCrc(byte[] data, int offset, int count)
    {
        ushort crc = 0xFFFF;
        for (int i = offset; i < offset + count; i++)
        {
            crc ^= (ushort)(data[i] << 8);
            for (int bit = 0; bit < 8; bit++)
            {
                crc = (crc & 0x8000) != 0
                    ? (ushort)((crc << 1) ^ 0x1021)
                    : (ushort)(crc << 1);
            }
        }

        return crc;
    }

    private static void ReadExactly(Stream source, byte[] destination)
    {
        int offset = 0;
        while (offset < destination.Length)
        {
            int count = source.Read(destination, offset, destination.Length - offset);
            if (count == 0)
            {
                throw new TimeoutException("Timed out waiting for an FPGA response.");
            }

            offset += count;
        }
    }

    private sealed class WindowsSerialStream : Stream
    {
        private readonly FileStream fileStream;

        private WindowsSerialStream(FileStream fileStream)
        {
            this.fileStream = fileStream;
        }

        public static WindowsSerialStream Open(string portName, int baudRate, int timeoutMilliseconds)
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                throw new PlatformNotSupportedException("The built-in UART transport currently supports Windows only.");
            }
            if (string.IsNullOrWhiteSpace(portName))
            {
                throw new ArgumentException("A serial port name is required.", nameof(portName));
            }
            if (baudRate <= 0 || timeoutMilliseconds <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(baudRate), "Baud rate and timeout must be positive.");
            }

            string devicePath = portName.StartsWith(@"\\.\", StringComparison.Ordinal)
                ? portName
                : @"\\.\" + portName;
            SafeFileHandle handle = CreateFile(
                devicePath,
                GenericRead | GenericWrite,
                0,
                IntPtr.Zero,
                OpenExisting,
                0,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Could not open UART port " + portName + ".");
            }

            try
            {
                Dcb dcb = new Dcb { Length = (uint)Marshal.SizeOf(typeof(Dcb)) };
                if (!GetCommState(handle, ref dcb))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read UART settings.");
                }

                dcb.BaudRate = (uint)baudRate;
                dcb.Flags = 1;
                dcb.ByteSize = 8;
                dcb.Parity = 0;
                dcb.StopBits = 0;
                if (!SetCommState(handle, ref dcb))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not configure UART as 8-N-1.");
                }

                CommTimeouts timeouts = new CommTimeouts
                {
                    ReadIntervalTimeout = uint.MaxValue,
                    ReadTotalTimeoutConstant = (uint)timeoutMilliseconds,
                    WriteTotalTimeoutConstant = (uint)timeoutMilliseconds
                };
                if (!SetCommTimeouts(handle, ref timeouts))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not configure UART timeouts.");
                }

                if (!PurgeComm(handle, PurgeRxClear | PurgeTxClear))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not clear UART buffers.");
                }

                return new WindowsSerialStream(new FileStream(handle, FileAccess.ReadWrite, 1, false));
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public override bool CanRead { get { return fileStream.CanRead; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return fileStream.CanWrite; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position
        {
            get { throw new NotSupportedException(); }
            set { throw new NotSupportedException(); }
        }

        public override void Flush() { fileStream.Flush(); }
        public override int Read(byte[] buffer, int offset, int count) { return fileStream.Read(buffer, offset, count); }
        public override void Write(byte[] buffer, int offset, int count) { fileStream.Write(buffer, offset, count); }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                fileStream.Dispose();
            }
            base.Dispose(disposing);
        }

        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint OpenExisting = 3;
        private const uint PurgeRxClear = 0x0008;
        private const uint PurgeTxClear = 0x0004;

        [StructLayout(LayoutKind.Sequential)]
        private struct Dcb
        {
            public uint Length;
            public uint BaudRate;
            public uint Flags;
            public ushort Reserved;
            public ushort XonLimit;
            public ushort XoffLimit;
            public byte ByteSize;
            public byte Parity;
            public byte StopBits;
            public sbyte XonChar;
            public sbyte XoffChar;
            public sbyte ErrorChar;
            public sbyte EofChar;
            public sbyte EventChar;
            public ushort Reserved1;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CommTimeouts
        {
            public uint ReadIntervalTimeout;
            public uint ReadTotalTimeoutMultiplier;
            public uint ReadTotalTimeoutConstant;
            public uint WriteTotalTimeoutMultiplier;
            public uint WriteTotalTimeoutConstant;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetCommState(SafeFileHandle file, ref Dcb dcb);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetCommState(SafeFileHandle file, ref Dcb dcb);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetCommTimeouts(SafeFileHandle file, ref CommTimeouts timeouts);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool PurgeComm(SafeFileHandle file, uint flags);
    }
}
