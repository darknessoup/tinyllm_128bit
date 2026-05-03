# TinyLLM FPGA Matrix Multiplication Accelerator

## Quick Start

This folder contains the hardware design and test infrastructure for a 16-parallel MAC (Multiply-Accumulate) FPGA accelerator for tiny LLM inference on Xilinx Zynq platforms.

### Project Structure

```
tinyllm_128bit/
├── DESIGN_DOCUMENTATION.md    # Comprehensive architecture documentation
├── README.md                  # This file
│
├── VHDL Hardware Files:
│   ├── matmul_v1.vhd         # Top-level module (matmul_v1_0)
│   ├── matmul_manager.vhd    # MAC engine & state machine (16 parallel DSPs)
│   ├── mac.vhd               # Single 8×8 MAC DSP unit
│   ├── axi_interface.vhd     # AXI4-Lite slave (vec_len register)
│
├── Test Benches (VHDL):
│   ├── TestBench.vhd          # Comprehensive multi-phase inference test
│   ├── TestBench_timing.vhd   # Single-cycle deterministic test (golden: 0x78)
│   └── test_bench_current     # Alternative 32-bit stream variant (legacy)
│
├── Python Integration:
│   ├── matmul.py              # Driver class (MatmulIP, StreamMatmulDriver)
│   ├── matmul_test.py         # Unit tests & golden reference model
│   ├── llm.py                 # End-to-end inference (uses PL acceleration)
│   └── lllm-proj-matmul.py    # Alternative LLM integration script
```

---

## Hardware Overview

### Top-Level Interfaces

**AXI4-Lite Slave (32-bit)**
- Register @ offset 0x0: `vec_len` (vector length in elements)
- Controls how many 128-bit BRAM words to process per inference

**AXI4-Stream Slave (128-bit)**
- Input: 16 × 8-bit signed weights per beat
- Byte lanes [0..15] → DSP inputs [0..15]
- Handshake: `s00_axis_tvalid` / `s00_axis_tready`

**AXI4-Stream Master (64-bit)**
- Output: One 64-bit neuron accumulator result
- Asserted when: `m00_axis_tvalid = '1'`
- Ready signal: `m00_axis_tready` (downstream consumer)

**BRAM Interface (128-bit, 4096 deep)**
- Port A: Read-only (activations from ARM PS via CDMA)
- Port B: Write-only (CDMA loading new activation vectors)
- Address: 12-bit (4K locations)

---

## Running Tests in Vivado/ModelSim

### Test 1: Comprehensive Functional Test (TestBench.vhd)

**What it tests:**
- Multiple weight stream frames (64 beats each)
- Inter-phase BRAM updates via port B
- State machine transitions (idle → active → finishing → done)
- Sparse weight patterns

**To run:**
1. Open project in Vivado
2. Select `TestBench.vhd` as top module
3. Run behavioral simulation
4. Inspect waveforms:
   - `s00_axis_tready`: Should pulse high during active state
   - `m00_axis_tvalid`: Should assert once per frame
   - `m00_axis_tdata`: Check neuron outputs against expected values

**Duration:** ~10 µs simulation time

---

### Test 2: Deterministic Single-Cycle Test (TestBench_timing.vhd)

**What it tests:**
- Exact timing for one MAC operation
- Activations: bytes 0x00 through 0x0F
- Weights: all bytes = 0x01
- Expected result: MAC_sum = 0 + 1 + 2 + ... + 15 = **120 = 0x78**

**To run:**
1. Select `TestBench_timing.vhd` as top module
2. Run behavioral simulation
3. **Key check:** When `m00_axis_tvalid = '1'`, verify `m00_axis_tdata = 0x0000000000000078`

**Duration:** ~200 ns simulation time

**Waveform inspection points:**
- Cycle 0: Write vec_len = 16 via AXI4-Lite
- Cycle ~20: BRAM pre-fetch occurs, `addra = 0x000`
- Cycle ~30: `s00_axis_tdata` driven with weight beat (all 0x01)
- Cycle ~60+: Pipelined summation tree processes; `m00_axis_tvalid` asserts
- **Verify:** `m00_axis_tdata = 0x0000000000000078`

---

## Python Testing & Integration

### Running Unit Tests

```bash
cd tinyllm_128bit/
python matmul_test.py
```

**Expected output:**
```
======================================================================
TinyLLM Matmul Unit Test Suite
======================================================================

[PASS] Simple Unit Test (weights=1, activations=0..15)
      Expected: 120 (0x0000000000000078)
      Got:      120 (0x0000000000000078)

[PASS] All Zeros Test
[PASS] Alternating 1/-1 Pattern
[PASS] Maximum Positive (127*127*16)
[PASS] Maximum Negative (-128*-128*16)
[PASS] Mixed Sign Values
[PASS] Sparse Weight Pattern

======================================================================
Test Summary: 7 passed, 0 failed
======================================================================

======================================================================
Matrix-Vector Multiplication Test Suite
======================================================================

[PASS] Simple 2x4 Matrix-Vector
[PASS] Identity Matrix

======================================================================
Matvec Summary: 2 passed, 0 failed
======================================================================

======================================================================
OVERALL RESULTS: 9 passed, 0 failed
======================================================================
```

### Golden Model for Verification

The `matmul_test.py` file includes a golden reference model:

```python
from matmul_test import MatmulGoldenModel
import numpy as np

# Single MAC computation
weights = np.array([0x01] * 16, dtype=np.int8)
activations = np.arange(16, dtype=np.int8)
result = MatmulGoldenModel.parallel_mac_16lane(weights, activations)
print(f"Result: {result}")  # Expected: 120

# Matrix-vector product
W = np.random.randint(-128, 127, (64, 128), dtype=np.int8)
A = np.random.randint(-128, 127, (128,), dtype=np.int8)
output = MatmulGoldenModel.matmul_vector(W, A)
print(f"Output shape: {output.shape}")  # (64,)
```

### Using the Driver (matmul.py)

```python
from pynq import Overlay

# Load bitstream on Zynq
ol = Overlay("path/to/llm_project.bit")

# Instantiate driver
driver = ol.StreamMatmulDriver()

# Allocate buffers
activations = np.array([...], dtype=np.int8).shape = (1, 1, 128)
weights = np.array([...], dtype=np.int8).shape = (64, 128)
output = allocate((1, 64), dtype=np.int32)

# Perform matmul
result = driver.matmul(activations, weights, output, wait=True)
```

---

## Recent Updates (May 2026)

### Fixed Issues
- ✅ **AXI4-Lite Strobe Width:** Corrected `s00_axi_wstrb` from 15 downto 0 to 3 downto 0 in `TestBench.vhd`
- ✅ **Empty Test File:** Populated `matmul_test.py` with 9 unit tests + golden reference model
- ✅ **Documentation:** Created `DESIGN_DOCUMENTATION.md` with full architecture details

### Verified
- ✅ All 9 Python unit tests pass
- ✅ Test vectors cover positive, negative, zero, sparse, and boundary cases
- ✅ Matrix-vector test validates golden model accuracy

---

## Known Limitations & Future Work

### Current Limitations
1. **Fixed 128-bit Width:** Efficiently processes vectors as multiples of 128 bits (16 elements)
2. **No Saturation:** Results saturate at int64 bounds; no rounding modes configurable
3. **No Error Detection:** No parity or ECC on BRAM/accumulators

### Planned Enhancements
1. **Dual-stream Pipeline:** Queue multiple neurons for improved throughput
2. **Configurable Precision:** Add register bits for rounding/saturation control
3. **Debug Features:** Expose intermediate accumulator values via debug registers
4. **Extended Memory:** Support 16K/32K BRAM for larger batch processing

---

## File Dependencies

```
matmul_v1.vhd (top)
  ├── matmul_manager.vhd (MAC engine)
  │   ├── mac.vhd (x16 parallel instances)
  │   └── blk_mem_dp_128_1024 (BRAM component)
  └── axi_interface.vhd (AXI4-Lite slave)
      └── blk_mem_dp_128_1024 (BRAM component)

TestBench.vhd
  ├── matmul_v1.vhd
  └── blk_mem_dp_128_1024

TestBench_timing.vhd
  ├── matmul_v1.vhd
  └── blk_mem_dp_128_1024
```

---

## Synthesis & Implementation Notes

### Resource Utilization (Estimate - Zynq-7000)
| Resource | Count | Notes |
|----------|-------|-------|
| LUTs | ~2,500 | State machine, AXI logic |
| FFs | ~1,200 | Pipelined accumulators |
| DSP48E1 | 16 | MAC units (8×8 → 64-bit) |
| BRAM | 4 | 128-bit wide, 4K deep |

### Timing Closure
- Target clock: 100 MHz
- Critical path: BRAM read → DSP → Summation tree adders
- Pipelined: 4 stages allow deep folding

---

## Troubleshooting

### Simulation Issues

**Problem:** `m00_axis_tdata` doesn't match expected value
- **Check:** vec_len is correctly written via AXI4-Lite
- **Check:** Activations are pre-fetched into BRAM at address 0
- **Check:** Allow sufficient time for 4-stage summation tree (~4 cycles)

**Problem:** `s00_axis_tready` never asserts
- **Check:** Reset (`s00_axi_aresetn` = '1') is asserted long enough
- **Check:** State machine is in `active` state (check waveform)

**Problem:** BRAM data mismatches
- **Check:** Port B write enable (`web`) is pulsed correctly
- **Check:** BRAM latency (usually 1 cycle for synchronous read)

---

## References

- **VHDL:** IEEE 1076-2008 Standard
- **AXI:** Xilinx AXI Protocol Specifications
- **DSP:** Xilinx DSP48E1 User Guide
- **PYNQ:** https://pynq.readthedocs.io

---

## Contact & Support

- **Project:** TinyLLM FPGA Acceleration
- **Last Updated:** May 2026
- **Maintainers:** TinyLLM FPGA Team

For issues or questions:
1. Check `DESIGN_DOCUMENTATION.md` for architecture details
2. Review test bench waveforms in simulation
3. Verify golden model with `matmul_test.py`

---
