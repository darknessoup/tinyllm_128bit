import math
from time import time
from timer_cm import Timer

USE_PL = True

if USE_PL:
    for k, v in np_weights.items():
        if isinstance(v, np.ndarray) and v.dtype == np.int8:
            buf = allocate(v.shape, dtype=np.int8)
            np.copyto(buf, v)
            np_weights[k] = buf
    # 1-time Initialize PL Buffers
    ln1_q_a = allocate((1, 1, 768), dtype=np.int8)
    act_a = allocate((1, 1, 3072), dtype=np.int8)
    ln2_a = allocate((1, 1, 768), dtype=np.int8)
    final_hidden = allocate((1, 1, 768), dtype=np.int8)
    attn_out_a = allocate((1, 1, 768), dtype=np.int8)

    out_buf_768 = allocate((1, 768), dtype=np.int32)
    out_buf_2304 = allocate((1, 2304), dtype=np.int32)
    out_buf_3072 = allocate((1, 3072), dtype=np.int32)
    out_buf_50257 = allocate((1, 50257), dtype=np.int32)
else:
    ln1_q_a = np.ndarray((1, 1, 768), dtype=np.int8)
    act_a = np.ndarray((1, 1, 3072), dtype=np.int8)
    ln2_a = np.ndarray((1, 1, 768), dtype=np.int8)
    final_hidden = np.ndarray((1, 1, 768), dtype=np.int8)
    attn_out_a = np.ndarray((1, 1, 768), dtype=np.int8)

    out_buf_768 = np.ndarray((1, 768), dtype=np.int32)
    out_buf_2304 = np.ndarray((1, 2304), dtype=np.int32)
    out_buf_3072 = np.ndarray((1, 3072), dtype=np.int32)
    out_buf_50257 = np.ndarray((1, 50257), dtype=np.int32)
def softmax(x):
    x = x.astype(np.float32)
    e_x = np.exp(x - np.max(x, axis=-1, keepdims=True))
    return e_x / e_x.sum(axis=-1, keepdims=True)

def gelu(input):
    return 0.5 * input * (1.0 + np.tanh(math.sqrt(2.0 / math.pi) * (input + 0.044715 * np.power(input, 3.0))))

def ln(din, weight, bias):
    normed = (din - np.mean(din)) / np.std(din)
    return normed * weight + bias

def predict(token_id, idx, kv_cache=[], timing=False, return_probs=False):

    def quantize_activation_per_tensor_absmax(t, n_bits=8):
        scales = np.abs(t).max()
        q_max = 2**(n_bits-1)-1
        scales = scales.clip(min=1e-5) / q_max
        t = (t / scales).round() * (scales)
        return t
    
    with Timer('Main Loop', print_results=timing) as t:
        with t.child("Embedding"):
            embedding = np_weights["token_embedding"][token_id].view(np.ndarray) * np_weights["token_embedding_scale"]  + np_weights["pos_embedding"][idx]
            layer_in = embedding
            
        PL_matmul = ol.matmul_memory.matmul # Important!
    
        for i in range(4):
#             t_block = time()
            with t.child("QKV") as t_qkv:
                with t_qkv.child("Layernorm"):
                    ln1_q = ln(layer_in, np_weights[f"block_{i}_ln1_scale_w"], np_weights[f"block_{i}_ln1_scale_b"])
                    np.rint(ln1_q.clip(-127, 127), out=ln1_q_a, casting="unsafe")
                with t_qkv.child("Matmul"):
                    if not USE_PL:
                        m = np.matmul(ln1_q_a, np_weights[f"block_{i}_qkv_q"].T, dtype=np.float32)
                    else:
                        m = PL_matmul(ln1_q_a, np_weights[f"block_{i}_qkv_q"], out_buf_2304)#, timer=t)
                m = m.astype(np.float32)
                q, k, v = np.split(m, 3, axis=-1)
                q = q * np_weights[f"block_{i}_q_scale"]
                k = (k * np_weights[f"block_{i}_k_scale"]).round()
                v = (v * np_weights[f"block_{i}_v_scale"]).round()
                if len(kv_cache) > i:
                    k_past, v_past = kv_cache[i]
                    k_merged = np.concatenate([k_past, k.reshape((1, 16, 1, 48))], axis=2)
                    v_merged = np.concatenate([v_past, v.reshape((1, 16, 1, 48))], axis=2)
                    kv_cache[i] = (k_merged, v_merged)
                else:
                    k_merged = k.reshape((1, 16, 1, 48))
                    v_merged = v.reshape((1, 16, 1, 48))
                    kv_cache.append((k_merged, v_merged))
    #             t_qkv = time()
            
            with t.child("Attn") as t_attn:
                q = q.reshape((1, 16, 1, 48))
                q = q.clip(-127, 127).round().astype(np.int32)
                # print(q.shape, k_merged.shape)
                # ^ (1, 16, 1, 48) (1, 16, X, 48) ^ X increments every 4 run loop
                with t_attn.child("CPU Matmul"):
                    dot = np.matmul(q, k_merged.transpose((0, 1, 3, 2)), dtype=np.float32)
                #dot = ol.matmul_memory.matmul(q, k_merged.transpose((0, 1, 3, 2))).astype(np.float32)
                dot = dot * np_weights[f"block_{i}_qk_scale"]
                attn_weight = softmax(dot) * 127
                attn_weight = attn_weight.clip(-127, 127).round().astype(np.int32)
                with t_attn.child("CPU Matmul"):
                    attn_out = np.matmul(attn_weight, v_merged, dtype=np.float32).reshape((1, 1, 768))
                attn_out = attn_out * np_weights[f"block_{i}_attn_scale"]
            #print(attn_weight.shape, v_merged.shape)
            # ^ (1, 16, 1, X) (1, 16, X, 48) ^  X increments every 4 run loop
#             t_attn = time()
            with t.child("Attn Proj") as t_attn_proj:
                proj_w = np_weights[f"block_{i}_attn_proj_w_q"]
                proj_b = np_weights[f"block_{i}_attn_proj_b"]

                attn_out_a[:] = attn_out.clip(-127, 127).round().astype(np.int32)
                with t_attn_proj.child("Matmul"):
                    if not USE_PL:
                        attn_out = np.matmul(attn_out_a, proj_w.T, dtype=np.float32)
                    else:
                        attn_out = PL_matmul(attn_out_a, proj_w, out_buf_768)
                attn_out = attn_out.astype(np.float32)
                attn_out = attn_out * np_weights[f"block_{i}_attn_proj_w_scale"] + proj_b
#             t_proj = time()
                residual = layer_in + attn_out
            with t.child("Layernorm"):
                ln2 = ln(residual, np_weights[f"block_{i}_ln2_scale_w"], np_weights[f"block_{i}_ln2_scale_b"])
            
            with t.child("FC") as t_fc:
                fc_w = np_weights[f"block_{i}_fc_w_q"]
                fc_b = np_weights[f"block_{i}_fc_b"]

                np.rint(ln2.clip(-127, 127), out=ln2_a, casting="unsafe")
                with t_fc.child("Matmul"):
                    if not USE_PL:
                        fc = np.matmul(ln2_a, fc_w.T, dtype=np.float32)
                    else:
                        fc = PL_matmul(ln2_a, fc_w, out_buf_3072).astype(np.float32)
                fc = fc * np_weights[f"block_{i}_fc_w_scale"] + fc_b
                with t_fc.child("Activation"):
                    act = gelu(fc) * np_weights[f"block_{i}_fc_gelu_scale"]
            
            with t.child("Proj") as t_proj:
                np.rint(act.clip(-127, 127), out=act_a, casting="unsafe")
                proj_w = np_weights[f"block_{i}_proj_w_q"]
                proj_b = np_weights[f"block_{i}_proj_b"]
                
                with t_proj.child("Matmul"):
                    if not USE_PL:
                        proj = np.matmul(act_a, proj_w.T, dtype=np.float32)
                    else:
                        proj = PL_matmul(act_a, proj_w, out_buf_768).astype(np.float32)
                proj = proj * np_weights[f"block_{i}_proj_w_scale"] + proj_b
                layer_in = residual + proj
            t_fc = time()
        
        with t.child("Layernorm"):
            final_ln = ln(layer_in, np_weights[f"lnf_scale_w"], np_weights[f"lnf_scale_b"])
        # End of loop
        with t.child("Logits") as t_logit:
            np.rint(final_ln.clip(-127, 127), out=final_hidden, casting="unsafe")
            with t_logit.child("Matmul"):
                if not USE_PL:
                    logits = np.matmul(final_hidden, np_weights["token_embedding"].T, dtype=np.float32)
                else:
                    logits = PL_matmul(final_hidden, np_weights["token_embedding"], out_buf_50257).astype(np.float32)
            
            logits = logits * np_weights["lm_head_scale"]
        

        logits = logits.reshape((50257,))
        if return_probs:
            with t.child("Sampling") as t_s:
                with t_s.child("Filtering"):
                    logits = top_k_top_p_filtering(logits, top_p=0.7)
                with t_s.child("Softmax"):
                    probs = softmax(logits)
                return probs
        else:
            return logits
        

def generate_story(prompt="Once upon a", length=100):
    streamer = TextStreamer(tokenizer)
    tokens = tokenizer.encode(prompt).ids
    cache = []
    streamer.put(np.array(tokens))
    for i in range(len(tokens) - 1):
        predict(tokens[i], i, cache)
    for i in range(len(tokens) - 1, length):
        probs = predict(tokens[i], i, cache, timing=False, return_probs=True)
        #logits = top_k_top_p_filtering(logits, top_p=0.7)
        #probs = softmax(logits)
        newtok = np.random.choice(len(probs), p=probs)
        tokens.append(newtok)
        streamer.put(np.array([newtok]))
        if tokens[-1] == 50256:
            streamer.end()
            break
generate_story()