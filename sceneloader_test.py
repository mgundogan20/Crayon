"""Smoke test for uart_parser: loads an arbitrary scene over UART, then
fetches every record back and checks the bytes round-trip unchanged.

Run on the Windows machine with the board attached as COM5. The board must
already be programmed and out of reset (press the reset button) before
running this script.
"""

import struct
import sys

import serial

PORT = "COM5"
BAUD = 3_000_000

SYNC = 0xA5
CMD_LOAD = 0x5A
CMD_FETCH_BVH = 0x5B
CMD_FETCH_TRI = 0x5C
CMD_FETCH_MAT = 0x5D

NODE_ADDR_BYTES = 2
TRI_ADDR_BYTES = 2
MAT_ADDR_BYTES = 1

# int32 left, right, id, morton; float3 center; float3 size
NODE_FMT = "<4i6f"
# int32 material_id; float3 V0, E1, E2, N1, N2, N3
TRI_FMT = "<i18f"
# uint8 smoothness; float3 emission; float3 absorption
MAT_FMT = "<B6f"

NODE_BYTES = struct.calcsize(NODE_FMT)
TRI_BYTES = struct.calcsize(TRI_FMT)
MAT_BYTES = struct.calcsize(MAT_FMT)

assert NODE_BYTES == 40, NODE_BYTES
assert TRI_BYTES == 76, TRI_BYTES
assert MAT_BYTES == 25, MAT_BYTES


def build_scene():
    nodes = [
        struct.pack(NODE_FMT, 10 * i, 10 * i + 1, i, 999 * i,
                     1.0 * i, 2.0 * i, 3.0 * i,
                     1.0, 1.0, 1.0)
        for i in range(2)
    ]
    tris = [
        struct.pack(TRI_FMT, i,
                     1.0 * i, 2.0 * i, 3.0 * i,   # V0
                     4.0 * i, 5.0 * i, 6.0 * i,   # E1
                     7.0 * i, 8.0 * i, 9.0 * i,   # E2
                     0.0, 0.0, 1.0,               # N1
                     0.0, 1.0, 0.0,               # N2
                     1.0, 0.0, 0.0)               # N3
        for i in range(2)
    ]
    mats = [
        struct.pack(MAT_FMT, i,
                     1.0 * i, 1.0 * i, 1.0 * i,   # emission
                     2.0 * i, 2.0 * i, 2.0 * i)   # absorption
        for i in range(2)
    ]
    return nodes, tris, mats


def send_load(ser, nodes, tris, mats):
    payload = bytearray()
    payload += bytes([SYNC, CMD_LOAD])
    payload += struct.pack("<H", len(nodes))
    payload += struct.pack("<H", len(tris))
    payload += struct.pack("<B", len(mats))
    for rec in nodes:
        payload += rec
    for rec in tris:
        payload += rec
    for rec in mats:
        payload += rec
    ser.write(bytes(payload))


def fetch_record(ser, cmd, address, addr_bytes, record_len):
    addr_fmt = {1: "<B", 2: "<H"}[addr_bytes]
    request = bytes([SYNC, cmd]) + struct.pack(addr_fmt, address)
    ser.write(request)
    return ser.read(record_len)


def check(label, sent, received):
    if received == sent:
        print(f"{label}: OK")
        return True
    print(f"{label}: MISMATCH (sent {len(sent)}B, got {len(received)}B)")
    print(f"  sent:     {sent.hex()}")
    print(f"  received: {received.hex()}")
    return False


def main():
    nodes, tris, mats = build_scene()

    with serial.Serial(PORT, BAUD, timeout=2) as ser:
        send_load(ser, nodes, tris, mats)

        results = []
        for i, rec in enumerate(nodes):
            got = fetch_record(ser, CMD_FETCH_BVH, i, NODE_ADDR_BYTES, NODE_BYTES)
            results.append(check(f"node[{i}]", rec, got))
        for i, rec in enumerate(tris):
            got = fetch_record(ser, CMD_FETCH_TRI, i, TRI_ADDR_BYTES, TRI_BYTES)
            results.append(check(f"tri[{i}]", rec, got))
        for i, rec in enumerate(mats):
            got = fetch_record(ser, CMD_FETCH_MAT, i, MAT_ADDR_BYTES, MAT_BYTES)
            results.append(check(f"mat[{i}]", rec, got))

    passed = sum(results)
    total = len(results)
    print(f"\n{passed}/{total} records matched")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
