# Asynchronous Router Design & Verification

A parameterizable 1-input / 3-output packet router (Verilog RTL), verified with a
self-checking, layered SystemVerilog testbench — scoreboard, functional coverage,
mailboxes, and a driver/monitor/generator architecture. **266/266 data checks and
40/40 error-flag checks passing, 100% signal coverage, 96.67% transaction
coverage.**

## Overview

The router accepts a serial stream of packets on a single input channel and routes
each packet to one of three output FIFOs based on a 2-bit destination address
encoded in the packet header. Each packet is parity-checked in hardware, with a
live `err` flag raised on mismatch.

**Packet format:**

| Byte           | Contents                                                        |
|----------------|-------------------------------------------------------------------|
| 0 (header)     | `[7:2]` = payload length, `[1:0]` = destination address (0/1/2)  |
| 1..N           | Payload data bytes (`packet_valid = 1`)                          |
| N+1 (trailer)  | Parity = header ^ payload[0] ^ ... ^ payload[N-1] (`packet_valid = 0`, marks end of packet) |

## RTL Architecture

| File            | Description                                                              |
|------------------|---------------------------------------------------------------------------|
| `router_top.v`   | Top-level module; instantiates 3x FIFO, the register/datapath, FSM, and sync/write-enable logic |
| `router_fsm.v`   | Main control FSM: header decode → load-first-data → load-data → parity check, with a stall path for a full/busy destination |
| `router_reg.v`   | Datapath register: header hold, payload pass-through, running XOR parity computation, error flag |
| `router_fifo.v`  | 16-deep, 9-bit-wide (8 data + 1 header-tag) synchronous FIFO used per output port |
| `router_sync.v`  | Per-port write-enable decode, `fifo_full` mux, valid-out generation, soft-reset watchdogs |

## Testbench Architecture

`router_tb.sv` is a single-file, layered SystemVerilog testbench (interface +
classes + top), written to run on any full SystemVerilog simulator (verified on
Cadence Xcelium via EDA Playground).

```
generator → [mailbox] → driver → DUT → monitor → [mailbox] → scoreboard
                            │                                     ▲
                            └────────────[mailbox]─────────────────┘
                                  (expected-data / expected-err)
                          read_agent (independent random reader, all 3 ports)
                          coverage   (sampled per-transaction + per-clock)
```

- **`transaction`** — randomized packet: destination address, payload length,
  payload bytes, computed parity, and a ~15% weighted `inject_err` fault for
  negative testing.
- **`generator`** — produces N randomized transactions onto a mailbox.
- **`driver`** — drives the packet-valid/datain protocol, including a required
  one-cycle bubble after the header (matching the DUT's internal
  `load_first_data` state) and a wait for the destination port to be fully
  drained before starting a new packet to it (the DUT does not queue a new
  packet behind an unread one).
- **`read_agent`** — independently, randomly toggles all three `read_enb_x`
  lines to drain the output FIFOs concurrently with driving.
- **`monitor`** — pipelines its sampling by one cycle to match the FIFO's
  registered read latency, and captures data from all three output ports.
- **`scoreboard`** — reconstructs the expected byte stream (header + payload +
  parity) per port and compares it against what the monitor observed; checks
  the `err` flag against the intentionally-injected fault expectation.
- **`coverage`** — a transaction-level covergroup (address × length × injected
  error, with cross bins) and a per-clock signal covergroup (`busy`, `err`,
  `vldout_0/1/2`).

## Running the Testbench

### EDA Playground
1. Paste the 5 RTL files into the **Design** panel.
2. Paste `router_tb.sv` into the **Testbench** panel.
3. Select a full SystemVerilog simulator (e.g. Cadence Xcelium).
4. Top module: `tb_top`.
5. To see functional coverage numbers (not just pass/fail), add to the
   **Tools & Simulators → Run options** field:
   ```
   -coverage functional -covoverwrite
   ```

### Sample result
```
========================================================
SCOREBOARD REPORT
  Data  matches   : 266
  Data  mismatches: 0
  Err   matches   : 40
  Err   mismatches: 0
  RESULT: PASS
========================================================
[COVERAGE] Transaction coverage : 96.67 %
[COVERAGE] Signal      coverage : 100.00 %
```

## Bugs Found & Fixed During Verification

Verification surfaced one real RTL defect and two testbench/protocol-timing
issues along the way — a useful log of how the design and its regression
converged:

1. **RTL bug — `router_fifo.v` read logic (fixed).** The FIFO's "COMPLETELY
   READ" high-Z condition was written as a second, independent `if` rather
   than an `else if`, alongside the live-read assignment:
   ```verilog
   // before (buggy): both can fire the same cycle, second wins
   if (read_enb && !empty) dataout <= fifo[read_ptr];
   if (count == 0)          dataout <= 8'bz;

   // after (fixed):
   if (read_enb && !empty)      dataout <= fifo[read_ptr];
   else if (count == 0)         dataout <= 8'bz;
   ```
   `count` is still `0` on the exact cycle a fresh packet's header is read (it
   only becomes non-zero as a *result* of that read), so both conditions were
   true simultaneously and the header byte was silently overwritten with
   `8'bz` on every packet.

2. **Driver protocol timing (testbench).** The DUT spends one clock cycle in
   an internal `load_first_data` "bubble" state right after the header,
   before it is ready to consume the first payload byte. The original driver
   advanced straight from header to payload with no bubble, so the first
   payload byte was silently dropped every time.

3. **Missing per-port flow control (testbench).** The DUT only accepts a new
   packet for a given output port once that port's FIFO has been fully
   drained; if a new packet arrives while the previous one is still unread,
   the FSM silently stalls (`wait_till_empty`) and drops whatever the driver
   presents during the stall. The driver now waits for the destination port's
   `vldout_x` to go low before starting a new packet to that port.

## Repository Structure

```
.
├── router_top.v         # top-level module
├── router_fifo.v         # per-port FIFO (fixed)
├── router_fsm.v          # control FSM
├── router_reg.v          # datapath / parity logic
├── router_sync.v         # write-enable / sync logic
├── router_tb.sv           # layered SystemVerilog testbench
└── README.md
```

## Requirements

A SystemVerilog simulator with class, mailbox, and covergroup support
(e.g. Cadence Xcelium, Synopsys VCS, Siemens Questa). Not compatible with
Icarus Verilog / iverilog (no SV class/mailbox support).
