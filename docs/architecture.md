# Architecture & Design Decisions

## System Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    OPERATOR (Remote — Seattle)                      │
│   ┌───────────────────────┐       ┌──────────────┐                  │
│   │       Telegram        │       │ Laptop (SSH) │                  │
│   │  Bot 1: Claudius      │       └──────┬───────┘                  │
│   │  Bot 2: Apollius      │              │ Tailscale WireGuard       │
│   └──────────┬────────────┘              │                          │
└──────────────┼───────────────────────────┼──────────────────────────┘
               │ Telegram Bot API          │
               ▼                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  RASPBERRY PI 5 — California (Always On)            │
│                                                                     │
│   ┌─────────────────────────────────────────┐                       │
│   │   Bot 1 — OpenClaw Gateway (:18789)     │                       │
│   │   Claudius · qwen3:8b via Mac Tailscale │                       │
│   │   • Bound to 127.0.0.1 (loopback only) │                       │
│   │   • Auth: cryptographic token           │                       │
│   │   • Telegram allowlist: [operator ID]   │                       │
│   │   • streaming: partial                  │                       │
│   │   • Runtime: Node.js 22 (systemd)       │                       │
│   └───────────────────┬─────────────────────┘                       │
│                       │ Tailscale mesh (164ms to Mac)               │
│                       ▼                                             │
│   ┌──────────────────────────────────────────────────────────┐      │
│   │           MacBook Pro — Apple Silicon (18GB)             │      │
│   │   Ollama (Metal GPU) · qwen3:8b at ~30-50 tok/s         │      │
│   │   Keep-alive: 10 min idle → unloads from GPU memory     │      │
│   └──────────────────────────────────────────────────────────┘      │
│                                                                     │
│   ┌─────────────────────────────────────────┐                       │
│   │   Bot 2 — Apollius (Claude Code CLI)    │                       │
│   │   claude --channels telegram plugin     │                       │
│   │   • Runs in tmux PTY (real terminal)    │                       │
│   │   • systemd service: apollius.service   │                       │
│   │   • --dangerously-skip-permissions      │                       │
│   │   • CLAUDE.md handles approval logic    │                       │
│   │   • Telegram allowlist: [operator ID]   │                       │
│   └───────────────────┬─────────────────────┘                       │
│                       │ HTTPS (Anthropic API)                       │
│                       ▼                                             │
│              Claude Sonnet 4.6 (Claude Pro subscription)            │
│                                                                     │
│   Web search tool → Gemini 2.5 Flash (Google Search Grounding)      │
│   6 AM cron      → Gemini 2.5 Flash (isolated session)              │
│   Emergency offline → qwen3:1.7b on Pi (not in routing chain)       │
│                                                                     │
│   Hooks: session-memory, command-logger, boot-md                    │
│   Scheduled: Morning News Briefing (6 AM daily via Gemini)          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Decision 1: Two-Bot Architecture

The system now runs two separate Telegram bots with distinct purposes:

| | Bot 1 — Claudius | Bot 2 — Apollius |
|---|---|---|
| Model | qwen3:8b (local Mac) | Claude Sonnet 4.6 (Anthropic) |
| Cost | Free | Claude Pro subscription |
| Purpose | General chat, tools, briefings | Coding agent sessions |
| Agent | OpenClaw | Claude Code CLI |
| Path | Telegram → Pi → Mac → Pi → Telegram | Telegram → Pi (Claude Code) → Anthropic → Telegram |
| Session | Managed by OpenClaw | Managed by Claude Code natively |
| Memory | Grows with context, auto-reset at 30m idle | Built-in compaction, 200k context window |

**Why two bots instead of one?**

- Claude Pro subscription doesn't expose an API key — only the CLI works
- OpenClaw requires an API key to route to Anthropic
- Claude Code CLI has its own Telegram plugin that bypasses OpenClaw entirely
- Separation is cleaner: local model for free general use, Claude for serious coding

---

## Decision 2: Voice Transcription — whisper.cpp on Pi

Apollius supports Telegram voice messages via whisper.cpp running on the Pi itself.

| Option | Speed | Cost | Privacy | Notes |
|--------|-------|------|---------|-------|
| OpenAI Whisper API | ~1-2s | $0.006/min | Cloud | Requires API key, adds cost |
| Picovoice Leopard | ~1-3s | Free tier | On-device | Less accurate, key required |
| faster-whisper | ~5-15s | Free | On-device | Max int8 — no int4 support |
| **whisper.cpp (chosen)** | **~13s** | **Free** | **On-device** | **MIT license, int4/Q4/Q5 support, ARM NEON** |

### Why whisper.cpp over faster-whisper

faster-whisper uses CTranslate2 which caps at int8 quantization. whisper.cpp (ggml backend) supports Q4 and Q5 quantized models natively on ARM.

**Why Q5_1 over Q4:** The whisper.cpp model download script doesn't ship a Q4 tiny.en model — Q5_1 is the smallest available quantized English model. Q5_1 sits between int4 and int8 in size/speed, with accuracy nearly indistinguishable from fp16 on short voice clips (per March 2025 quantization study).

**Why edge quantization matters:** Pi 5 has no GPU or NPU — all inference is CPU-only (ARM Cortex-A76). Q5_1 tiny reduces model size ~45% vs fp16 and inference time ~19% vs int8, making real-time-ish transcription feasible on ARM without cloud dependency.

**Pipeline:**
1. Claude Code downloads the `.oga` voice file via Telegram plugin
2. `transcribe.sh` converts `.oga` → 16kHz mono WAV via ffmpeg
3. whisper.cpp runs inference → plain text
4. Claude processes the text as if it were a typed message

**Installed at:** `~/whisper.cpp/` | Model: `models/ggml-tiny.en-q5_1.bin` | Script: `~/.local/bin/transcribe.sh`

---

## Decision 3: Apollius — Official Claude Code Channels Feature

The Apollius bot uses **Claude Code Channels**, an official Anthropic feature currently in research preview (requires Claude Code v2.1.80+).

- Official docs: https://code.claude.com/docs/en/channels
- Plugin source: https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/telegram
- Requires claude.ai login (Pro/Max) — API keys are explicitly NOT supported

The feature is designed exactly for this use case: push Telegram messages into a running Claude Code session on your own machine, against your real files. Anthropic officially supports `--dangerously-skip-permissions` for unattended/daemon use.

## Decision 3: Apollius — Claude Code CLI as Daemon

Claude Code is designed as an interactive terminal application. Running it as a headless systemd service required solving several problems:

### PTY requirement

Claude Code needs a real pseudo-terminal to function. `script -q` (fake PTY) was tried and failed — Ollama could receive messages but responses weren't sent back to Telegram. `tmux` provides a real PTY and works correctly.

### Startup dialog automation

Claude Code shows two interactive dialogs on startup:
1. Workspace trust dialog ("Yes, I trust this folder")
2. Bypass permissions warning ("Yes, I accept")

The wrapper script (`apollius-start.sh`) polls the tmux pane and auto-sends the correct key inputs when these dialogs appear.

### Permission model

`--dangerously-skip-permissions` removes all OS-level approval prompts (necessary for daemon mode — prompts have nowhere to display). `~/CLAUDE.md` replaces this with application-level approval logic: Claude is instructed to clarify intent first, and ask before any destructive/irreversible action.

### Session persistence

Claude Code's `--channels` mode keeps the session alive indefinitely. Context is managed natively by Claude Code (200k window, built-in compaction). `/clear` or `/reset` from Telegram resets the conversation.

---

## Decision 3: Mac-Offloaded Inference (Claudius)

The Pi routes all OpenClaw LLM requests to a MacBook Pro on the same Tailscale network. The Mac runs Ollama with Metal GPU acceleration.

### Why not run the LLM on the Pi?

Pi 5 CPU inference was tested extensively. Results:

| Model | Size | Pi 5 Result |
|-------|------|-------------|
| gemma4:e4b | 9.6 GB | OOM — Pi only has 8GB |
| gemma4:e2b | 7.2 GB | OOM at 32k context |
| phi4-mini | 2.5 GB | Stalled — 2+ min for "hi" |
| qwen3:1.7b | 1.1 GB | Stalled — still 2+ min |

**Root cause:** Pi 5 has no NPU or GPU. All inference runs on the ARM Cortex-A76 CPU. The workspace `.md` files sent as system context add thousands of tokens — CPU prefill is the bottleneck regardless of model size.

**Mac comparison:** Apple Silicon unified memory + Metal GPU runs qwen3:8b at ~30-50 tok/s.

### Model routing (Claudius)

| Priority | Model | Location |
|----------|-------|----------|
| Primary | `ollama/qwen3:8b` | Mac via Tailscale |
| Web search | `gemini-2.5-flash` | Google API (tool, not LLM chain) |
| 6 AM cron | `gemini-2.5-flash` | Pinned directly on job |
| Emergency offline | `qwen3:1.7b` on Pi | Not in routing chain |

---

## Decision 4: Streaming Enabled (partial)

`channels.telegram.streaming` was previously `off` — the entire response had to complete before Telegram received anything. With responses taking 15-90 seconds (cold load + inference), this felt like the bot was broken or dropping messages.

Setting to `partial`: Telegram shows a message immediately that updates as tokens stream in. Perceived latency drops dramatically even though total inference time is unchanged.

---

## Decision 5: Mode A Web Search (Cloud Grounding)

| | Mode A: Cloud Grounding (chosen) | Mode B: Local Fetching |
|---|---|---|
| Who visits the website | Google's crawlers | The Raspberry Pi |
| Prompt injection risk | Low | High |
| Pi IP exposure | None | Exposed to every site visited |

**Why Mode A:** Pi runs unattended ~800 miles from the operator. A malicious page tricking the agent into a destructive shell command with no one present = unrecoverable. Mode A removes this attack surface.

Gemini is used **only** for web search (tool) and the 6 AM cron — never in the general LLM chain, preserving the 20 req/day free quota.

---

## Decision 6: Tailscale over Port Forwarding

| Property | Tailscale | Port Forwarding |
|----------|-----------|-----------------|
| Pi visible to internet | No | Yes (public IP + port) |
| Works through NAT/firewalls | Yes | Requires router access |
| Works on university networks | Yes | Often blocked |
| Cost | Free (100 devices) | Free but risky |

Gateway bound to `127.0.0.1`. External access via Tailscale Serve (private HTTPS only — not Funnel).

Same Tailscale mesh connects Pi ↔ Mac, making Mac-offloaded inference possible without any public exposure. Pi↔Mac latency: ~164ms direct link.

---

## Decision 7: qwen3:8b over other local models

Requirements: **tool calling** + **instruction following** (workspace .md files must be obeyed, not repeated back).

| Model | Tool Calling | Instruction Following | Notes |
|-------|-------------|----------------------|-------|
| `gemma4:e2b` | No | Good | Fails — no tool support |
| `llama3.1:8b` | Yes | Weak | Leaks system prompt back to user |
| `qwen3:8b` | Excellent | Excellent | Current — purpose-built for agentic workflows |

Context window explicitly capped at 32k in OpenClaw config (Ollama auto-discovers 200k native, which pre-allocates too much RAM):
```json
{"contextWindow": 32768, "maxTokens": 8192}
```

---

## Security Layers

### 1. Network — Tailscale
- WireGuard encryption on all traffic
- Zero open ports on home router
- Pi invisible to public internet
- Key expiry disabled — no silent disconnection while owner is remote

### 2. SSH — Fail2Ban + UseDNS
- 3 failed attempts → 1 hour ban
- Loopback, LAN, and Tailscale IPs whitelisted
- `UseDNS no` — eliminates 10-15s login delay over Tailscale

### 3. Claudius Gateway — OpenClaw
- Bound to `127.0.0.1` (loopback only)
- Exposed via Tailscale Serve (private HTTPS, not public Funnel)
- 64-character cryptographic auth token
- Telegram `allowFrom` — single user ID only

### 4. Apollius — Claude Code
- Telegram `allowlist` policy — single user ID only
- `--dangerously-skip-permissions` scoped to daemon use only
- CLAUDE.md enforces clarify-first + approval-on-key-steps behavior
- Runs on Pi filesystem — no public exposure

### 5. AI Model Layer — Mode A Grounding
- Web research via Gemini — Pi never visits external sites
- Untrusted content never enters Pi's local execution context

---

## Model Evolution

| Version | Primary | Reason for Change |
|---------|---------|------------------|
| v1 | Llama 3.2 3B (Pi local) | Initial setup |
| v2 | Groq Llama 3.3 70B (cloud) | Speed + quality gap vs local 3B |
| v3 | phi4-mini (Pi local) | API quota conservation |
| v4 | qwen3:8b (Mac via Tailscale) | Pi CPU too slow; Mac Metal GPU is fast |
| v5 | + Claude Sonnet 4.6 (Apollius bot) | Coding agent added via Claude Code CLI |

---

## Session Management & Performance

### Claudius (OpenClaw + qwen3:8b)

Every response requires Ollama to re-process the entire conversation history (transformer prefill). Auto-compaction never fires because Ollama doesn't report token counts.

Config:
```json
"session": { "reset": { "idleMinutes": 30 } },
"agents": { "defaults": { "contextPruning": { "mode": "cache-ttl" } } }
```

- `idleMinutes: 30` — auto-resets context after 30 min of inactivity
- `cache-ttl` pruning — prunes old tool results without needing token counts
- Use `/reset` in Telegram when switching topics or returning after a break

### Apollius (Claude Code)

Claude Code manages its own context natively:
- 200k token context window
- Built-in automatic compaction when approaching limits
- Proper token counting (Anthropic API reports tokens correctly)
- Use `/clear` to wipe history, `/compact` to compress without wiping

### OLLAMA_KEEP_ALIVE (Mac)

| Setting | Behavior |
|---------|----------|
| `10m` | Unload after 10 min idle — recommended |
| `-1` | Never unload — avoid, overheats Mac during long idle |

Trade-off: after unload, first request takes ~45s to reload from disk into GPU.

---

## Scheduled Automation

```
Morning News Briefing
  Schedule:  0 6 * * * (6:00 AM Pacific daily)
  Model:     google/gemini-2.5-flash (pinned — needs web search)
  Session:   isolated (no cross-contamination with regular chat)
  Delivery:  announce → Telegram → operator chat ID
  Status:    active
```
