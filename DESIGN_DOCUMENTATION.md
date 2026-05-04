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

**Purpose:** 
- State machine coordinating BRAM reads and weight stream handshaking
- Instantiates 16 parallel MAC DSP units
- Fires results per row using count-based trigger (every `length_div16` beats)
- Produces 32-bit output (accumulated inner product) per row

**Generic Parameters:**
- `WEIGHT_TDATA_WIDTH`: 128
- `OUTPUT_TDATA_WIDTH`: 32
- `BRAM_ADDR_WIDTH`: 12

**State Machine (Current Refactored Version):**
```
idle → active → finishing → done
  │      ↓ (blocked if needed)      ↓
  └─ blocked → active          blocked_finishing → finishing
```

| State | Behavior |
|-------|----------|
| `idle` | Waiting for first weight beat (`s00_axis_tvalid`). On valid → `active`. |
| `active` | Accepting weight beats. On each beat with `s00_axis_tvalid='1'`, run MAC and increment `count`. On `tlast` → `finishing`. On `count=2 and first_done='1'` → fire result, stay in active or go to blocked. On `count=1 and result_ready='1'` → `blocked`. |
| `finishing` | `tlast` received. Continue MAC pipeline with `macc_en='1'`. At `count=2 and first_done='1'`, fire result and transition to `done`. ⚠️ **CRITICAL BUG:** After final weight beat with no more beats arriving, pipeline drains incorrectly; final row's result may not fire. |
| `blocked` | Weight reception paused because result not consumed. Resume to `active` when `m00_axis_tready='1'`. |
| `blocked_finishing` | In `finishing` state with result pending; downstream not ready. Resume to `finishing` (not `done`) when ready. |
| `done` | Result valid. Asserts `m00_axis_tlast`. On `m00_axis_tready` → `idle`. |

**MAC Pipeline & Result Generation:**
- 16 DSP units compute: `acc_out_i = Σ(weight_byte[i] * activation_byte[i])` for each byte lane
- Each DSP is 8×8→32-bit multiply-accumulate with synchronous load
- **2-stage internal pipeline:** Valid data at cycle K appears in accumulators at cycle K+2
- **Result Firing:** At `count=2 and first_done='1'`, compute `output_reg = acc_out1 + ... + acc_out16` (16-way combinatorial sum)
- **Count-Based Trigger:** For 768-element vector, `length_div16=48`, so results fire every 48 beats
- ⚠️ **Architectural Limitation:** Assumes the next row's first beats (count=0,1) provide the 2-cycle pipeline drain for the current row. This breaks for the final row in a single-packet DMA transfer where no further beats arrive.

**Signal Definitions:**
- `length_div16`: `length(15 downto 4)` — number of 128-bit BRAM words per row
- `count`: Current BRAM word index (0 to `length_div16-1`), wraps after `length_div16-1`
- `first_done`: Set when `count = length_div16 - 1`; persists through all rows until `done` state
- `clr_acc`: Asserted on `count<2 and first_done='0'` or `count=1 and first_done='1'` during active cycles to reset accumulators
- `bram_addr`: Driven by `next_count` (prefetch one cycle early; BRAM has 1-cycle latency)
- `result_ready`: High when result is valid; cleared after handshake
- `m00_axis_tvalid`: Directly driven by `result_ready`
- `m00_axis_tlast`: Asserted when `state=done`

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

This section records bugs found during simulation and implementation, and the architectural approaches taken to fix them.

### Original Bugs (Early Simulation)

#### Bug 1 — Summation tree unreachable for short vectors (`count = 2` trigger)

**Symptom:** Accumulators populated correctly but `m00_axis_tvalid` never asserts for `length_div16 ≤ 2`.

**Root Cause:** The original Stage 1 condition was `count = 2 and first_done = '1'`. `next_count` wraps to 0 at `count = length_div16 - 1`. For `length_div16 = 1`, count wraps back to 0 immediately on the `tlast` beat and never reaches 2.

**Initial Fix:** Implemented a dedicated `flush_count` / `sum_done` flow and 2-stage registered summation tree tied to `finishing` state entry, making result generation independent of vector length.

---

#### Bug 2 — `macc_en='1'` throughout `finishing` caused accumulator corruption

**Symptom:** Accumulators correct after `active` phase but corrupted by `finishing`; value drifts with simulation time.

**Root Cause:** `macc_en='1'` in `finishing` allowed unbounded accumulation of BRAM[0] as `count` wrapped repeatedly.

**Initial Fix:** Introduced `flush_count` (2-bit) to limit `macc_en='1'` to exactly 2 cycles in `finishing` for MAC pipeline drainage.

---

#### Bug 3 — `clr_acc` fires in `finishing` and wipes accumulators

**Symptom:** Accumulators read as 0 between flush completion and sum tree read.

**Root Cause:** `clr_acc='1'` when `count=0 and macc_en='0'` fired in `finishing` after flush ended, zeroing accumulators before summation.

**Fix:** Gated `clr_acc` to only fire in `idle` or `done` states.

---

#### Bug 4 — Testbench AXI-Stream handshake missed the beat

**Symptom:** `macc_en` never fires in simulation; accumulators stay 0.

**Root Cause:** AXI-Stream TB pattern burned a cycle before checking `tready`, causing `tvalid` to deassert before handshake.

**Fix:** Changed to `loop / exit when` pattern that waits and samples atomically.

---

### Architectural Refactoring & The Critical Bug

#### Refactoring Attempt (Session N)

**Motivation:** The flush_count / 2-stage sum tree architecture was adding complexity. Hypothesis: the 32-bit manager (known to work) uses a simpler model.

**Changes Made:**
- Removed `flush_count`, `sum_valid`, `sum_done`, `sum_stage1_x` signals
- Removed 2-stage registered summation tree
- Changed to `active | finishing` combined state with direct 16-accumulator sum at `count=2 and first_done='1'`
- Simplified `clr_acc` logic: `(count < 2 and first_done='0') or (count=1 and first_done='1')`
- Changed `clr_acc` guard to fire during active computation, not just `idle`/`done`
- Fixed `bram_addr <= next_count` (prefetch)
- Fixed `blocked_finishing` to return to `finishing` (not `done`)

**Result:** Code complexity reduced by ~50 lines. Architecture now mirrors 32-bit exactly.

**Expected Behavior:** Manager should fire results continuously: every `length_div16` beats (every 48 beats for 768-dim), regardless of `tlast`. One `tlast` at the end marks final row. All 3072 output indices populated.

---

#### Critical Bug Exposed: Only First Output Index Populated ⚠️

**Symptom (from cdma_test.py):** DMA transfer of full 3072×768 matrix produces only `out_buf[0]` with valid value; rest are 0.

**Root Cause (ARCHITECTURAL FLAW):**

The refactored architecture assumes the pipeline will drain naturally via "free" flush cycles provided by the next row's beats. But this breaks for the **final row** with a single-packet DMA transfer:

1. **DMA Packet Structure:** Python driver sends entire weight matrix as ONE AXI-Stream packet:
   - Total beats: 3072 rows × 48 beats/row = 147,456 beats
   - Only the **final beat (beat 147455)** asserts `tlast='1'`
   - This beat is `count=47` (last beat) of row 3071

2. **Result Fire Condition:** Manager fires results at `count=2 and first_done='1'`
   - For row 3071: Beats 147408-147455 (its 48 beats)
   - At beat 147455: `count=47`, `tlast='1'` → state transitions to `finishing`
   - Expected next beat: count wraps to 0, then to 1, then to 2 (at beat 147457)
   - **Actual next beat:** There is none. The DMA transfer ends.

3. **Pipeline Never Drains for Final Row:**
   - After beat 147455, `s00_axis_tvalid='0'` (no more weight beats)
   - Manager is in `finishing` state with `macc_en='1'` (independent of `tvalid`)
   - But the MACs compute using old (stale) `s00_axis_tdata` and `bram_din` — wrong behavior
   - The 2-stage MAC pipeline for row 3071 never properly flushes into accumulators
   - Result for row 3071 never fires at `count=2`

4. **Result:** Only rows 0 through ~1.04 produce valid outputs (~52 out of 3072). DMA captures first result only; remaining 3071 are never sent, leaving `out_buf[1..3071]` as zeros.

---

#### Why the 32-bit Manager May Not Have Exposed This Bug

- The 32-bit uses 96 beats/row (768/8). Smaller beat count may interact differently with DMA buffering.
- The 32-bit test vector may use shorter matrices where the final row's pipeline doesn't need extra beats.
- The bug may exist in the 32-bit too but was masked by test configuration.

---

#### Required Solution: Explicit `tlast` Handling

**Correct approach:** Do NOT rely on implicit count wrapping to drain the final row's pipeline. Instead:

1. **Detect `tlast`:** Track when the final weight beat arrives.
2. **Explicit Flush:** After the current row cycle, run exactly 2 cycles with `macc_en='1'` even if `s00_axis_tvalid='0'`, to drain the MAC pipeline.
3. **Fire Result:** At `count=2` (after those 2 cycles), output the final result and assert `m00_axis_tlast='1'`.
4. **End Transfer:** Transition to `done`.

This reintroduces a cycle counter similar to `flush_count`, but now it is **mandatory for correctness** with single-packet DMA transfers, not an optional optimization.

**Recommended Fix:** Restore a version of the `flush_count` mechanism, but with explicit `tlast` awareness and gating to prevent over-firing.

---

## Known Issues & Future Improvements

### CRITICAL: Architectural Flaw in Current Refactored Implementation

**Status:** ⚠️ **NOT WORKING** — Only first output index populated in multi-neuron transfers

**Issue:** The refactored architecture (count-based firing without explicit `tlast` handling) assumes the next row provides 2 flush cycles for the current row's pipeline. This is violated for the **final row** in a single-packet DMA transfer.

**Evidence:** `cdma_test.py` output shows only `out_buf[0]` populated; all other indices are 0.

**Immediate Action Required:**
- **Do NOT synthesize the current matmul_manager_128bit.vhd** — it will fail multi-neuron workloads.
- Restore the `flush_count` mechanism with explicit `tlast` awareness to handle final row pipeline draining correctly.
- Or restructure to support per-row packet boundaries (requires Python driver changes).

**Pending Issues (from pre-refactoring):**

1. **Output width overflow potential:**
   - Direct 16-accumulator sum can produce values wider than 32 bits if individual accumulators are large
   - Current code uses `resize(..., SUM_OUTPUT)` which truncates to 32 bits
   - May cause saturation/truncation of large dot products
   - **Mitigation:** For int8 inputs, 16 MACs of (8×8=64-bit products) sum to ~14 bits per MAC, total ~18 bits per row. Within 32-bit range for typical workloads.

2. **AXI4-Lite Strobe Width Mismatch** (TestBench_process.vhd):
   - Signal `s00_axi_wstrb` should be `std_logic_vector(3 downto 0)` for 32-bit data
   - **Fix:** Change to `s00_axi_wstrb : std_logic_vector(3 downto 0)`

3. **Empty matmul_test.py**:
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
