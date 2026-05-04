from pynq import Overlay, allocate, DefaultIP, MMIO, Device, DefaultHierarchy
from pynq_cdma import CDMA
from time import time
from contextlib import nullcontext
import numpy as np
from timer_cm import Timer
# Now for benchmarks
size_vec_in = 768
size_vec_out = 3072
vec_buf = allocate(shape=(size_vec_in,), dtype=np.int8)
weight_buf = allocate(shape=(size_vec_out, size_vec_in), dtype=np.int8)
out_buf = allocate(shape=(size_vec_out,), dtype=np.int32)
np.copyto(vec_buf, np.random.randint(-127, high=127, size=(size_vec_in), dtype=np.int8))
np.copyto(weight_buf, np.random.randint(-127, high=127, size=(size_vec_out, size_vec_in), dtype=np.int8))
#
# output 
# [-93  80  57   8  14  -1 -26 -40] [[ -76  -26  113  -87 -105    1  -29  -32]
#[ -38  -13   -5   34   60  -83  -62  -39]
#[ -40   42  114   90   78  125   88 -121]
#[-103   14  -99  -45 -119   40   -2  -84]
#[ -40   37  -53   -5  -90  -31  -83   46]
#[  40   49  124   37   56  -77 -123   45]
#[  13  -15 -100  -72   -7    9   48  -45]
#[  45  -77  -31  -63   20  -49    5   47]]
PL_matmul = overlay.matmul_memory.matmul # Important!
#PL_matmul_1 = overlay.matmul_memory1.matmul
with Timer('Full', print_results=True) as t:
    with t.child("matmul") as t_mat:
        PL_matmul(vec_buf, weight_buf, out_buf, timer=t)
print(out_buf[:])

#(3072, 768) -> out_buffer size. So we're outputting a 3072 element array. And each element should take the 
#Full: 0.060s
#  matmul: 0.060s (99%)
#  Matmul Inner: 0.060s (99%)
#  CDMA: 0.052s (87%)
#  DMA: 0.004s (6%)
#[-14217047         0         0 ...         0         0         0]