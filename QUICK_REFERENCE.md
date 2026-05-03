# TinyLLM Matmul Accelerator - Quick Reference Guide

## Key System Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| **MAC Units** | 16 parallel | 8×8 multiply → 64-bit accumulate |
| **Weight Bus Width** | 128-bit | AXI4-Stream slave (s00_axis) |
| **Output Bus Width** | 64-bit | AXI4-Stream master (m00_axis) |
| **BRAM Depth** | 4096 (4K) | 128-bit wide, dual-port |
| **BRAM Address Width** | 12-bit | log2(4096) |
| **AXI4-Lite Data Width** | 32-bit | Configuration register bus |
| **Clock Frequency** | 100 MHz (target) | 10 ns period |
| **Latency per Neuron** | ~64 cycles | 16 MAC iters × 4 cycles/summation tree |

---

## Register Map

### AXI4-Lite Slave (S00_AXI) - 32-bit Data Bus

| Offset | Name | Type | Width | Description |
|--------|------|------|-------|-------------|
| **0x0** | `vec_len` | R/W | 16-bit | Vector length (elements). Controls loop count = vec_len/16. |

**Example:**
- Write 128 to vec_len → Processor expects 128 activations (8 × 128-bit BRAM words)

---

## Data Path

### Weight Stream (s00_axis_tdata[127:0])

```
Byte 15  Byte 14  ...  Byte 1  Byte 0
   w[15]    w[14]  ...   w[1]    w[0]   (each 8-bit signed)
     ↓        ↓            ↓       ↓
  MAC[15]  MAC[14]  ...  MAC[1]  MAC[0]  (16 parallel units)
```

### Activation Stream (BRAM douta[127:0])

```
Byte 15  Byte 14  ...  Byte 1  Byte 0
   a[15]    a[14]  ...   a[1]    a[0]   (each 8-bit signed)
     ↓        ↓            ↓       ↓
  MAC[15]  MAC[14]  ...  MAC[1]  MAC[0]  (multiplies with weights)
```

### Output (m00_axis_tdata[63:0])

```
Result = Σ(w[i] × a[i]) for i ∈ [0, 15]
       = 64-bit signed integer
```

---

## Timing Diagram

### Single MAC Cycle (10 ns @ 100 MHz)

```
Clock        ↑     ↓     ↑     ↓     ↑     ↓     ↑
             |     |     |     |     |     |     |
Cycle        0     1     2     3     4     5     6

MAC[0]:      [a,b]→[mult]→[add]→[out]
Latency:      0     1     2     3      (3 cycles from input to output)

Manager:    [idle/active read BRAM] → [process] → [summation pipeline] → [result ready]
```

---

## State Machine Reference

```
┌─────────────────────────────────────────────────────────────────┐
│                  MANAGER STATE MACHINE                          │
└─────────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────┐
    ↓ reset                                                    │
 [IDLE]                                                        │
    │                                                          │
    │ s00_axis_tvalid='1'                                      │
    ↓                                                          │
 [ACTIVE] ←────────────────────────────────────────────────────┘
    │                              m00_axis_tready='1' (consume)
    │
    ├─→ s00_axis_tlast='1' & tvalid='1'
    │         ↓
    │      [FINISHING] ────→ Wait for pipeline drain
    │         │
    │         ↓ (pipelined sums complete)
    │      [DONE]
    │         │
    │         ↓ (m00_axis_tready='1')
    └───────→ [IDLE]

 Blocking Conditions:
    - If tvalid drops before tlast: MAY enter [BLOCKED]
    - If pipeline not drained by next beat: [BLOCKED_FINISHING]
```

---

## Summation Tree Pipeline

### 16 → 8 → 4 → 2 → 1 Reduction

```
MAC Outputs (16 × 64-bit):
  acc[0..15]

Stage 1 (Cycle 0):
  sum[0] = acc[0] + acc[1]
  sum[1] = acc[2] + acc[3]
  ...
  sum[7] = acc[14] + acc[15]

Stage 2 (Cycle 1):
  sum[0] = sum[0] + sum[1]    (carries intermediate sums)
  sum[1] = sum[2] + sum[3]
  ...
  sum[3] = sum[6] + sum[7]

Stage 3 (Cycle 2):
  sum[0] = sum[0] + sum[1]
  sum[1] = sum[2] + sum[3]

Stage 4 (Cycle 3):
  RESULT = sum[0] + sum[1]     (64-bit final output)
           ↓
         m00_axis_tdata
```

**Total latency:** 4 cycles

---

## Test Vectors

### Golden Model: Simplest Case

```
Weights:     [0x01, 0x01, ..., 0x01]  (16 ones)
Activations: [0x00, 0x01, ..., 0x0F]  (0 through 15)

Expected:    0 × 1 + 1 × 1 + ... + 15 × 1 = 120 = 0x78
             → m00_axis_tdata = 0x0000000000000078
```

### Run in Vivado Simulator

```tcl
# In Vivado Tcl Console after opening TestBench_timing.vhd

run 200ns
# Look for: m00_axis_tvalid = '1' → m00_axis_tdata = 0x0000000000000078
```

---

## Python Integration Checklist

- [ ] PYNQ Overlay loaded: `ol = Overlay("bitstream.bit")`
- [ ] Driver instantiated: `driver = ol.StreamMatmulDriver()`
- [ ] Buffers allocated: `allocate((batch, size), dtype=np.int8)`
- [ ] vec_len register written: `driver.matmul_0.vec_len = vector_length`
- [ ] CDMA transfer started: `driver.axi_cdma_0.transfer(activations, dst_addr)`
- [ ] DMA send/receive: `driver.axi_dma.sendchannel.transfer(weights)`
- [ ] Results collected: `driver.axi_dma.recvchannel.transfer(output_buf)`
- [ ] Verify golden model: `python matmul_test.py` ✓ All tests pass

---

## Common Pitfalls

| Issue | Cause | Solution |
|-------|-------|----------|
| `s00_axis_tready` stuck low | Manager not in `active` state | Check reset, write vec_len first |
| `m00_axis_tdata` incorrect | Results not pipelined through summation tree | Wait ≥4 cycles after weight beat |
| BRAM read returns 0x0 | Activations never written to BRAM | Use CDMA or port B write in testbench |
| Overflow in accumulator | Weights/activations too large | Check bit widths (8-bit signed range: -128..127) |
| Simulation hangs | Missing m00_axis_tready from downstream | Ensure testbench drives this signal high |

---

## Byte Lane Mapping

**Input (128-bit weights):**
```
s00_axis_tdata[127:120] → weight[15]  (MSB)
s00_axis_tdata[119:112] → weight[14]
...
s00_axis_tdata[15:8]    → weight[1]
s00_axis_tdata[7:0]     → weight[0]   (LSB)
```

**BRAM Output (128-bit activations):**
```
douta[127:120] → activation[15]  (MSB)
douta[119:112] → activation[14]
...
douta[15:8]    → activation[1]
douta[7:0]     → activation[0]   (LSB)
```

**Each MAC[i] computes:**
```
MAC[i] = Σ(weight[i] × activation[i])  for i ∈ [0, 15]
Result = Σ MAC[i]  (summed in tree)
```

---

## Performance Estimation

### Throughput (Neurons/Second)

```
Clock frequency:           100 MHz (10 ns/cycle)
Latency per neuron:        ~64 cycles
Time per neuron:           640 ns
Throughput:                100 MHz / 64 = ~1.56 Neurons/μs
                          = ~1.56M neurons/second

For 768-neuron layer (768 elements / 16 parallel):
  Time = 768 / 16 × 640 ns = 48 × 640 ns = 30.72 μs
```

### Memory Bandwidth

```
Weight stream:  128-bit/cycle × 100 MHz = 1.6 GB/s
Activation:     128-bit/cycle × 100 MHz = 1.6 GB/s (BRAM limited)
Output:          64-bit/cycle × 100 MHz = 0.8 GB/s
```

---

## Debugging Checklist

1. **Functional Check:**
   - [ ] Run `python matmul_test.py` → all pass?
   - [ ] Run TestBench_timing.vhd → m00_axis_tdata = 0x78?
   - [ ] Run TestBench.vhd → multiple frames processed?

2. **Waveform Inspection:**
   - [ ] s00_axis_tready pulses during active state?
   - [ ] s00_axis_tlast asserted on final beat?
   - [ ] m00_axis_tvalid strobes once per frame?
   - [ ] m00_axis_tdata holds result until tready?

3. **Register/Control:**
   - [ ] vec_len written correctly via AXI4-Lite?
   - [ ] Reset sequence: aresetn low → high, wait 20ns?
   - [ ] Clock stable at 100 MHz during simulation?

4. **Memory Access:**
   - [ ] BRAM douta matches expected activation pattern?
   - [ ] BRAM addra increments linearly in active state?
   - [ ] Port B writes update memory for next inference?

---

## Quick VHDL Snippets

### Instantiate Matmul Core

```vhdl
matmul_inst: matmul_v1_0
port map (
    s00_axi_aclk    => clk,
    s00_axi_aresetn => resetn,
    
    -- AXI4-Lite configuration
    s00_axi_awaddr  => (others => '0'),  -- Offset 0x0
    s00_axi_awvalid => '1' when writing_vec_len else '0',
    s00_axi_wdata   => std_logic_vector(to_unsigned(vec_len, 32)),
    s00_axi_wvalid  => '1' when writing_vec_len else '0',
    s00_axi_bready  => '1',
    
    -- AXI4-Stream weights
    axis_aclk       => clk,
    axis_aresetn    => resetn,
    s00_axis_tdata  => weight_data,
    s00_axis_tvalid => weight_valid,
    s00_axis_tlast  => weight_last,
    s00_axis_tready => weight_ready,
    
    -- AXI4-Stream output
    m00_axis_tdata  => result_data,
    m00_axis_tvalid => result_valid,
    m00_axis_tready => result_ready,
    
    -- BRAM
    addra           => bram_addr,
    douta           => activations,
    ena             => bram_enable,
    rsta            => bram_reset,
    dina            => (others => '0'),  -- Read-only port
    wea             => (others => '0')
);
```

### Write vec_len in Testbench

```vhdl
-- AXI4-Lite write: vec_len = 128
s00_axi_awvalid <= '1';
s00_axi_wvalid  <= '1';
s00_axi_wdata   <= std_logic_vector(to_unsigned(128, 32));
wait until rising_edge(clk);
wait until s00_axi_awready = '1';
wait until s00_axi_wready = '1';
s00_axi_awvalid <= '0';
s00_axi_wvalid  <= '0';
```

---

## Document Versions

| Date | Version | Changes |
|------|---------|---------|
| May 2026 | 1.0 | Initial quick reference created |
| May 2026 | 1.1 | Added TestBench_timing fixes |
| May 2026 | 1.2 | Expanded with Python test results |

---
