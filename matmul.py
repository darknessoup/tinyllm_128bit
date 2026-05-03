from pynq import Overlay, allocate, DefaultIP, MMIO, Device, DefaultHierarchy
from pynq_cdma import CDMA
from time import time
from contextlib import nullcontext
import numpy as np

class MatmulIP(DefaultIP):
    def __init__(self, description):
        super().__init__(description=description)
        
    bindto = ['xilinx.com:user:matmul:1.0']

    @property
    def vec_len(self):
        return self.read(0x0)

    @vec_len.setter
    def vec_len(self, value):
        self.write(0x0, value)
        
        
class StreamMatmulDriver(DefaultHierarchy):
        
    def __init__(self, description):
        super().__init__(description)
    
    def matmul(self, vec_buf, mat_buf, out_buf, timer=None): 
        # mat_buf is of size (output_dim, input_dim)
        cdma_cm = timer.child("CDMA") if timer is not None else nullcontext()
        dma_cm = timer.child("DMA") if timer is not None else nullcontext()
        cm = timer.child("Matmul Inner") if timer is not None else nullcontext()
        with cm:
            size = vec_buf.shape[-1]
            depth = mat_buf.shape[0]
            assert size == mat_buf.shape[-1], f"Invalid matrix dimensions {size} vs {mat_buf.shape[-1]}"
            assert depth == out_buf.shape[-1], f"Output buffer incorrect size {depth} vs {out_buf.shape[-1]}"
            self.matmul_0.vec_len = size

            with cdma_cm:
                self.axi_cdma_0.transfer(vec_buf, 0xC000_0000)

            with dma_cm:
                # Arm the receive channel BEFORE sending so backpressure
                # never stalls the pipeline and the channel is always ready
                # when the first result word arrives.
                self.axi_dma.recvchannel.transfer(out_buf)
                self.axi_dma.sendchannel.transfer(mat_buf)
                # Always wait: without this the channel stays non-idle on
                # the next call, raising "DMA channel not idle".
                self.axi_dma.recvchannel.wait()

        return out_buf
        
    @staticmethod
    def checkhierarchy(description):
        if 'axi_dma' in description['ip'] \
           and 'axi_cdma_0' in description['ip'] \
           and 'matmul_0' in description['ip']:
            return True
        return False