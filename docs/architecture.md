# Architecture & Design Decisions

## System Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    OPERATOR (Remote Location)                       │
│   ┌───────────┐              ┌──────────────┐                       │
│   │ Telegram  │              │ Laptop (SSH) │                       │
│   └─────┬─────┘              └──────┬───────┘                       │
└─────────┼──────────────────────────┼────────────────────────────────┘
          │ Telegram Bot API         │ Tailscale WireGuard Tunnel
          ▼                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      RASPBERRY PI 5 (Primary Site)                  │
│                                                                     │
│   ┌──────────────────────────────────────────────┐                  │
│   │         OpenClaw Gateway (:18789)            │                  │
│   │  • Bound to 127.0.0.1 (loopback)             │                  │
│   │  • Proxied via Tailscale Serve (HTTPS)       │                  │
│   │  • Auth: 64-char cryptographic token         │                  │
│   │  • Telegram allowlist: [your_telegram_id]    │                  │
│   │  • Runtime: Node.js 22 (systemd daemon)      │                  │
│   └────────────┬──────────────┬──────────────────┘                  │
│                │              │                                     │
│                ▼              ▼                                     │
│   ┌─────────────────┐  ┌───────────────────────────────────────┐   │
│   │ Ollama          │  │ Cloud Providers (fallback / tools)    │   │
│   │ phi4-mini       │  │                                       │   │
│   │ (PRIMARY)       │  │  Groq Llama 3.3 70B  — fallback #1   │   │
│   │                 │  │  OpenRouter Llama 70B — fallback #2   │   │
│   │ 2.5 GB on-disk  │  │  Gemini 2.5 Flash   — web search     │   │
│   │ ~2.5 GB RAM     │  │                       + 6 AM cron    │   │
│   │ Fully offline   │  └───────────────────────────────────────┘   │
│   └─────────────────┘                                               │
│                                                                     │
│   Active Skills: github, weather, healthcheck, skill-creator        │
│   Hooks: session-memory, command-logger, boot-md                    │
│   Scheduled: Morning News Briefing (6 AM daily via Gemini)          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Decision 1: Local-First Model Routing

### Current routing chain

| Priority | Model | Purpose |
|----------|-------|---------|
| Primary | `ollama/phi4-mini` (local) | All chat — zero API cost |
| Fallback 1 | `groq/llama-3.3-70b-versatile` | Cloud LLM if phi4 fails |
| Fallback 2 | `openrouter/llama-3.3-70b:free` | Last-resort cloud LLM |
| Web search tool | `google/gemini-2.5-flash` | Independently routed — never in LLM chain |
| 6 AM cron | `google/gemini-2.5-flash` | Pinned directly on the job |

### Why local-first?

Free-tier cloud quotas are finite (Groq ~30 RPM, Gemini 20 req/day, OpenRouter heavily throttled). phi4-mini handles all normal chat locally at zero cost, preserving cloud quota for when it actually matters — rate limit recovery.

### Why Gemini is NOT in the LLM fallback chain

Gemini is already consumed by the web search tool (Mode A grounding) and the 6 AM cron job. Adding it to the general fallback chain would drain its 20 req/day quota on ordinary chat that phi4-mini can handle locally. It is available via `/model gemini` for explicit manual use.

### Evolution

| Phase | Primary | Reason for Change |
|-------|---------|------------------|
| v1 | Ollama Llama 3.2 3B (local) | Initial setup |
| v2 | Groq Llama 3.3 70B (cloud) | Speed + quality gap was dramatic |
| v3 | phi4-mini (local) | API quota conservation; local handles most chat fine |

---

## Decision 2: Why phi4-mini over other local models

Tested on Pi 5 (8GB RAM):

| Model | Size | RAM | Fits? | Notes |
|-------|------|-----|-------|-------|
| gemma4:e4b | 9.6 GB | ~9+ GB | No | Too large for 8GB Pi |
| gemma4:e2b | 7.2 GB | ~7 GB | Marginal | Leaves very little headroom |
| phi4-mini | 2.5 GB | ~2.5 GB | Yes | Best reasoning/instruction following for size |
| qwen3:4b | 2.5 GB | ~2.5 GB | Yes | Strong alternative |
| qwen3:1.7b | 1.1 GB | ~1 GB | Yes | Lighter but less capable |

**phi4-mini chosen** — Microsoft's instruction-tuning is excellent for assistant tasks, 128K context window, and leaves ~5 GB RAM free for OpenClaw and OS overhead.

---

## Decision 3: Mode A Web Search (Cloud Grounding)

When the agent needs to research something, there are two architecturally distinct approaches:

| | Mode A: Cloud Grounding (chosen) | Mode B: Local Fetching |
|---|---|---|
| How it works | Pi sends the question to Gemini. Gemini searches Google on its own servers and returns a sanitized text summary. | Pi uses a local headless browser to visit websites and scrape content. |
| Who visits the website | Google's crawlers | The Raspberry Pi |
| Prompt injection risk | Low — malicious site content never reaches the Pi | High — hidden instructions on a page can reach the LLM |
| Pi IP exposure | None | Pi IP visible to every visited site |

**Why Mode A:** The Pi runs unattended at a location ~800 miles from the operator. If a malicious page tricked the agent into running a destructive shell command with no one present to intervene, the consequences could be unrecoverable. Mode A removes this attack surface entirely.

**Tradeoff:** Gemini returns text summaries only — it cannot download files or navigate complex web apps. For those tasks, the operator SSHes in directly.

---

## Decision 4: Tailscale over Port Forwarding

| Property | Tailscale (chosen) | Port Forwarding |
|----------|--------------------|----------------|
| Pi visibility to internet | Invisible — zero open ports | Public IP + exposed port |
| Works through firewalls/NAT | Yes | Requires router access |
| Works on university networks | Yes (WireGuard UDP) | Often blocked |
| Setup complexity | Install + auth | Router config, DDNS, firewall rules |
| Cost | Free (up to 100 devices) | Free but risky |

The gateway is bound to `127.0.0.1` and exposed only via Tailscale Serve — a private HTTPS reverse proxy visible only to devices on the Tailscale network. Tailscale Funnel (public internet) is explicitly **not** used.

---

## Decision 5: Node.js over Bun

OpenClaw supports both Node.js and Bun runtimes. Bun was tested and rejected:

- Bun exhibited memory corruption on long-lived WebSocket connections (observed after several hours of uptime)
- The Pi runs 24/7 — stability over days/weeks matters more than startup speed
- Node.js 22 LTS has proven stability for daemon workloads

---

## Security Layers

Security is applied at four independent layers:

### 1. Network — Tailscale
- WireGuard encryption on all traffic
- Zero open ports on the home router
- Pi is invisible to public internet port scanners
- Key expiry disabled — prevents silent disconnection while owner is remote

### 2. SSH — Fail2Ban + UseDNS
- 3 failed auth attempts → 1 hour ban
- Loopback, LAN CIDR, and both Tailscale IPs whitelisted
- `UseDNS no` — eliminates 10-15s SSH login delay over Tailscale

### 3. Agent Gateway — OpenClaw
- Gateway bound to `127.0.0.1` (loopback only)
- External access via Tailscale Serve (private HTTPS only)
- 64-character cryptographic auth token
- Telegram `allowFrom` restricts bot to a single user ID
- Destructive shell commands require explicit approval

### 4. AI Model Layer — Mode A Grounding
- Web research routes through Gemini's servers
- Pi never visits external websites
- Untrusted web content never enters the Pi's local execution context

---

## Workspace Files (Claudius's Persona)

The bot's behavior is defined by `.md` files in `~/.openclaw/workspace/`. These are LLM instructions — they do **not** control actual model routing (that lives in `openclaw.json`).

| File | Purpose |
|------|---------|
| `IDENTITY.md` | Name, role, hardware, model stack |
| `SOUL.md` | Behavioral rules — honesty, destructive command gating, zero hallucination policy |
| `USER.md` | Operator profile — background, preferences, timezone |
| `AGENTS.md` | Model routing guidance, trigger phrases, capability descriptions |
| `MEMORY.md` | Long-term setup context persisted across sessions |
| `TOOLS.md` | Environment-specific tool notes |

**Important:** Keep `AGENTS.md` in sync with `openclaw.json`. When model routing changes, both must be updated — the `.md` file informs the LLM's suggestions, `openclaw.json` controls actual failover behavior.

---

## Scheduled Automation

```
Morning News Briefing
  Schedule:  0 6 * * * (6:00 AM Pacific daily)
  Model:     google/gemini-2.5-flash (pinned)
  Session:   isolated (no shared context with regular chat)
  Delivery:  announce → Telegram → operator's chat ID
  Status:    active, last run ok
```

The job is pinned to Gemini because it requires live web search grounding. It runs in an isolated session to prevent cross-contamination with the operator's ongoing conversations.
