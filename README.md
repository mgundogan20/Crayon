# Crayon ray tracer and FPGA prototype

This repository contains the Unity project at its root. Open this folder in
Unity Hub and run `Assets/Scenes/SampleScene.unity`. The project currently
renders with the serial CPU ray tracer by default.

## Ray tracer

| Topic | Code |
| --- | --- |
| CPU rendering, bounce/reflection and image output | [`FakePGA.cs`](Assets/Scripts/FakePGA.cs) |
| Mesh extraction and triangle representation (`V0`, `E1`, `E2`) | [`RTCore_mesh.cs`](Assets/Scripts/RTCore_mesh.cs) |
| Scene upload and ray-batch UART API | [`FpgaRayTriangleApi.cs`](Assets/Scripts/FpgaRayTriangleApi.cs) |
| Deterministic Q16.16 CPU reference | [`RayTraceBatch.cs`](Assets/Scripts/RayTraceBatch.cs) |

`FakePGA` is the current software renderer/emulator; it is not an FPGA and
"PGA" is not the hardware acronym. FPGA means *field-programmable gate array*.
The FPGA implementation below is an optional first hardware target, disabled
by default.

## Optional FPGA path

Enable **Use FPGA (UART)** in the Game view or set **Use FPGA** on the
`FakePGA` component before Play. Set the COM port, baud rate, and response
timeout in the Inspector. This checkbox selects the FPGA scene/batch API.
`FakePGA` uploads the scene once (and again only when its fixed-point data
changes), then submits each bounce's rays and receives the nearest hit for
each ray. If the port cannot be opened, or a request fails, Unity reports the
error and uses its CPU ray tracer instead. The serial transport currently
uses the Windows UART/COM API.
Enable **Use Cpu Golden Reference** on the same component to render through
the deterministic fixed-point software reference without connecting hardware.
Enable **Compare FPGA With Cpu Reference** to run both paths on the same ray
batches and log mismatch counts. `FakePGA.LastBatchResults` and
`FakePGA.LastGoldenResults` expose the most recent result arrays for probing.

The FPGA owns the scene triangles and performs nearest-hit selection. Triangle
materials are uploaded with geometry; the CPU still handles shading,
reflection, random direction perturbation, and image output. The public CPU
reference in `RayTraceBatch.TraceCpuReference` uses the same fixed-point
intersection arithmetic as the RTL and returns one nearest triangle index and
distance per ray. This makes it suitable for deterministic RTL comparison.
The normal CPU renderer remains the floating-point implementation.

The current UART protocol uploads a scene once, then sends a complete ray
batch. The RTL buffers those rays, traverses the resident scene for each one,
and streams the results back in order. This avoids retransmitting triangle
data and avoids a host round trip per ray. The endpoint currently supports up
to 256 triangles and 256 rays per batch. Results consume ten UART bytes per
ray, so at 115200 baud the output link alone takes about 278 seconds for an
800x400 frame (before bounces or protocol overhead). UART transactions are
synchronous on Unity's main thread, so a missing/stalled FPGA can pause the
game until the configured timeout.

### RTL partition and data flow

The RTL is split into transport, protocol/control, scene/batch processing,
the intersection pipeline, and reusable Q16.16 arithmetic. The hierarchy is:

```text
rt_uart_endpoint
|-- scene_trace_engine              records -> ordered nearest-hit results
|   |-- ray_triangle_pipeline       one ray/triangle intersection at a time
|   |   |-- q16_cross3 / q16_sub3   vector operations
|   |   |-- q16_dot3                dot products
|   |   |   `-- q16_mul             Q16.16 scalar multiply
|   |   `-- q16_div                 final Q16.16 distance division
|   `-- scene and ray memories      retain uploaded triangles and batch rays
`-- protocol/
    |-- uart_rx / uart_tx           serial byte transport
    |-- rt_request_decoder          UART bytes -> CRC-checked scene/ray records
    |-- rt_response_sender          CRCs, result buffering, ordered UART bytes
    `-- crc16_ccitt_byte            shared CRC-16/CCITT-FALSE byte update
```

`rt_uart_endpoint` is a small wiring top that connects UART, request decoding,
scene tracing, and response generation. `rt_request_decoder` owns command
header and record parsing, CRC checks, and scene/ray write handshakes.
`rt_response_sender` builds acknowledgements and result CRCs, buffers the
batch results, and transmits them in order. `crc16_ccitt_byte` is shared by
request validation and response generation. Serial framing stays separate
from the geometry engine.

#### One scene upload and batch trace, end to end

1. `uart_rx` converts serial bits into bytes. The request decoder waits for
   sync `0xA5`, reads the command/count/header CRC, and rejects invalid headers.
2. For scene upload (`0x10`), it clears the old scene, collects each 60-byte
   triangle payload plus CRC, and emits a scene-write pulse only for a valid
   record. After the last record it signals upload completion.
3. For ray batch (`0x20`), it collects and checks each 24-byte ray payload,
   writing valid rays into indexed engine memory. Once the full batch is
   buffered, it pulses `batch_start`.
4. `scene_trace_engine` visits each buffered ray and every uploaded triangle.
   The intersection pipeline calculates candidates; the engine retains the
   nearest positive hit and presents one result through ready/valid.
5. `rt_response_sender` encodes each result, calculates its CRC, and stores
   the ten-byte response. After all rays are traced, it streams the buffered
   responses in input order through `uart_tx`.

The UART receiver's overrun or framing-error pulses reset the request decoder
so it does not continue parsing a corrupted byte stream. Invalid scene-record
CRCs clear the partially uploaded scene; invalid ray records abort the batch
without starting the trace engine.

The UART byte transport is based on Alex Forencich's MIT-licensed
[verilog-uart](https://github.com/alexforencich/verilog-uart); its license is
included in [`THIRD_PARTY_LICENSES.txt`](Verilog/THIRD_PARTY_LICENSES.txt).
The original repository is deprecated, but its MIT-licensed RTL is a small,
self-contained 8-bit UART implementation. The endpoint adapts its baud
prescale and valid/ready byte interfaces.

`scene_trace_engine` owns the scene and ray memories and runs a batch. For
each ray it walks the resident triangles, submits ray/triangle pairs to the
intersection pipeline, and retains the nearest positive hit. Its result uses
a ready/valid handshake and remains stable until accepted. It does not know
about UART bytes or CRC framing, which makes the trace engine and protocol
controller independently testable.

`ray_triangle_pipeline` is a four-stage ready/valid Möller–Trumbore
intersection datapath. The arithmetic modules in `Verilog/arithmetic/` are
combinational building blocks: `q16_mul` truncates a signed product to Q16.16,
`q16_dot3` combines three products, `q16_cross3` forms a vector cross product,
`q16_sub3` subtracts packed XYZ vectors, and `q16_div` computes the final
distance. Packed vectors use `{z, y, x}` (x in bits 31:0).

| Module/file | Responsibility |
| --- | --- |
| [`rt_uart_endpoint.v`](Verilog/rt_uart_endpoint.v) | Top-level wiring between UART, protocol, and trace engine. |
| [`uart_rx.v`](Verilog/protocol/uart_rx.v) | 8-N-1 UART byte receiver. |
| [`uart_tx.v`](Verilog/protocol/uart_tx.v) | 8-N-1 UART byte transmitter. |
| [`rt_request_decoder.v`](Verilog/protocol/rt_request_decoder.v) | Header and record parser; emits only CRC-checked records. |
| [`rt_response_sender.v`](Verilog/protocol/rt_response_sender.v) | Response CRC, batch result buffering, and ordered UART byte sender. |
| [`crc16_ccitt_byte.v`](Verilog/protocol/crc16_ccitt_byte.v) | Shared one-byte CRC-16/CCITT-FALSE update block. |
| [`scene_trace_engine.v`](Verilog/scene_trace_engine.v) | Scene/ray storage, sequential triangle traversal, nearest-hit selection, result handshake. |
| [`ray_triangle_pipeline.v`](Verilog/ray_triangle_pipeline.v) | Four-stage ray/triangle fixed-point intersection datapath. |
| [`q16_mul.v`](Verilog/arithmetic/q16_mul.v) | Signed scalar Q16.16 multiply. |
| [`q16_dot3.v`](Verilog/arithmetic/q16_dot3.v) | Three-component dot product built from `q16_mul`. |
| [`q16_cross3.v`](Verilog/arithmetic/q16_cross3.v) | Three-component cross product built from `q16_mul`. |
| [`q16_sub3.v`](Verilog/arithmetic/q16_sub3.v) | Three-component vector subtraction. |
| [`q16_div.v`](Verilog/arithmetic/q16_div.v) | Signed Q16.16 division for the hit distance. |
| [`tb_ray_triangle_pipeline.v`](Verilog/tb_ray_triangle_pipeline.v) | Directed intersection cases (hit, outside, parallel, behind ray). |
| [`tb_rt_uart_endpoint.v`](Verilog/tb_rt_uart_endpoint.v) | End-to-end UART test for scene upload, ray batch, nearest hit, and CRC. |

[BaseJump STL](https://github.com/bespoke-silicon-group/basejump_stl) is a
valuable SystemVerilog component library, but this design does not currently
depend on it. Its repository uses the
[Solderpad Hardware License 0.51](https://github.com/bespoke-silicon-group/basejump_stl/blob/master/LICENSE),
and its general-purpose primitives do not replace the scene-specific
fixed-point datapath or this protocol's UART/CRC boundary. Keeping the current
arithmetic local avoids a broad dependency and preserves the exact Q16.16
behavior used by the CPU reference.

The UART endpoint's `CLKS_PER_BIT` defaults to 434, for a 50 MHz clock and
115200 baud. Set it to the rounded ratio `clock_frequency / baud_rate` for the
board's clock and chosen baud rate. The board top level must connect the clock,
active-high reset, RX pin, and TX pin.

### UART protocol

Frames use 8-N-1 UART bytes. Multi-byte integers are little-endian. CRC is
CRC-16/CCITT-FALSE (polynomial `0x1021`, initial value `0xFFFF`, no reflection,
no final XOR), transmitted low byte first. The four-byte command header is
`0xA5`, command, item count low byte, item count high byte, followed by its
two-byte CRC.

**Scene upload (command `0x10`):**

| Bytes | Meaning |
| --- | --- |
| Header count | Number of triangles, 0-256 |
| Each 62-byte record | Fifteen signed Q16.16 values: `V0`, `E1`, `E2`, diffuse RGB, emission RGB; then CRC over the 60 data bytes |
| Response | `0x5A`, status (0 success), CRC over those two bytes |

**Ray batch (command `0x20`):**

| Bytes | Meaning |
| --- | --- |
| Header count | Number of rays, 0-256 |
| Each 26-byte record | Ray origin XYZ and direction XYZ as signed Q16.16; then CRC over the 24 data bytes |
| Ray records | Send all 26-byte records in the batch before reading results |
| Response per ray | `0x5A`, status (0 miss, 1 hit), triangle index u16, signed Q16.16 distance, CRC over the first eight response bytes (10 bytes total); responses are streamed in ray order |

Q16.16 represents signed values from -32768 to just under 32768. The C# side
rounds input values to the nearest fixed-point value (midpoints away from zero).
RTL products shift right by 16 bits, intermediate vector results wrap to 32
bits, and division truncates toward zero. The RTL uses a zero-determinant test
instead of the CPU's floating-point epsilon. Consequently, the current FPGA
path is a fixed-point approximation, not a bit-identical replacement for
Unity's floating-point CPU implementation. Keep the CPU implementation as the
visual fallback; use a fixed-point software reference and the Verilog
testbench for arithmetic-equivalence work.

### RTL verification

Install Icarus Verilog and Verilator through MSYS2, then open an **MSYS2
UCRT64** terminal at the repository root. Icarus compiles the Verilog and
executes the testbench with `vvp`; each testbench checks its own expected
results and prints `PASS` or calls `$fatal` on a mismatch.

```sh
iverilog -g2012 -s tb_ray_triangle_pipeline -o ray_triangle_test \
  Verilog/arithmetic/*.v Verilog/ray_triangle_pipeline.v \
  Verilog/tb_ray_triangle_pipeline.v
vvp ray_triangle_test

iverilog -g2012 -s tb_rt_uart_endpoint -o rt_uart_endpoint_test \
  Verilog/arithmetic/*.v Verilog/protocol/*.v \
  Verilog/ray_triangle_pipeline.v Verilog/scene_trace_engine.v \
  Verilog/rt_uart_endpoint.v \
  Verilog/tb_rt_uart_endpoint.v
vvp rt_uart_endpoint_test
```

Verilator is a fast Verilog/SystemVerilog elaborator and lint tool. Here,
`--lint-only` checks the synthesizable design for structural problems and
warnings; it does **not** execute these testbenches or replace Icarus
simulation. Run lint from the same MSYS2 terminal:

```sh
verilator --lint-only --timing -Wall -Wno-PINCONNECTEMPTY \
  --top-module rt_uart_endpoint \
  Verilog/arithmetic/*.v Verilog/protocol/*.v \
  Verilog/ray_triangle_pipeline.v Verilog/scene_trace_engine.v \
  Verilog/rt_uart_endpoint.v
```

The endpoint and UART modules are synthesizable RTL. The lint command
suppresses only `PINCONNECTEMPTY` for the UART's intentionally unused busy
status output. Icarus tests exercise both arithmetic corner cases and a full
UART scene-upload/ray-batch round trip; Verilator lint adds a separate early
check before synthesis or board integration.

## Current CPU limitations

The CPU renderer traces every ray against every triangle and renders three
bounces per frame. It has no BVH or other acceleration structure, and rendering
is repeated from `Update`. Its geometry path is still a software prototype,
not a production renderer. The FPGA path does not currently change those
costs; its purpose is to establish a simple UART and arithmetic contract that
can be verified and improved in measured stages.
