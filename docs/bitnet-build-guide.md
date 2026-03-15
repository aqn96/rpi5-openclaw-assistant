# BitNet b1.58 on Raspberry Pi 5 — Local LLM Build Guide

> A step-by-step guide to building and running Microsoft's BitNet 1.58-bit LLM on a Raspberry Pi 5, serving it as an OpenAI-compatible API, and connecting it to OpenClaw.

**Author:** Andrew Nguyen (@aqn96)  
**Date:** March 15, 2026  
**Hardware:** Raspberry Pi 5 (8GB RAM)  
**Performance:** 9.68 tokens/second (4 threads)  
**RAM Usage:** ~1.3GB (model + KV cache)  

---

## Why BitNet?

BitNet b1.58 uses ternary weights ({-1, 0, +1}) instead of the 4-bit or 16-bit weights used by traditional LLMs. The result is a model that uses dramatically less RAM and runs faster on CPUs — ideal for always-on deployment on a Raspberry Pi.

| Metric | Ollama Llama 3.2 3B (old) | BitNet 2.4B (new) |
|--------|--------------------------|-------------------|
| RAM | ~2GB | ~1.3GB |
| Model size on disk | ~2GB | ~1.1GB |
| Speed | 12-15 tok/s | 9.68 tok/s |
| Quantization | Q4_K_M (4-bit) | I2_S (1.58-bit) |
| API | Ollama | llama-server (OpenAI-compatible) |

The 2.4B model is not as smart as the 70B cloud models (Groq, Gemini), but it's always available, has zero rate limits, uses no API quota, and keeps data local. It serves as the default backbone, with cloud models available on-demand for complex tasks.

---

## Prerequisites

- Raspberry Pi 5 (8GB RAM) running Raspberry Pi OS 64-bit (Debian 12 Bookworm)
- Internet connection for downloading packages and model
- ~5GB free disk space

---

## Build Steps

### 1. Install System Dependencies

```bash
sudo apt update
sudo apt install -y cmake git build-essential wget software-properties-common
```

### 2. Install Clang 18

Bookworm ships clang 14, but BitNet requires 18+.

```bash
wget https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 18

sudo update-alternatives --install /usr/bin/clang clang /usr/bin/clang-18 100
sudo update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-18 100
```

### 3. Install Conda (Miniforge)

Standard Anaconda doesn't support ARM64. Miniforge does.

```bash
wget https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-aarch64.sh
bash Miniforge3-Linux-aarch64.sh
source ~/.bashrc
```

### 4. Clone & Build BitNet

```bash
conda create -n bitnet-cpp python=3.9 -y
conda activate bitnet-cpp

cd ~
git clone --recursive https://github.com/microsoft/BitNet.git
cd BitNet
pip install -r requirements.txt

# CRITICAL: Pin to last working ARM commit (see Troubleshooting section)
git checkout 404980e
git submodule update --init --recursive

# Generate LUT kernel headers
python utils/codegen_tl1.py \
  --model bitnet_b1_58-3B \
  --BM 160,320,320 \
  --BK 64,128,64 \
  --bm 32,64,32

# Build with clang (must be explicit)
export CC=clang-18 CXX=clang++-18
rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
cd ..
```

Build takes ~3-4 minutes on Pi 5. Warnings during compilation are normal.

### 5. Download Model & Test

```bash
huggingface-cli download microsoft/BitNet-b1.58-2B-4T-gguf \
  --local-dir models/BitNet-b1.58-2B-4T

python run_inference.py \
  -m models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf \
  -p "You are a helpful assistant" \
  -t 4 -cnv
```

You should see coherent responses. Ctrl+C to exit.

### 6. Set Up Persistent Server

Create a systemd user service so the server runs 24/7:

```bash
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/bitnet-server.service << 'EOF'
[Unit]
Description=BitNet llama-server (OpenAI-compatible API)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/BitNet
ExecStart=%h/BitNet/build/bin/llama-server \
  -m %h/BitNet/models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  -t 4 \
  -c 2048 \
  -ngl 0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable bitnet-server.service
systemctl --user start bitnet-server.service
```

Verify: `curl http://127.0.0.1:8080/v1/models`

The server exposes an OpenAI-compatible API at `http://127.0.0.1:8080/v1`, supporting `/v1/chat/completions`, `/v1/completions`, and `/v1/models`.

---

## Service Management

| Command | Purpose |
|---------|---------|
| `systemctl --user status bitnet-server` | Check server status |
| `systemctl --user restart bitnet-server` | Restart after changes |
| `systemctl --user stop bitnet-server` | Stop to free RAM |
| `curl http://127.0.0.1:8080/v1/models` | Verify API is live |
| `journalctl --user -u bitnet-server -f` | Live server logs |

---

## Troubleshooting

### ARM Regression — Gibberish Output (CRITICAL)

**Commits after `112f853` (January 2026 CPU Optimization update) produce garbage output on all ARM platforms.** This affects Raspberry Pi 4, Pi 5, Ampere Altra, and other aarch64 hardware.

The regression was introduced in the parallel I2S kernel implementation. Multiple bugs were identified by the community including an int16 overflow in the NEON fallback path and a type signature mismatch in the `to_float` callback.

**Fix:** Pin to commit `404980e` (last known working ARM commit).

Tracked in:
- [#411 — Garbage output on ARMv8.0](https://github.com/microsoft/BitNet/issues/411)
- [#468 — UB in to_float callback for I2_S](https://github.com/microsoft/BitNet/issues/468)
- [#470 — ARM I2_S inference gibberish after commit 112f853](https://github.com/microsoft/BitNet/issues/470)

### Build Completes Instantly (No Compilation)

If `setup_env.py` finishes in seconds, it's skipping compilation. The script redirects all output to `logs/`. Check `logs/compile.log` for details. The manual build process (Step 4 above) avoids this entirely.

### Tokenizer Warning — "GENERATION QUALITY WILL BE DEGRADED"

The pre-built GGUF from Hugging Face is missing the `tokenizer.ggml.pre` metadata field. On the working commit (`404980e`), this does not affect output quality. If you encounter it, you can suppress it with:

```bash
--override-kv tokenizer.ggml.pre=str:llama-bpe
```

### OOM Kill During Model Conversion

If you try to convert from the bf16 source weights (`microsoft/bitnet-b1.58-2B-4T-bf16`), the preprocessing script requires ~12GB RAM. On Pi 5 (8GB), this requires creating a swap file:

```bash
sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

Even with 8GB swap, the script may still OOM. Use the pre-built GGUF from `microsoft/BitNet-b1.58-2B-4T-gguf` instead.

### Must Use Clang, Not GCC

BitNet's ARM kernels require clang for correct compilation. Always set `export CC=clang-18 CXX=clang++-18` before building. If cmake uses gcc, the binary will build but produce incorrect output.

---

## Learnings

### 1. Compilation Is Hardware-Specific for a Reason
BitNet's speed comes from kernels hand-tuned for specific CPU instruction sets (ARM NEON, x86 AVX2). The compilation step generates machine code optimized for your exact CPU — that's why you build on the Pi itself rather than cross-compiling. Without the correct kernels, the binary runs but produces mathematical garbage.

### 2. "It Compiles" Doesn't Mean "It Works"
We spent significant time debugging gibberish output from a binary that compiled without errors. The build succeeded, the model loaded, tensors were correct — but the computation was wrong. Runtime correctness requires the right kernels for your hardware, not just a successful build.

### 3. Bisection Is Your Best Debugging Tool
When something breaks, `git checkout` to an older known-good commit. If it works, the bug is in the newer code. Binary search through commits narrows it to the exact change. This is how we identified commit `112f853` as the regression point — it would have taken much longer to debug the kernel code directly.

### 4. Open Source Contribution Starts With Good Bug Reports
Filing [#470](https://github.com/microsoft/BitNet/issues/470) and commenting on [#411](https://github.com/microsoft/BitNet/issues/411) with bisection data was a meaningful contribution. A well-structured bug report with reproduction steps, environment details, and commit boundaries is more useful than a vague "it doesn't work" — and it helps maintainers and other users find fixes faster.

### 5. Swap Is Emergency Overflow, Not a Substitute for RAM
Creating a swap file on an SD card lets the OS overflow RAM to disk, preventing OOM kills. But SD card I/O is ~100x slower than RAM, so processes that rely heavily on swap will crawl or still fail. For memory-intensive one-time tasks (like model conversion), it's a useful hack. For runtime inference, the model must fit in real RAM.

### 6. The Pre-Built Binary Isn't Always the Right One
The pre-built GGUF from Hugging Face had correct weights but an incomplete tokenizer. The `setup_env.py` script hid compilation output in log files, masking potential issues. Going through the manual build process and testing each step independently was what ultimately got everything working.

---

## Architecture After Integration

```
┌─────────────────────────────────────────────────────────────┐
│                RASPBERRY PI 5 (Primary Site)                │
│                                                             │
│   ┌──────────────────────────────────────────┐              │
│   │      OpenClaw Gateway (:18789)           │              │
│   └──────┬────────┬────────┬─────────────────┘              │
│          │        │        │                                │
│          ▼        ▼        ▼                                │
│   ┌──────────┐ ┌────────┐ ┌──────────────┐                 │
│   │ BitNet   │ │ Groq   │ │ Gemini       │                 │
│   │ (LOCAL)  │ │(CLOUD) │ │ (WEB SEARCH) │                 │
│   │          │ │        │ │              │                  │
│   │ 2.4B     │ │ 70B    │ │ 2.5 Flash    │                 │
│   │ 1.58-bit │ │ Free   │ │ 20 req/day   │                 │
│   │ :8080    │ │ ~30RPM │ │ Grounding    │                 │
│   │ DEFAULT  │ │ /groq  │ │ /gemini      │                 │
│   └──────────┘ └────────┘ └──────────────┘                 │
│                                                             │
│   Fallback: Groq → Gemini → OpenRouter (free)              │
│                                                             │
│   Background Services:                                      │
│   tailscaled, fail2ban, openclaw-gateway, bitnet-server     │
└─────────────────────────────────────────────────────────────┘
```

---

## References

- [Microsoft BitNet Repository](https://github.com/microsoft/BitNet)
- [Adafruit BitNet on Raspberry Pi Guide](https://learn.adafruit.com/local-llms-on-raspberry-pi/bitnet)
- [BitNet b1.58 2B4T on Hugging Face](https://huggingface.co/microsoft/bitnet-b1.58-2B-4T)
- [BitNet b1.58 Technical Report](https://arxiv.org/abs/2402.17764)
- [ARM Regression Bug #411](https://github.com/microsoft/BitNet/issues/411)
- [Our Bug Report #470](https://github.com/microsoft/BitNet/issues/470)
