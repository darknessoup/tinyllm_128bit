# TinyLLM FPGA Matmul Accelerator - Design Documentation

## Project Overview

This project implements a 16-parallel MAC (Multiply-Accumulate) engine for matrix multiplication acceleration on FPGA, specifically designed for tiny LLM (Language Model) inference. The accelerator processes 128-bit wide weights and 128-bit wide activation streams to compute inner products efficiently.

---

## Architecture Overview

### High-Level System Block Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                         matmul_v1_0 (Top Level)                     │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ AXI4-Lite Slave (32-bit)                                     │  │
│  │ - vec_len register @ 0x0 (16-bit field)                      │  │
│  │ - Used to configure the vector length for current matmul     │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                           │                                         │
│                           ▼                                         │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ matmul_manager (State Machine & Accumulation Engine)         │  │
│  │ - 16 parallel DSP MAC units (macc_dsp instances)             │  │
│  │ - 4-stage pipelined accumulator tree                         │  │
│  │ - Manages BRAM read sequencing                               │  │
│  └──────────────────────────────────────────────────────────────┘  │
│         │                             │                             │
│         │ BRAM control signals        │ Accumulation result         │
│         │ (addr, en, rsta)            │                             │
│         ▼                             ▼                             │
│  ┌──────────────────┐         ┌──────────────────────┐             │
│  │ True Dual-Port   │         │ AXI4-Stream Master   │             │
│  │ BRAM             │         │ (64-bit output)      │             │
│  │ (128-bit, 4096)  │         │ - Neuron results     │             │
│  │ Port A: Activs   │         │ - One result/beat    │             │
│  │ Port B: CDMA     │         └──────────────────────┘             │
│  └──────────────────┘                                               │
│         ▲                                                            │
│         │ Activation data from BRAM (128-bit)                      │
│         │                                                           │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ AXI4-Stream Slave (128-bit weights)                          │  │
│  │ - 16 x 8-bit signed weights per beat                         │  │
│  │ - Byte-lanes correspond to 16 DSP inputs                     │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

---

## Module Descriptions

### 1. matmul_v1_0 (Top-Level Wrapper)

**File:** `matmul_v1.vhd`

**Purpose:** Top-level integration module that connects all subcomponents via AXI protocols.

**Key Generics:**
- `BRAM_ADDR_WIDTH`: 12 (supports 4096 locations)
- `C_S00_AXI_DATA_WIDTH`: 32 (AXI4-Lite bus width)
- `WEIGHT_TDATA_WIDTH`: 128 (AXI4-Stream slave width)
- `OUTPUT_TDATA_WIDTH`: 64 (AXI4-Stream master width)

**Interfaces:**
- **AXI4-Lite Slave (S00_AXI):** 32-bit address bus, carries vec_len register at offset 0x0
- **AXI4-Stream Slave (S00_AXIS):** 128-bit weight stream (16 x 8-bit signed)
- **AXI4-Stream Master (M00_AXIS):** 64-bit neuron output stream
- **BRAM Interface:** 128-bit bidirectional data, 12-bit address, byte-enables

---

### 2. matmul_manager (Accumulation & Control Engine)

**File:** `matmul_manager.vhd`

**Purpose:** 
- State machine coordinating BRAM reads and weight stream handshaking
- Instantiates 16 parallel MAC DSP units
- Implements 4-stage pipelined summation tree for combining results
- Produces 64-bit output (neuron accumulator result) at word rate

**Generic Parameters:**
- `WEIGHT_TDATA_WIDTH`: 128
- `OUTPUT_TDATA_WIDTH`: 64
- `BRAM_ADDR_WIDTH`: 12

**State Machine:**
```
idle → active → finishing → done
  │      ↓ (blocked if needed) ↓      ↓
  └─ blocked → blocked_finishing
```

| State | Behavior |
|-------|----------|
| `idle` | Waiting for first weight beat (s00_axis_tvalid). On valid → active. |
| `active` | Accepting weight beats, performing MAC. On tlast → finishing. On blocked condition → blocked. |
| `finishing` | No more weights coming; allow accumulated results to pipeline through summation tree. |
| `blocked` | Weight reception paused to allow pipelined summation to complete. |
| `blocked_finishing` | Blocked state triggered by tlast; after summation complete → done. |
| `done` | Result ready; asserts m00_axis_tvalid; m00_axis_tlast=1. On m00_axis_tready → idle. |

**MAC Pipeline:**
- 16 DSP units compute: `acc_out_i = Σ(weight_byte[i] * activation_byte[i])` for each byte lane
- Each DSP is 8×8→64-bit multiply-accumulate with synchronous load
- Results are pipelined through a 4-stage adder tree:
  - **Stage 1:** 8 pairwise additions (16→8 accumulators)
  - **Stage 2:** 4 dual additions (8→4 accumulators)
  - **Stage 3:** 2 dual additions (4→2 accumulators)
  - **Stage 4:** 1 final addition (2→1 result, final 64-bit output)

**Key Signals:**
- `length_div16`: Computed from vec_len; counts how many 128-bit BRAM words needed
- `count`: Tracks current BRAM word index (0 to length_div16-1)
- `bram_addr`: Prefetch address; increments each cycle to enable pipelining
- `s00_axis_tready`: High when manager is in `active` state (ready for weights)
- `m00_axis_tvalid`: High when result is ready; strobed by external flow control

---

### 3. macc_dsp (8×8 Multiply-Accumulate Unit)

**File:** `mac.vhd`

**Purpose:** 
Single multiply-accumulate DSP unit exploiting Xilinx DSP48 primitives for efficient 8×8 multiply and 64-bit accumulation.

**Generics:** None (fixed 8-bit inputs, 64-bit output)

**Interface:**
```vhdl
Port (
  clk       : in std_logic;
  ce        : in std_logic;                -- Clock enable (when '1', perform MAC)
  clr_acc   : in std_logic;               -- Accumulator clear (synchronous load reset)
  a         : in signed(7 downto 0);      -- 8-bit weight
  b         : in signed(7 downto 0);      -- 8-bit activation
  accum_out : out signed(63 downto 0)     -- 64-bit accumulator
);
```

**Internal Pipeline:**
```
Cycle N:   a_reg, b_reg ← a, b (registered inputs)
Cycle N+1: mult_reg ← a_reg * b_reg (8×8 multiply)
           adder_out ← old_result + mult_reg (64-bit add)
Cycle N+2: accum_out ← adder_out (registered output)
```

**Latency:** 3 clock cycles from input to output

**Accumulation Logic:**
- If `clr_acc='1'`: `old_result ← 0` (resets accumulator without losing a cycle)
- If `clr_acc='0'`: `old_result ← adder_out` (accumulation feedback)

---

### 4. AXI Slave Interface (axi_interface.vhd)

**File:** `axi_interface.vhd`

**Purpose:** AXI4-Lite slave for register programming (vec_len configuration).

**Registers:**
- **Offset 0x0:** `vec_len` (16-bit write/read)
  - Input vector dimension (controls how many 128-bit BRAM words to process)
  - Internal: `length_div16 = vec_len / 16`

---

## Data Flow

### Weight Stream Input (AXI4-Stream Slave, 128-bit)
- Each beat carries 16 signed 8-bit weights: `weight[i]` for i ∈ [0, 15]
- Bytes are mapped to DSP inputs: `s00_axis_tdata(8*(i+1)-1 downto 8*i)` → macc_i input `a`

### Activation Stream (from BRAM)
- Manager pre-fetches activation vector from BRAM port A
- Each 128-bit BRAM word contains 16 signed 8-bit activations
- On each clock while in `active` state:
  - Read BRAM at address `count` (indexes into activation vector)
  - Activation byte `i` is fed to macc_i input `b`

### Output (AXI4-Stream Master, 64-bit)
- One 64-bit neuron result per weight frame
- When manager asserts `m00_axis_tvalid`, downstream logic captures `m00_axis_tdata`
- Typical downstream: DMA engine writes to main memory or PS DDR

---

## Timing & Throughput

### Single Neuron Computation

**Assumptions:**
- Vector length = 1024 elements (16 MAC iterations required, i.e., length_div16=64)
- Each MAC iteration processes 16 element-pairs in parallel

**Latency Breakdown:**
1. **Weight Stream Acceptance:** 64 cycles (one per 128-bit weight beat)
2. **BRAM + DSP Pipeline:** 4 cycles (BRAM read latency + 3-cycle DSP + 1 idle to start pipelining)
3. **Summation Tree Latency:** 4 cycles (4 stages of pipelined addition)
4. **Result Strobe:** 1 cycle (m00_axis_tvalid assertion)

**Total Latency (1024-element vector):** ~73 clock cycles

**Throughput:**
- With proper pipelining and multiple neurons queued: ~1 neuron per 64 clock cycles (limited by weight stream rate)
- Peak DSP utilization: 16 × 8×8 multiply = 128 multiply operations/cycle

---

## Test Benches

### 1. TestBench.vhd (Comprehensive Functional Test)

**Purpose:** Multi-phase inference simulation with realistic data patterns.

**Test Phases:**
1. **Reset & Initialization:**
   - Assert `resetn=0` for 20ns
   - Write `vec_len=8` via AXI4-Lite

2. **Phase 1: First Weight Stream (32 beats, no tlast)**
   - Weights: sparse pattern (ident=1 every 9 cycles, else 0)
   - Manager stays in idle/active, pre-fetches from BRAM

3. **Phase 2: Second Weight Stream (32 beats, tlast on beat 63)**
   - Weights: same sparse pattern
   - Final beat asserts `tlast` → manager moves to finishing/done

4. **Inter-Phase Gap:**
   - BRAM port B write: pulse `web=x"FFFF"` for 40ns to commit new activation vector

5. **Phase 3: Third Weight Stream (64 beats, tlast on beat 63)**
   - Full inference pass with new activations

**Stimulus Procedures:**
- `write_axi()`: Performs full AXI4-Lite write handshake (AWVALID, WVALID, BVALID)

**Key Waveform Inspection Points:**
- `s00_axis_tready`: Should pulse high when manager is active
- `m00_axis_tvalid`: Should assert once per inference frame (after summation tree settles)
- `m00_axis_tdata`: Neuron output (check against golden model)
- `bram_addr`: Should increment sequentially per cycle while in active state

---

### 2. TestBench_timing.vhd (Deterministic Single-Cycle Test)

**Purpose:** Validate exact timing for one simple MAC operation.

**Test Vector:**
- **Activations:** BRAM word = `0x0f0e0d0c0b0a09080706050403020100` (bytes 0x00..0x0F)
- **Weights:** All bytes = `0x01`
- **vec_len:** 16 (exactly one 128-bit BRAM word)

**Expected Result:**
```
MAC_sum = Σ(i * 1) for i ∈ [0, 15]
        = 0 + 1 + 2 + ... + 15
        = 120 = 0x78
```

**Waveform Check:**
- `m00_axis_tdata` should equal `0x0000000000000078` when `m00_axis_tvalid=1`

**Test Flow:**
1. Reset & write activations to BRAM port B
2. Release reset, write vec_len=16 via AXI4-Lite
3. Send one weight beat with all bytes=0x01, assert tlast
4. Wait for m00_axis_tvalid → check m00_axis_tdata = 0x78

---

## Python Integration

### matmul.py (Driver Class)

**MatmulIP Class:**
- Wraps AXI4-Lite register access
- Property `vec_len`: Read/write the vector length register at offset 0x0

**StreamMatmulDriver Class:**
- Higher-level abstraction for matrix multiplication operations
- Method `matmul(vec_buf, mat_buf, out_buf, timer=None, wait=False)`:
  - **vec_buf:** Activation vector (1, 1, size) in int8
  - **mat_buf:** Weight matrix (output_dim, input_dim) in int8
  - **out_buf:** Output buffer (1, output_dim) in int32
  - **Returns:** Populated output buffer
- Uses PYNQ `CDMA` for vectorized activation loading to BRAM
- Uses AXI DMA send for weight streaming, receive for result collection

**Typical Usage:**
```python
ol = Overlay(bitstream_path)
mdriver = ol.StreamMatmulDriver()
out = mdriver.matmul(activations, weights, output_buffer)
```

### llm.py & lllm-proj-matmul.py (Inference Scripts)

**Purpose:** TinyLLM end-to-end inference integrating PL matmul with PS software layers.

**Key Functions:**
- `predict()`: Single token prediction loop
- `ln()`: Layer normalization
- `softmax()`, `gelu()`: Activation functions
- `quantize_activation_per_tensor_absmax()`: int8 quantization

**Matmul Integration:**
- Calls `ol.matmul_memory.matmul(activations, weights, output_buffer)` for PL acceleration
- Handles software fallback if USE_PL=False

---

## Known Issues & Future Improvements

### Current Issues

1. **AXI4-Lite Strobe Width Mismatch** (TestBench.vhd):
   - Signal `s00_axi_wstrb` declared as `std_logic_vector(15 downto 0)` but should be 3 downto 0 for 32-bit data
   - Impact: Low severity; most AXI slaves ignore unused strobe bits
   - **Fix:** Change to `s00_axi_wstrb : std_logic_vector(3 downto 0)`

2. **Empty matmul_test.py**:
   - Test file created but not populated with unit tests
   - **Fix:** Implement basic test vectors for DSP unit verification

3. **Documentation in Comments**:
   - Limited inline VHDL comments; relies on external documentation
   - **Fix:** Add state machine and pipeline diagrams to VHDL source

---

### Future Enhancements

1. **Configurable Vector Length:**
   - Add support for sub-vector (< 128 elements) processing
   - Current: Only efficiently handles multiples of 16

2. **Dynamic Precision Control:**
   - Add register bits to enable/disable saturation, rounding modes
   - Current: Fixed 8×8→64-bit no saturation

3. **Performance Optimization:**
   - Implement dual-streaming to pipeline multiple neurons
   - Current: One neuron result per 64 cycles

4. **Fault Tolerance:**
   - Add parity or ECC on BRAM and accumulator outputs
   - Current: No error detection

5. **Memory Expansion:**
   - Support 16K/32K BRAM configurations for larger batch sizes
   - Current: 4096 × 128-bit (512 KB)

6. **Debugging Enhancements:**
   - Add integrated logic analyzer (ILA) triggers for internal state
   - Expose intermediate accumulator values via debug registers

---

## Verification Checklist

- [ ] **Simulation:** Run TestBench.vhd in Vivado/ModelSim, verify weight acceptance and neuron outputs
- [ ] **Timing:** Run TestBench_timing.vhd, confirm m00_axis_tdata = 0x78
- [ ] **Synthesis:** Confirm LUT/BRAM/DSP utilization; check timing closure
- [ ] **Real Data:** Load real LLM weights/activations, compare PL vs. software results
- [ ] **Stream Coherency:** Verify tlast propagation and frame boundaries with real DMA flows
- [ ] **Python Integration:** Test PYNQ overlay load, matmul driver instantiation, end-to-end inference

---

## Build & Deployment

### Vivado Project Setup
1. Open `llm_project.xpr` in Vivado
2. Run synthesis/implementation on `simple_dma` design
3. Generate bitstream → `llm_project.bit`

### PYNQ Deployment
1. Copy bitstream to Zynq board
2. Load overlay: `ol = Overlay(bitstream_path)`
3. Instantiate driver: `driver = ol.StreamMatmulDriver()`
4. Call matmul: `result = driver.matmul(activations, weights, output_buffer)`

---

## References

- VHDL IEEE 1076-2008 Standard
- Xilinx AXI Protocol Spec (AXI4, AXI4-Lite, AXI4-Stream)
- Xilinx DSP48 User Guide (for MAC pipelining)
- PYNQ Documentation: https://pynq.readthedocs.io

---

## Authors & History

- **Created:** March 2024
- **Last Updated:** May 2026
- **Maintainers:** TinyLLM FPGA Team

---
