import math
from time import time

USE_PL = True

def predict(token_id, idx, kv_cache, timing=False):
    def ln(din, weight, bias):
        normed = (din - np.mean(din)) / np.std(din)
        return normed * weight + bias

    def softmax(x):
        e_x = np.exp(x - np.max(x, axis=-1, keepdims=True))
        return e_x / e_x.sum(axis=-1, keepdims=True)

    def gelu(input):
        return 0.5 * input * (1.0 + np.tanh(math.sqrt(2.0 / math.pi) * (input + 0.044715 * np.power(input, 3.0))))

    def quantize_activation_per_tensor_absmax(t, n_bits=8):
        scales = np.abs(t).max()
        q_max = 2**(n_bits-1)-1
        scales = scales.clip(min=1e-5) / q_max
        t = (t / scales).round() * (scales)
        return t
    
    t_start = time()
    embedding = np_weights["token_embedding"][token_id].view(np.ndarray) * np_weights["token_embedding_scale"]  + np_weights["pos_embedding"][idx]
    t_embed = time()
    # print(embedding.min(), embedding.max())
    layer_in = embedding
    for i in range(4):
        t_block = time()
        ln1_q = ln(layer_in, np_weights[f"block_{i}_ln1_scale_w"], np_weights[f"block_{i}_ln1_scale_b"])
        n = time()
        #print(n - t_block)
#         ln1_q = ln1_q.clip(-127, 127).round().astype(np.int32)
        np.rint(ln1_q.clip(-127, 127), out=ln1_q_a, casting="unsafe")
        p = time()
        #print(p - n)
        # below is the long one
        #print(ln1_q.shape, np_weights[f"block_{i}_qkv_q"].T.shape)
        if not USE_PL:
            m = np.matmul(ln1_q_a, np_weights[f"block_{i}_qkv_q"].T, dtype=np.float32)
        else:
#             ln1_q_a[:] = ln1_q
#             qkv_a[:] = np_weights[f"block_{i}_qkv_q"]
            m = ol.matmul_memory.matmul(ln1_q_a, np_weights[f"block_{i}_qkv_q"], out_buf_2304).astype(np.float32)

        t = time()
        #print(t-p)
        q, k, v = np.split(m, 3, axis=-1)
        n = time()
        #print(n - t)
        q = q * np_weights[f"block_{i}_q_scale"]
        k = k * np_weights[f"block_{i}_k_scale"]
        v = v * np_weights[f"block_{i}_v_scale"]
        p = time()
        #print(p - n)
        k_cache, v_cache = kv_cache
#         print(k.min(), k.max(), v.min(), v.max())
        np.rint(k.clip(-127, 127).reshape(1, 16, 48), out=k_cache[:, :, i, :], casting="unsafe")
        np.rint(v.clip(-127, 127).reshape(1, 16, 48), out=v_cache[:, :, i, :], casting="unsafe")
        
        k_slice = k_cache[:, :, :i+1, :]
        v_slice = v_cache[:, :, :i+1, :]
        
        if i == 0:
            print(k, k_slice)
#         if len(kv_cache) > i:
#             k_past, v_past = kv_cache[i]
#             k_merged = np.concatenate([k_past, k.reshape((1, 16, 1, 48))], axis=2)
#             v_merged = np.concatenate([v_past, v.reshape((1, 16, 1, 48))], axis=2)
#             kv_cache[i] = (k_merged, v_merged)
#         else:
#             k_merged = k.reshape((1, 16, 1, 48))
#             v_merged = v.reshape((1, 16, 1, 48))
#             kv_cache.append((k_merged, v_merged))
        t_qkv = time()
        #print(t_qkv - p)

        q = q.reshape((1, 16, 1, 48))
        q = q.clip(-127, 127).round().astype(np.int32)
        # print(q.shape, k_merged.shape)
        # ^ (1, 16, 1, 48) (1, 16, X, 48) ^ X increments every 4 run loop
        dot = np.matmul(q, k_slice.transpose((0, 1, 3, 2)), dtype=np.float32)
        #dot = ol.matmul_memory.matmul(q, k_merged.transpose((0, 1, 3, 2))).astype(np.float32)
        dot = dot * np_weights[f"block_{i}_qk_scale"]
        attn_weight = softmax(dot) * 127
        attn_weight = attn_weight.clip(-127, 127).round().astype(np.int32)
        attn_out = np.matmul(attn_weight, v_slice, dtype=np.float32).reshape((1, 1, 768)) * np_weights[f"block_{i}_attn_scale"]
        #print(attn_weight.shape, v_merged.shape)
        # ^ (1, 16, 1, X) (1, 16, X, 48) ^  X increments every 4 run loop
        #attn_out = ol.matmul_memory.matmul(attn_weight, v_merged).astype(np.float32).reshape((1, 1, 768)) * np_weights[f"block_{i}_attn_scale"]
        t_attn = time()

        proj_w = np_weights[f"block_{i}_attn_proj_w_q"]
        proj_b = np_weights[f"block_{i}_attn_proj_b"]

        attn_out = attn_out.clip(-127, 127).round().astype(np.int32)
        if USE_PL:
            attn_out = np.matmul(attn_out, proj_w.T, dtype=np.float32) * np_weights[f"block_{i}_attn_proj_w_scale"] + proj_b
        else:
            attn_out = ol.matmul(attn_out, proj_w, dtype=np.float32) * np_weights[f"block_{i}_attn_proj_w_scale"] + proj_b            
        
        t_proj = time()
        residual = layer_in + attn_out
        ln2 = ln(residual, np_weights[f"block_{i}_ln2_scale_w"], np_weights[f"block_{i}_ln2_scale_b"])
        fc_w = np_weights[f"block_{i}_fc_w_q"]
        fc_b = np_weights[f"block_{i}_fc_b"]

#         ln2 = ln2.clip(-127, 127).round().astype(np.int32)
        np.rint(ln2.clip(-127, 127), out=ln2_a, casting="unsafe")
        #start = time()
        #print(ln2.shape, fc_w.shape)
        if not USE_PL:
            fc = np.matmul(ln2_a, fc_w.T, dtype=np.float32) * np_weights[f"block_{i}_fc_w_scale"] + fc_b
        else:
#             ln2_a[:] = ln2
#             fc_w_a[:] = fc_w
            fc = ol.matmul_memory.matmul(ln2_a, fc_w, out_buf_3072).astype(np.float32) * np_weights[f"block_{i}_fc_w_scale"] + fc_b
        #print(time() - start)
        act = gelu(fc) * np_weights[f"block_{i}_fc_gelu_scale"]

        np.rint(act.clip(-127, 127), out=act_a, casting="unsafe")
        proj_w = np_weights[f"block_{i}_proj_w_q"]
        proj_b = np_weights[f"block_{i}_proj_b"]
        
        #start = time()
        if not USE_PL:
            proj = np.matmul(act_a, proj_w.T, dtype=np.float32) * np_weights[f"block_{i}_proj_w_scale"] + proj_b
        else:
#             act_a[:] = act #np.rint(act.clip(-127, 127), out=act_a, casting="unsafe")
#             proj_w_a[:] = proj_w #np.rint(proj_w.clip(-127, 127), out=proj_w_a, casting="unsafe")
            proj = ol.matmul_memory.matmul(act_a, proj_w, out_buf_768).astype(np.float32) * np_weights[f"block_{i}_proj_w_scale"] + proj_b
        #print(time() - start)
        layer_in = residual + proj
        t_fc = time()
    
    final_ln = ln(layer_in, np_weights[f"lnf_scale_w"], np_weights[f"lnf_scale_b"])
    # print(final_ln.min(), final_ln.max())
    #print(final_ln.shape, np_weights["token_embedding"].shape)
    if not USE_PL:
        logits = np.matmul(final_ln, np_weights["token_embedding"].T, dtype=np.float32)
    else:
        np.rint(final_ln.clip(-127, 127), out=final_hidden, casting="unsafe")
        logits = ol.matmul_memory.matmul(final_hidden, np_weights["token_embedding"], out_buf_50257).astype(np.float32)

    probs = softmax(logits)
    t_lm = time()

    if timing:
        print(f"Embedding: {t_embed - t_start}")
        print(f"QKV: {t_qkv - t_block}, total: {4*(t_qkv - t_block)}")
        print(f"Attn: {t_attn - t_qkv}, total: {4*(t_attn - t_qkv)}")
        print(f"Proj: {t_proj - t_attn}, total: {4*(t_proj - t_attn)}")
        print(f"FC: {t_fc - t_proj}, total: {4*(t_fc - t_proj)}")
        print(f"LM: {t_lm - t_fc}")
        print(f"Full: {t_lm - t_start}")
    return probs