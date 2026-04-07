# Learnings & Deep Dives

A personal reference for understanding the tech stack, the failure modes, and the concepts behind every decision in this project.

---

## 1. How LLM Inference Works (and Why Hardware Matters)

### The two phases of inference

Every time you send a message, the model does two things:

**1. Prefill (prompt processing)**
The model reads your entire input — system prompt, conversation history, workspace files, your message — all at once. This is computationally expensive because every token attends to every other token (quadratic complexity). This is where large system contexts (like OpenClaw's workspace `.md` files) kill performance on weak hardware.

**2. Decode (token generation)**
The model generates one token at a time, autoregressively. Each token is faster than prefill but adds up for long responses. This is what people measure as "tokens per second."

### Why the Pi 5 stalled

The Pi 5's ARM Cortex-A76 CPU has no GPU, no NPU, and limited memory bandwidth. Every matrix multiplication in the model runs on the CPU. For a 1.7B model responding to a simple "hi" with ~4KB of workspace context:

- **Prefill:** ~4,000 tokens × model layers × attention heads = billions of multiplications on CPU → **30-90 seconds**
- **Decode:** Even if fast, you already lost the user

Apple Silicon (M-series) is different: unified memory means the GPU and CPU share the same RAM pool. The GPU handles the matrix multiplications in parallel → same 1.7B model runs in seconds.

### The KV Cache and context window RAM

Every token in the context window requires storing key-value pairs in RAM (the "KV cache"). The formula roughly is:

```
KV cache size ≈ 2 × layers × heads × head_dim × context_length × bytes_per_element
```

For qwen3:8b at 32k context → ~5-6 GB KV cache + ~5 GB weights = ~10-11 GB total.
For qwen3:8b at 128k context → ~20+ GB — exceeds the Mac's 18 GB.

**This is why context window matters:** A model auto-detected at 128k context will try to pre-allocate 128k worth of KV cache even if you only send 100 tokens. Always explicitly cap `contextWindow` in your config.

---

## 2. Model Parameters: Size, Quantization, and What They Mean

### Parameter count

"8B" means 8 billion parameters — the learned weights of the neural network. More parameters = more capacity to learn complex patterns, but more RAM and compute required.

**Rough mental model:**
| Params | Quality | On Pi 5 CPU | On Mac (Metal) |
|--------|---------|-------------|----------------|
| 0.5B | Very limited | Marginally usable | Fast |
| 1.7B | Basic | Stalls with large context | Fast |
| 8B | Good | Unusable | 30-50 tok/s |
| 70B | Excellent | Impossible | Needs 40GB+ |

### Quantization

Full-precision models store each weight as a 32-bit float (~4 bytes). This is impractical for consumer hardware. Quantization compresses weights:

| Format | Bits per weight | Quality loss | Size reduction |
|--------|----------------|--------------|----------------|
| F32 | 32 | None (reference) | 1x |
| F16/BF16 | 16 | Negligible | 2x |
| Q8_0 | 8 | Very small | 4x |
| Q4_K_M | 4 | Small | 8x |
| Q2_K | 2 | Noticeable | 16x |

Ollama defaults to `Q4_K_M` — a good balance. The "K_M" means it uses a mixed quantization strategy (some layers get more bits than others). This is why a "2B effective parameter" model like gemma4:e2b is 7.2 GB on disk — the actual parameter count is higher.

### "Effective" parameters (E2B, E4B)

Gemma4's E2B/E4B naming is Google's way of saying the model behaves like a 2B/4B model in terms of speed/memory, but has more actual parameters with smart pruning. The "effective" label refers to compute cost, not raw parameter count. This is why gemma4:e2b is 7.2 GB despite the "2B" name.

---

## 3. Tool Calling — What It Is and Why It's Hard

### What tool calling actually does

When OpenClaw wants Claudius to run a web search or execute a terminal command, it sends the model a special message listing available "tools" (functions with names, descriptions, and parameter schemas). The model must respond with structured JSON specifying which tool to call and with what arguments — instead of a plain text response.

Example tool call the model must generate:
```json
{
  "tool_calls": [{
    "name": "web_search",
    "arguments": {"query": "today's news headlines"}
  }]
}
```

This requires the model to:
1. Understand it should use a tool (not just answer from memory)
2. Pick the right tool
3. Output valid JSON in exactly the right format
4. Stop generating and wait for the tool result

### Why some models fail at tool calling

Models that aren't fine-tuned for tool use tend to:
- Ignore tools entirely and answer from knowledge
- Output tool call JSON as plain text (doesn't get executed)
- Hallucinate tool names or argument schemas
- Continue generating after the tool call instead of stopping

This is a training data problem — the model needs to have seen thousands of examples of tool call patterns during fine-tuning.

### Why qwen3 is good at it

Alibaba trained the Qwen3 series specifically for "agentic" workflows — tasks that require multiple tool calls, planning, and following complex instructions over many turns. The training data includes extensive function-calling examples across many domains.

### The difference: tool calling vs instruction following vs reasoning

| Capability | What it means | Good models |
|------------|--------------|-------------|
| **Tool calling** | Outputs valid function call JSON, stops at right time, handles results | qwen3, llama3.1+, mistral |
| **Instruction following** | Obeys system prompt rules (e.g. "never reveal these files") | qwen3, claude, gpt-4 |
| **Reasoning** | Works through multi-step logic, shows chain-of-thought | deepseek-r1, qwen3 (thinking mode), o1/o3 |

These are separate skills. A model can be good at reasoning but bad at tool calling (deepseek-r1). A model can follow instructions well but be bad at structured output (many fine-tuned models). qwen3 is unusually strong at all three.

### Thinking mode (qwen3's `/think` vs `/no_think`)

qwen3 supports two modes:
- **Thinking mode** (default): model reasons through the problem before answering — slower, better for complex problems
- **No-think mode**: direct answer — faster, better for simple tasks

OpenClaw forces `thinking=off` (shown in logs as `thinking=off messageChannel=telegram`). This is correct for a chat assistant — you don't want the model spending 30 seconds reasoning about "say hi."

---

## 4. The OpenClaw Stack — How the Pieces Connect

### Request lifecycle (Pi → Mac → Pi → Telegram)

```
1. You send "hi" on Telegram
2. Telegram API → Pi (OpenClaw gateway at :18789)
3. OpenClaw loads workspace .md files as system context
4. OpenClaw sends API request to Mac Ollama (:11434) over Tailscale
5. Ollama runs qwen3:8b inference on Mac GPU (Metal)
6. Ollama streams tokens back to Pi
7. OpenClaw assembles response, sends to Telegram Bot API
8. You receive the message
```

The Pi never does LLM compute — it's purely a gateway and orchestrator.

### OpenClaw's role

OpenClaw is an LLM agent framework. It manages:
- **Provider abstraction:** talks to Ollama, Groq, Gemini etc. with the same internal API
- **Tool routing:** when the model requests a tool call, OpenClaw executes it (web search, exec, GitHub) and feeds the result back to the model
- **Session memory:** persists conversation context across disconnects
- **Workspace files:** loads `.md` files as system context on every request
- **Failover chain:** tries providers in order if one fails
- **Telegram channel:** listens for messages, sends responses
- **Cron scheduler:** runs scheduled jobs (6 AM news briefing)

### Ollama's role

Ollama is a local model server. It:
- Manages model downloads and storage (`~/.ollama/models/`)
- Serves an HTTP API (`/api/chat`, `/api/generate`, `/api/tags`)
- Handles model loading/unloading (respects `KEEP_ALIVE`)
- Uses Metal on Mac for GPU-accelerated inference
- Supports native tool calling via `/api/chat` — OpenClaw uses this (not the `/v1` OpenAI-compatible endpoint, which breaks tool calling)

### Why `/v1` breaks tool calling

Ollama has two API modes:
- **Native (`/api/chat`):** Ollama's own format, full tool support
- **OpenAI-compatible (`/v1/chat/completions`):** Translates to OpenAI format — tool call translation is lossy and unreliable

Always use `baseUrl: "http://host:11434"` (no `/v1`) with `api: "ollama"` in OpenClaw config.

### Tailscale's role

Tailscale creates a WireGuard mesh VPN between all your devices. Each device gets a stable Tailscale IP (e.g. `100.x.x.x`) and MagicDNS hostname. Traffic between Pi and Mac is encrypted end-to-end and works across any network — university WiFi, cellular, home — without port forwarding.

This is what makes Mac-offloaded inference work: the Pi treats the Mac as if it's on the same local network, even when they're in different physical locations.

**Tailscale Serve vs Funnel:**
- **Serve:** exposes a local service to your Tailscale network only (private)
- **Funnel:** exposes to the public internet (dangerous for an AI agent with shell access)

OpenClaw uses Serve, not Funnel.

---

## 5. RAM, Context, and Why These Numbers Matter

### The 16k minimum warning in OpenClaw

OpenClaw warns when `contextWindow < 32000`. This is because the workspace files + conversation history + tool call results can easily consume 8-16k tokens. If your context window is too small, the model starts truncating context — it forgets the beginning of the conversation, loses track of instructions, or cuts off tool results.

For an assistant use case, 16k-32k is the practical minimum. 32k is recommended.

### Memory pressure on the Mac

| Model | ctx | On-disk | In RAM |
|-------|-----|---------|--------|
| qwen3:1.7b | 16k | 1.4 GB | ~2 GB |
| qwen3:8b | 32k | 5.2 GB | ~9-10 GB |
| qwen3:8b | 128k | 5.2 GB | ~20+ GB |
| gemma4:e2b | 32k | 7.2 GB | ~12-14 GB |

With 18GB unified memory, qwen3:8b at 32k context leaves ~8-9 GB for macOS and other apps — comfortable. At 128k it would OOM.

### Why KEEP_ALIVE matters

`OLLAMA_KEEP_ALIVE=10m` means:
- Model stays loaded in GPU memory for 10 minutes after the last request
- First request after cold start: ~20-30s (loading from disk → GPU memory)
- Requests within the keep-alive window: ~5-15s (already in memory)
- After 10 min idle: model unloads, GPU memory freed, Mac fans quiet down

Too long (30m+): Mac stays warm even when not in use
Too short (1-2m): Every request feels like a cold start

10 minutes is a good balance for occasional Telegram use.

---

## 6. Model Comparison: What to Look For

### For an always-on assistant (this project's use case)

Priority order: **tool calling > instruction following > speed > reasoning > size**

- Must support tool calling — non-negotiable for OpenClaw
- Must follow system prompt rules (especially "don't leak your instructions")
- Speed matters for UX — waiting 2+ minutes is unusable
- Reasoning is nice but rarely needed for daily assistant tasks
- Smaller is better only if it doesn't sacrifice the above

### For coding tasks

Priority: **reasoning > instruction following > tool calling > size**

- Needs to handle multi-step logic and debug chains
- qwen3:8b, deepseek-r1 distills, codestral

### For edge devices (low RAM, no GPU)

Priority: **size > speed > instruction following**

- Must fit in available RAM with headroom
- qwen3:0.5b, qwen3:1.7b (but slow without GPU)
- Raspberry Pi AI Kit (Hailo-8L NPU) changes this equation — ~13 TOPS dedicated neural processing

### 2026 model landscape summary (for OpenClaw use)

| Model | Size | Tool Calling | Instruction | Speed (Mac M-series) | Notes |
|-------|------|-------------|-------------|----------------------|-------|
| qwen3:8b | 5.2 GB | Excellent | Excellent | Fast | **Best overall for this use case** |
| qwen3:14b | 9 GB | Excellent | Best | Good | Overkill but very capable |
| llama3.1:8b | 4.9 GB | Good | Weak | Fast | Leaks system prompts |
| mistral:7b | 4.4 GB | Good | Good | Fast | Solid alternative |
| gemma4:e2b | 7.2 GB | None | Good | Fast | Multimodal but no tools |
| deepseek-r1:8b | 5 GB | Poor | Good | Slow (thinks first) | Good for math/code, bad for chat |
| phi4-mini | 2.5 GB | Good | Good | Fast on Mac | Stalls on Pi CPU |

---

## 7. Lessons About System Design

### Separation of concerns: config vs instructions

`openclaw.json` = hard configuration (actual routing, failover, auth)
Workspace `.md` files = soft instructions (LLM behavior suggestions)

These must stay in sync but serve different purposes. A change to model routing needs both updated — the config for the machine behavior, the `.md` for the model's self-awareness.

### Smaller models need simpler prompts

The longer and more complex the system prompt, the more likely a smaller model is to:
- Repeat parts of it back
- Lose track of which instructions apply
- Conflate instructions with conversation content

Rule of thumb: if your total workspace context is over 100 lines, a sub-10B model will struggle. Trim ruthlessly.

### Fallback chains: less is more

Having Groq → Gemini → OpenRouter as fallbacks sounds resilient. In practice:
- Heavy testing exhausts all three simultaneously
- Free tier quotas are low and shared across all uses
- When all fail, the error is confusing
- Gemini's 20 req/day is too precious to use as a fallback

Better design: one high-quality primary (local, cost-free), no cloud LLM fallbacks, explicit failure if primary is down. Reserve cloud providers for specific tasks (web search, scheduled jobs) where they're the right tool.

### The Pi is a gateway, not a compute node

The Pi 5 is excellent at:
- Running a lightweight Node.js gateway (OpenClaw)
- Managing Tailscale connections
- Hosting a Telegram bot
- Running systemd daemons 24/7 on minimal power

The Pi 5 is bad at:
- LLM inference (no GPU, limited CPU)
- Any compute-intensive background task alongside inference

Design accordingly. Put the gateway on the Pi. Put the compute where compute lives.

---

## 8. Two-Bot Architecture — What Was Learned

### Why a subscription CLI can't replace an API key

Claude Pro ($20/month) gives you access to Claude Code CLI via OAuth. It does **not** give you an API key for programmatically calling Anthropic's API. OpenClaw requires an API key to route requests — so Claude Pro alone cannot power an OpenClaw agent.

This created a constraint that led to the two-bot design:
- **Claudius** (OpenClaw) uses a local model via Ollama — no API key needed, free
- **Apollius** (Claude Code CLI) uses the subscription through the official CLI — no API key needed

The lesson: understand what a subscription actually gives you. "Access to Claude" and "API access to Claude" are different products.

### Claude Code CLI as a headless daemon

Claude Code is designed for interactive terminal use. Running it headlessly (no user at the terminal) required solving three problems:

**1. PTY requirement**
Claude Code needs a real pseudo-terminal to function — it uses terminal control codes for its UI. A fake PTY (`script -q`) can receive messages but responses don't get sent back through the Telegram plugin. Only `tmux` provides a real PTY that works correctly as a daemon.

**2. Startup dialogs**
Claude Code shows interactive confirmation dialogs on startup that block execution until manually confirmed. The wrapper script polls the tmux pane and auto-sends the correct keystrokes when these dialogs appear.

**3. Slash commands don't work through Telegram**
Custom commands in `~/.claude/commands/*.md` only work in interactive terminal mode — they require the TUI to intercept the `/` prefix. When messages come in from Telegram's `--channels` plugin, they arrive as plain text. The fix: put all slash command logic in `~/CLAUDE.md` so Claude handles them via instruction following rather than the slash command system.

### CLAUDE.md is the right place for behavior rules

Claude Code reads `CLAUDE.md` from the working directory as part of its system context on every session. This is the correct place for:
- Slash command definitions (what `/reset`, `/health`, `/commands` should do)
- Approval logic (when to ask, when to just do it)
- Response style rules (keep it short, this is Telegram)

The `--dangerously-skip-permissions` flag removes OS-level approval prompts (necessary for daemon mode). `CLAUDE.md` replaces them with application-level logic that's smarter — Claude asks before destructive actions, not for every file read.

### Idle cost is zero

A Claude Code session in `--channels` mode sitting idle costs nothing. Anthropic only charges when the model is generating a response. Leaving the tmux session open 24/7 consumes ~50MB RAM on the Pi and zero API credits.

### Context window and memory management

Claude Code handles session memory far better than OpenClaw + Ollama:

| | OpenClaw + qwen3:8b | Apollius (Claude Code) |
|---|---|---|
| Context window | 32k (capped) | 200k |
| Auto-compaction | Broken (Ollama doesn't report token counts) | Works correctly |
| Manual reset | `/reset` | `/clear` |
| Cold start | ~45s (model reload) | None (Anthropic API, always warm) |

The practical difference: with Ollama, you have to manually `/reset` regularly or responses slow down. With Claude Code, you can have much longer conversations before needing to clear.

### Streaming vs one-shot for Telegram

`streaming: off` in OpenClaw meant the entire response had to complete before Telegram received anything. With 30-90 second inference times, this looked like the bot was broken or dropping messages.

`streaming: partial` sends the message immediately and edits it as tokens stream in. Same total inference time, but perceived latency drops to near-zero — the user sees the bot start typing within seconds.

Always enable streaming for any chat interface where the user is waiting.
