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
- `OUTPUT_TDATA_WIDTH`: 32 (AXI4-Stream master width — 32-bit signed result)

**Interfaces:**
- **AXI4-Lite Slave (S00_AXI):** 32-bit address bus, carries vec_len register at offset 0x0
- **AXI4-Stream Slave (S00_AXIS):** 128-bit weight stream (16 x 8-bit signed)
- **AXI4-Stream Master (M00_AXIS):** 32-bit neuron output stream
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
- `OUTPUT_TDATA_WIDTH`: 32
- `BRAM_ADDR_WIDTH`: 12

**State Machine:**
```
idle → active → finishing → done
  │      ↓ (blocked if needed)      ↓
  └─ blocked → active          blocked_finishing → done
```

| State | Behavior |
|-------|----------|
| `idle` | Waiting for first weight beat (`s00_axis_tvalid`). On valid → `active`. |
| `active` | Accepting weight beats, performing MAC each cycle `tvalid='1'`. On `tlast` → `finishing`. On `result_ready='1'` at `count=1` → `blocked`. |
| `finishing` | `tlast` received. Runs a 2-cycle pipeline flush (keeping `macc_en='1'` to drain the MAC stages), then executes the 2-stage summation tree over 2 registered cycles. Moves to `done` or `blocked_finishing` based on `m00_axis_tready`. |
| `blocked` | Weight reception paused because a prior result has not been consumed by downstream. Resumes to `active` when `m00_axis_tready='1'`. |
| `blocked_finishing` | Summation complete but downstream not ready. Waits for `m00_axis_tready` → `done`. |
| `done` | Result valid. Asserts `m00_axis_tvalid` and `m00_axis_tlast`. Resets `flush_count`, `sum_done`. On `m00_axis_tready` → `idle`. |

**MAC Pipeline:**
- 16 DSP units compute: `acc_out_i = Σ(weight_byte[i] * activation_byte[i])` for each byte lane
- Each DSP is 8×8→32-bit multiply-accumulate with synchronous load
- The `macc_dsp` component has a **2-stage internal pipeline**: inputs are registered one cycle before multiply, and the multiply result feeds the adder the same cycle — so valid data presented at cycle K appears in `adder_out` (and thus `accum_out`) at cycle **K+2**.
- Results are reduced through a **2-stage registered adder tree** after the flush:
  - **Stage 1:** 8 pairwise additions (16→8 partial sums), registered
  - **Stage 2:** 4 additions + final 4→1 combinatorial chain produces `output_reg` (32-bit)

**Pipeline Flush Mechanism (`flush_count`):**

Because the MAC has a 2-stage internal pipeline, simply deasserting `macc_en` the cycle after `tlast` is accepted would leave the last product in-flight and not yet reflected in `adder_out`. The `flush_count` signal (2-bit) solves this:

1. On entry to `finishing`, `flush_count=0` and `macc_en='1'` (driven by `flush_count < 2`).
2. `tdata` and `bram_din` are held at their last-beat values (AXI-Stream initiator deasserts `tvalid` but the data bus is still driven).
3. Over 2 rising edges, `flush_count` increments to 2 and the last product propagates through all MAC pipeline stages.
4. When `flush_count = 2`, `macc_en='0'`; accumulators are frozen and stable. The summation tree then reads them.

**`clr_acc` Guard:**

The accumulator clear signal is gated to fire **only in `idle` or `done`** states:
```vhdl
clr_acc <= '1' when count = 0 and (state = idle or state = done) else '0';
```
Without this guard, `clr_acc` would fire in `finishing` when `macc_en='0'` and `count=0` — wiping the accumulators just as the summation tree is reading them.

**Key Signals:**
- `length_div16`: `length(15 downto 4)` — number of 128-bit BRAM words (and weight beats) per dot product
- `count`: Tracks current BRAM word index (0 to `length_div16-1`)
- `flush_count`: 2-bit counter; drives 2 extra `macc_en` cycles in `finishing` to drain MAC pipeline
- `sum_valid`: Handshake flag between Stage 1 and Stage 2 of the adder tree
- `sum_done`: Prevents the adder tree from re-executing if `finishing` lingers
- `first_done`: Set when `count = length_div16 - 1`; confirms all accumulations are complete
- `bram_addr`: Directly driven from `count` (not `next_count`) — BRAM presents data one cycle after address, matching the MAC input registration stage
- `s00_axis_tready`: High only in `active` state
- `m00_axis_tvalid`: Combinatorially driven by `result_ready` register

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

### Output (AXI4-Stream Master, 32-bit)
- One 32-bit neuron result per weight frame
- When manager asserts `m00_axis_tvalid`, downstream logic captures `m00_axis_tdata`
- Typical downstream: DMA engine writes to main memory or PS DDR

---

## Timing & Throughput

### Single Neuron Computation

**Assumptions:**
- Vector length = 1024 elements (64 MAC iterations required, i.e., `length_div16=64`)
- Each MAC iteration processes 16 element-pairs in parallel

**Latency Breakdown (128-bit manager):**
1. **Weight Stream Acceptance:** 64 cycles (one per 128-bit weight beat)
2. **MAC Pipeline Flush:** 2 cycles (`flush_count` in `finishing` drains last product)
3. **Summation Tree — Stage 1:** 1 cycle (8 pairwise sums registered)
4. **Summation Tree — Stage 2:** 1 cycle (4 additions + final combinatorial chain → `output_reg`)
5. **Result Strobe:** `result_ready='1'` set same cycle as Stage 2

**Total Latency (1024-element vector):** ~68 clock cycles

**Throughput:**
- Back-to-back neurons possible if downstream consumes result before `count=1` on the next pass
- If downstream is slow: manager enters `blocked_finishing` and resumes after handshake
- Peak DSP utilization: 16 × 8×8 multiply = 128 multiply operations/cycle

**Exact Timing for `length_div16=1` (testbench vector):**

| Cycle | State | macc_en | Event |
|-------|-------|---------|-------|
| K | active | 1 | Beat accepted. `count←0`. `tlast='1'` → `state←finishing` |
| K+1 | finishing | 1 | `flush_count 0→1`. MAC pipeline stage 1 draining |
| K+2 | finishing | 1 | `flush_count 1→2`. Last product arrives in `adder_out` |
| K+3 | finishing | 0 | Stage 1 adder tree latches 8 pairwise sums. `sum_valid←1` |
| K+4 | finishing | 0 | Stage 2: final tree → `output_reg`. `result_ready←1`. → `done` or `blocked_finishing` |

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

### 2. TestBench_process.vhd (Deterministic Single-Cycle Test)

**Purpose:** Validate exact timing for one simple MAC operation with the 128-bit manager.

**Test Vector:**
- **Activations (BRAM port B, addr 0):** `0x01010101010101010101010101010101` (all bytes = 1)
- **Weights (one AXI-Stream beat):** `0x0102030405060708090a0b0c0d0e0f10` (bytes 1..16)
- **vec_len:** 16 → `length_div16 = 1` (exactly one 128-bit BRAM word)

**Expected Result:**
```
MAC_sum = Σ(weight[i] * activation[i]) for i ∈ [0, 15]
        = Σ((i+1) * 1) for i ∈ [0, 15]
        = 1 + 2 + 3 + ... + 16 = 136 = 0x88
```

**AXI-Stream Handshake (corrected):**

The testbench uses a `loop / exit when` pattern to correctly hold `tvalid` high until `tready` is sampled high at a rising clock edge:
```vhdl
loop
    wait until rising_edge(clk);
    exit when s00_axis_tready = '1';
end loop;
s00_axis_tvalid <= '0';
s00_axis_tlast  <= '0';
```
This ensures the manager process and the testbench process both see the handshake on the same rising edge, and `tvalid` is deasserted only *after* the beat is consumed. An earlier pattern (`wait until rising_edge; while tready/='1' loop...`) burned one cycle and exited the loop on a post-delta update of `tready`, so the handshake beat was never actually accepted.

**Test Flow:**
1. Assert `resetn='0'`, write activations to BRAM port B with `web=x"FFFF"`
2. Release reset, write `vec_len=16` via AXI4-Lite
3. Assert `m00_axis_tready='1'` (downstream always ready)
4. Present weight beat with `tvalid='1'`, `tlast='1'`; hold until `tready='1'`
5. Wait ~50 ns; observe `m00_axis_tdata = 0x00000088`

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

## Bug History & Design Decisions

This section records bugs found during simulation and the reasoning behind their fixes. It exists to prevent regressions and to explain non-obvious design choices.

### Bug 1 — Summation tree unreachable for short vectors (`count = 2` trigger)

**Symptom:** Accumulators populated correctly but `m00_axis_tvalid` never asserts for `length_div16 ≤ 2`.

**Root Cause:** The original Stage 1 condition was `count = 2 and first_done = '1'`. `next_count` wraps to 0 at `count = length_div16 - 1`. For `length_div16 = 1`, count wraps back to 0 immediately on the `tlast` beat and never reaches 2. For `length_div16 = 2`, count oscillates 0↔1, also never reaching 2.

**Fix:** Replaced the `count = 2` trigger with a dedicated `flush_count` / `sum_done` flow tied to entry into `finishing`, making the summation tree independent of vector length.

---

### Bug 2 — `macc_en='1'` throughout `finishing` caused accumulator corruption

**Symptom:** Accumulators correct after the `active` phase but wrong by the time the sum tree reads them; value increases with simulation time.

**Root Cause:** The original `macc_en` was `'1'` whenever `state = finishing`. Since `count` wraps to 0 and BRAM address 0 is re-fetched every cycle, the MAC units kept accumulating the first activation word repeatedly for an unbounded number of cycles before `count` happened to reach 2.

**Fix (first attempt):** Removed `finishing` from `macc_en`. Accumulators froze correctly, but `acc_out` was always 0 — because the MAC has a 2-stage pipeline and the last product had not yet propagated into `adder_out` when the sum tree read it.

**Fix (final):** Restore `macc_en='1'` in `finishing` for exactly `flush_count < 2` cycles. `flush_count` resets to 0 in `done`, preventing re-entry.

---

### Bug 3 — `clr_acc` fires in `finishing` and wipes accumulators

**Symptom:** Even with the flush properly gated, accumulators briefly read as 0 in waveforms between flush completion and sum tree Stage 1.

**Root Cause:** Original condition: `clr_acc <= '1' when count = 0 and macc_en = '0'`. In `finishing`, after `flush_count = 2`, `macc_en` drops to `'0'` and `count = 0` (it wrapped on the last active beat). Both conditions true → `clr_acc='1'` → accumulators zeroed one cycle before Stage 1.

**Fix:** Gate `clr_acc` to only fire in `idle` or `done`:
```vhdl
clr_acc <= '1' when count = 0 and (state = idle or state = done) else '0';
```

---

### Bug 4 — Testbench AXI-Stream handshake missed the beat

**Symptom:** With a correct manager, `macc_en` never fires — accumulators stay at 0 throughout simulation.

**Root Cause:** The original TB pattern:
```vhdl
wait until rising_edge(clk);     -- burns one cycle unconditionally
while s00_axis_tready /= '1' loop
    wait until rising_edge(clk);
end loop;
```
At the first `wait`, the manager's `idle→active` transition was registered. `tready` went high as a post-delta update on that same edge. The `while` condition was evaluated in simulation time, saw `tready='1'` immediately, and exited — but the TB then deasserted `tvalid` before the next rising edge. So on the first cycle `tready='1'`, `tvalid` was already `'0'`.

**Fix:** Replace with a `loop / exit when` that waits for a rising edge *and* samples `tready` atomically:
```vhdl
loop
    wait until rising_edge(clk);
    exit when s00_axis_tready = '1';
end loop;
```

---

## Known Issues & Future Improvements

### Current Issues

1. **Summation tree is 2-stage, not 4-stage:**
   - The current implementation uses 2 registered stages followed by a combinatorial chain in Stage 2. For `OUTPUT_TDATA_WIDTH=32`, overflow is possible if all 16 accumulators are near INT32_MAX. Consider widening `SUM_OUTPUT` or saturating.

2. **`sum_done` not reset on `blocked_finishing → done` path:**
   - `sum_done` is reset in `done`, but `flush_count` and `sum_done` are only reset inside the `done` case. If `blocked_finishing` transitions directly to `done` and then immediately to `idle` within one `m00_axis_tready` pulse, there is no issue — but this is worth verifying in waveforms with back-to-back neuron requests.

3. **AXI4-Lite Strobe Width Mismatch** (TestBench_process.vhd):
   - Signal `s00_axi_wstrb` should be `std_logic_vector(3 downto 0)` for 32-bit data
   - **Fix:** Change to `s00_axi_wstrb : std_logic_vector(3 downto 0)`

4. **Empty matmul_test.py**:
   - Test file created but not populated with unit tests
   - **Fix:** Implement basic test vectors for DSP unit verification

---

### Future Enhancements

1. **Configurable Vector Length:**
   - Add support for sub-vector (< 128 elements) processing
   - Current: Only efficiently handles multiples of 16

2. **Dynamic Precision Control:**
   - Add register bits to enable/disable saturation, rounding modes
   - Current: Fixed 8×8→32-bit no saturation

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

- [ ] **Simulation:** Run TestBench_process.vhd in Vivado/ModelSim, verify `m00_axis_tdata = 0x00000088`
- [ ] **Timing:** Confirm `flush_count` correctly gates 2 extra MAC cycles before sum tree
- [ ] **Back-to-Back:** Simulate two consecutive neurons to verify `flush_count`/`sum_done` reset in `done`
- [ ] **Synthesis:** Confirm LUT/BRAM/DSP utilization; check timing closure
- [ ] **Real Data:** Load real LLM weights/activations, compare PL vs. software results
- [ ] **Stream Coherency:** Verify `tlast` propagation and frame boundaries with real DMA flows
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
- **Last Updated:** May 2026 (architecture corrections and pipeline bug fixes)
- **Maintainers:** TinyLLM FPGA Team

---
