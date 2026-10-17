#!/usr/bin/env python3
"""
RoceOS Local AI Inference Server
基于 RKLLM Runtime 1.2.x + Flask，提供 OpenAI 兼容的 /v1/chat/completions API
运行在 RK3588 NPU 上
"""
import ctypes
import json
import os
import queue as _queue
import sys
import threading
from ctypes import (c_bool, c_char_p, c_float, c_int, c_int8, c_int32,
                    c_uint8, c_uint32, c_void_p, c_size_t, POINTER, Structure, Union)
from flask import Flask, request, Response, jsonify

# ─── 配置 ──────────────────────────────────────────────────────────────────────
LIB_PATH  = os.getenv("RKLLM_LIB",   "/opt/roceos-ai/librkllmrt.so")
MODEL_CFG = os.getenv("RKLLM_CONFIG", "/opt/roceos-ai/model.conf")
PORT      = int(os.getenv("RKLLM_PORT", "8686"))

# ─── RKLLM 1.2.x C 结构体（完全匹配 rkllm.h）─────────────────────────────────

class RKLLMExtendParam(Structure):
    _fields_ = [
        ("base_domain_id",   c_int32),
        ("embed_flash",      c_int8),
        ("enabled_cpus_num", c_int8),
        ("_pad1",            c_uint8 * 2),
        ("enabled_cpus_mask",c_uint32),
        ("n_batch",          c_uint8),
        ("use_cross_attn",   c_int8),
        ("reserved",         c_uint8 * 104),
    ]

class RKLLMParam(Structure):
    _fields_ = [
        ("model_path",        c_char_p),
        ("max_context_len",   c_int32),
        ("max_new_tokens",    c_int32),
        ("top_k",             c_int32),
        ("n_keep",            c_int32),
        ("top_p",             c_float),
        ("temperature",       c_float),
        ("repeat_penalty",    c_float),
        ("frequency_penalty", c_float),
        ("presence_penalty",  c_float),
        ("mirostat",          c_int32),
        ("mirostat_tau",      c_float),
        ("mirostat_eta",      c_float),
        ("skip_special_token",c_bool),
        ("is_async",          c_bool),
        ("_pad",              c_uint8 * 6),
        ("img_start",         c_char_p),
        ("img_end",           c_char_p),
        ("img_content",       c_char_p),
        ("extend_param",      RKLLMExtendParam),
    ]

class RKLLMEmbedInput(Structure):
    _fields_ = [
        ("embed",    POINTER(c_float)),
        ("n_tokens", c_size_t),
    ]

class RKLLMTokenInput(Structure):
    _fields_ = [
        ("input_ids", POINTER(c_int32)),
        ("n_tokens",  c_size_t),
    ]

class RKLLMMultiModalInput(Structure):
    _fields_ = [
        ("prompt",        c_char_p),
        ("image_embed",   POINTER(c_float)),
        ("n_image_tokens",c_size_t),
        ("n_image",       c_size_t),
        ("image_width",   c_size_t),
        ("image_height",  c_size_t),
    ]

class RKLLMInputUnion(Union):
    _fields_ = [
        ("prompt_input",     c_char_p),
        ("embed_input",      RKLLMEmbedInput),
        ("token_input",      RKLLMTokenInput),
        ("multimodal_input", RKLLMMultiModalInput),
    ]

class RKLLMInput(Structure):
    _fields_ = [
        ("role",           c_char_p),
        ("enable_thinking",c_bool),
        ("_pad",           c_uint8 * 3),
        ("input_type",     c_int),
        ("input_data",     RKLLMInputUnion),
    ]

class RKLLMLoraParam(Structure):
    _fields_ = [("lora_adapter_name", c_char_p)]

class RKLLMPromptCacheParam(Structure):
    _fields_ = [
        ("save_prompt_cache", c_int),
        ("prompt_cache_path", c_char_p),
    ]

class RKLLMInferParam(Structure):
    _fields_ = [
        ("mode",               c_int),
        ("_pad",               c_uint8 * 4),
        ("lora_params",        POINTER(RKLLMLoraParam)),
        ("prompt_cache_params",POINTER(RKLLMPromptCacheParam)),
        ("keep_history",       c_int),
    ]

class RKLLMResultLastHiddenLayer(Structure):
    _fields_ = [
        ("hidden_states", POINTER(c_float)),
        ("embd_size",     c_int),
        ("num_tokens",    c_int),
    ]

class RKLLMResultLogits(Structure):
    _fields_ = [
        ("logits",     POINTER(c_float)),
        ("vocab_size", c_int),
        ("num_tokens", c_int),
    ]

class RKLLMPerfStat(Structure):
    _fields_ = [
        ("prefill_time_ms",  c_float),
        ("prefill_tokens",   c_int),
        ("generate_time_ms", c_float),
        ("generate_tokens",  c_int),
        ("memory_usage_mb",  c_float),
    ]

class RKLLMResult(Structure):
    _fields_ = [
        ("text",              c_char_p),
        ("token_id",          c_int32),
        ("last_hidden_layer", RKLLMResultLastHiddenLayer),
        ("logits",            RKLLMResultLogits),
        ("perf",              RKLLMPerfStat),
    ]

CALLBACK_TYPE = ctypes.CFUNCTYPE(c_int, POINTER(RKLLMResult), c_void_p, c_int)

# ─── 全局状态 ──────────────────────────────────────────────────────────────────
lib        = None
handle     = c_void_p(None)
model_lock = threading.Lock()
model_path = ""

# ─── 永久全局回调（解决 SIGILL 崩溃的核心修复）────────────────────────────────
#
# 问题根因：原代码在 load_model() 里创建 dummy_cb 局部变量传给 rkllm_init。
# 函数返回后 dummy_cb 引用计数归零，CPython 立即回收，RKLLM runtime 持有的
# 函数指针变成悬空指针。每次推理调用该指针 → SIGILL/SIGBUS。
#
# 修复方案：在模块级创建唯一的永久回调对象 _RKLLM_CB，传给 rkllm_init，
# 它永远存活。每次推理前将当前请求的处理函数赋给 _active_handler，
# model_lock 保证同一时刻只有一个推理任务。
_active_handler = None   # 当前推理请求的 Python 处理函数（model_lock 保护）

def _global_rkllm_callback(result_ptr, userdata, state):
    """模块级永久回调，由 rkllm_init 注册，永不被 GC 回收，分发到当前请求处理函数"""
    fn = _active_handler
    if fn is not None:
        try:
            return fn(result_ptr, userdata, state)
        except Exception:
            pass
    return 0

# 创建一次，永久存活于模块级，指针永远有效
_RKLLM_CB = CALLBACK_TYPE(_global_rkllm_callback)

# ─── 加载库并初始化模型 ────────────────────────────────────────────────────────
def load_model(path: str):
    global lib, handle

    lib = ctypes.CDLL(LIB_PATH)

    lib.rkllm_createDefaultParam.restype  = RKLLMParam
    lib.rkllm_createDefaultParam.argtypes = []
    lib.rkllm_init.argtypes   = [POINTER(c_void_p), POINTER(RKLLMParam), CALLBACK_TYPE]
    lib.rkllm_init.restype    = c_int
    lib.rkllm_run.argtypes    = [c_void_p, POINTER(RKLLMInput), POINTER(RKLLMInferParam), c_void_p]
    lib.rkllm_run.restype     = c_int
    lib.rkllm_abort.argtypes  = [c_void_p]
    lib.rkllm_abort.restype   = c_int
    lib.rkllm_destroy.argtypes= [c_void_p]
    lib.rkllm_destroy.restype = c_int

    param = lib.rkllm_createDefaultParam()
    param.model_path                    = path.encode()
    param.max_context_len               = 4096
    param.max_new_tokens                = 1024  # 合理默认上限，可被请求参数覆盖
    param.top_k                         = 1
    param.top_p                         = 0.9
    param.temperature                   = 0.8
    param.repeat_penalty                = 1.1
    param.skip_special_token            = True
    param.is_async                      = False
    param.extend_param.base_domain_id   = 0
    param.extend_param.n_batch          = 1

    h = c_void_p(None)
    # 传入永久全局回调，不再使用会被 GC 回收的局部 dummy_cb
    ret = lib.rkllm_init(ctypes.byref(h), ctypes.byref(param), _RKLLM_CB)
    if ret != 0:
        raise RuntimeError(f"rkllm_init 失败, ret={ret}")
    handle = h
    print(f"[roceos-ai] 模型加载完成: {path}", flush=True)

# ─── Flask 应用 ────────────────────────────────────────────────────────────────
app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status": "ok", "model_loaded": bool(handle.value)})

@app.route("/v1/abort", methods=["POST"])
def abort_inference():
    """中断当前正在进行的推理"""
    if lib and handle.value:
        try:
            lib.rkllm_abort(handle)
            return jsonify({"status": "ok", "message": "推理已中断"})
        except Exception as e:
            return jsonify({"status": "error", "message": str(e)}), 500
    return jsonify({"status": "ok", "message": "无推理任务"})

def _detect_model_family(path: str) -> str:
    name = os.path.basename(path).lower()
    if "qwen" in name:
        return "qwen"
    return "gemma"

def _build_prompt(messages: list, family: str) -> str:
    prompt = ""
    if family == "qwen":
        for m in messages:
            role    = m.get("role", "user")
            content = m.get("content", "")
            if role == "system":
                prompt += f"<|im_start|>system\n{content}<|im_end|>\n"
            elif role == "user":
                prompt += f"<|im_start|>user\n{content}<|im_end|>\n"
            elif role == "assistant":
                prompt += f"<|im_start|>assistant\n{content}<|im_end|>\n"
        prompt += "<|im_start|>assistant\n"
    else:
        for m in messages:
            role    = m.get("role", "user")
            content = m.get("content", "")
            if role == "system":
                prompt += f"<start_of_turn>system\n{content}<end_of_turn>\n"
            elif role == "user":
                prompt += f"<start_of_turn>user\n{content}<end_of_turn>\n"
            elif role == "assistant":
                prompt += f"<start_of_turn>model\n{content}<end_of_turn>\n"
        prompt += "<start_of_turn>model\n"
    return prompt

@app.route("/v1/chat/completions", methods=["POST"])
def chat_completions():
    data      = request.get_json(force=True)
    messages  = data.get("messages", [])
    stream    = data.get("stream", True)
    max_tokens = int(data.get("max_tokens", 1024))  # 默认 1024，防止无限生成

    family = _detect_model_family(model_path)
    prompt = _build_prompt(messages, family)

    if stream:
        resp = Response(_stream_generate(prompt, max_tokens), content_type="text/event-stream")
        resp.headers['X-Accel-Buffering'] = 'no'
        resp.headers['Cache-Control'] = 'no-cache'
        return resp
    else:
        result = _blocking_generate(prompt, max_tokens)
        return jsonify({
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "choices": [{"index": 0,
                         "message": {"role": "assistant", "content": result},
                         "finish_reason": "stop"}]
        })

def _make_input(prompt_bytes: bytes) -> RKLLMInput:
    inp = RKLLMInput()
    inp.role            = None
    inp.enable_thinking = False
    inp.input_type      = 0
    inp.input_data.prompt_input = prompt_bytes
    return inp

def _make_infer_param() -> RKLLMInferParam:
    p = RKLLMInferParam()
    p.mode                 = 0
    p.lora_params          = None
    p.prompt_cache_params  = None
    p.keep_history         = 0
    return p

def _stream_generate(prompt: str, max_tokens: int = 1024):
    global _active_handler

    q = _queue.SimpleQueue()
    prompt_bytes = prompt.encode()
    token_count = 0

    def handler(result_ptr, userdata, state):
        nonlocal token_count
        if result_ptr and result_ptr.contents.text:
            try:
                text = result_ptr.contents.text.decode("utf-8", errors="replace")
                if text:
                    token_count += 1
                    q.put(('token', text))
                    # 超出 max_tokens 时主动 abort
                    if token_count >= max_tokens and lib and handle.value:
                        lib.rkllm_abort(handle)
            except Exception:
                pass
        if state == 2:    # RKLLM_RUN_FINISH
            q.put(('done', None))
        elif state == 3:  # RKLLM_RUN_ERROR
            q.put(('error', '推理出错'))
            q.put(('done', None))
        return 0

    def run_inference():
        global _active_handler
        inp       = _make_input(prompt_bytes)
        inf_param = _make_infer_param()
        with model_lock:
            _active_handler = handler
            try:
                lib.rkllm_run(handle, ctypes.byref(inp), ctypes.byref(inf_param), None)
            finally:
                _active_handler = None
        q.put(('done', None))

    t = threading.Thread(target=run_inference, daemon=True)
    t.start()

    while True:
        try:
            kind, val = q.get(timeout=120)
        except _queue.Empty:
            break
        if kind == 'token':
            chunk = {
                "id": "chatcmpl-local",
                "object": "chat.completion.chunk",
                "choices": [{"index": 0,
                              "delta": {"content": val},
                              "finish_reason": None}]
            }
            yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"
        elif kind == 'error':
            yield f"data: {{\"error\": \"{val}\"}}\n\n"
        elif kind == 'done':
            break

    yield "data: [DONE]\n\n"

def _blocking_generate(prompt: str, max_tokens: int = 1024) -> str:
    global _active_handler

    result      = []
    done_event  = threading.Event()
    prompt_bytes = prompt.encode()
    token_count = 0

    def handler(result_ptr, userdata, state):
        nonlocal token_count
        if result_ptr and result_ptr.contents.text:
            try:
                text = result_ptr.contents.text.decode("utf-8", errors="replace")
                if text:
                    token_count += 1
                    result.append(text)
                    if token_count >= max_tokens and lib and handle.value:
                        lib.rkllm_abort(handle)
            except Exception:
                pass
        if state >= 2:
            done_event.set()
        return 0

    def run_inference():
        global _active_handler
        inp       = _make_input(prompt_bytes)
        inf_param = _make_infer_param()
        with model_lock:
            _active_handler = handler
            try:
                lib.rkllm_run(handle, ctypes.byref(inp), ctypes.byref(inf_param), None)
            finally:
                _active_handler = None

    t = threading.Thread(target=run_inference, daemon=True)
    t.start()
    done_event.wait(timeout=120)
    return "".join(result)

# ─── 入口 ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if not os.path.exists(LIB_PATH):
        print(f"[roceos-ai] 错误: 找不到 {LIB_PATH}", file=sys.stderr)
        sys.exit(1)

    if os.path.exists(MODEL_CFG):
        with open(MODEL_CFG) as f:
            model_path = f.read().strip()

    if not model_path or not os.path.exists(model_path):
        print(f"[roceos-ai] 错误: 模型文件不存在: {model_path}", file=sys.stderr)
        # 3 对应 unit 中的 RestartPreventExitStatus，避免没有模型时被 systemd 无限重启
        sys.exit(3)

    load_model(model_path)
    print(f"[roceos-ai] 推理服务启动, 监听 0.0.0.0:{PORT}", flush=True)
    app.run(host="0.0.0.0", port=PORT, threaded=True)
