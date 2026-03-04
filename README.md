# rpi5-openclaw-assistant

> A Raspberry Pi 5 (8GB) transformed into a 24/7 AI personal assistant, accessible from anywhere via Tailscale and controllable through Telegram. Powered by OpenClaw with a cloud-only multi-provider model stack — Groq for speed, Gemini for web search, and OpenRouter as a free fallback.

**Author:** Andrew Nguyen (@aqn96)
**Status:** Active — managed remotely from Seattle, WA while hardware runs in California
**Bot:** MrOpenClaw (codename: Claudius)

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture & Design Decisions](#2-architecture--design-decisions)
3. [Hardware & Software Stack](#3-hardware--software-stack)
4. [Phase 1 — Base Server Setup](#4-phase-1--base-server-setup)
5. [Phase 2 — AI Agent Layer](#5-phase-2--ai-agent-layer)
6. [Phase 3 — Security Hardening](#6-phase-3--security-hardening)
7. [Key Concepts & Learnings](#7-key-concepts--learnings)
8. [Troubleshooting Log](#8-troubleshooting-log)
9. [Future Plans](#9-future-plans)

## 1. Project Overview

### The Problem

As an MSCS student splitting time between Seattle and California, I needed a way to run a persistent, private AI assistant on hardware I control — without paying for cloud compute, without exposing my home network, and without being physically present to manage it.

### The Solution

A Raspberry Pi 5 running OpenClaw as a systemd daemon, connected to the world through Tailscale (encrypted mesh VPN) and Telegram (messaging interface). The assistant uses a cloud-only multi-provider architecture: Groq handles fast daily chat, Gemini handles web research through Google Search Grounding, and OpenRouter provides a free fallback when other providers are rate-limited.

### What Claudius Can Do

- Respond to natural language commands via Telegram from anywhere in the world
- Search the live 2026 web using Gemini's Google Search Grounding — the Pi itself never visits external websites
- Execute terminal commands on the Pi with confirmation gating for destructive operations
- Read and manage files in the local workspace
- Track GitHub repositories, commits, and PRs via the authenticated `gh` CLI
- Provide real-time system health reports (CPU temp, RAM, disk, network status)
- Remember conversation context across sessions via the session-memory hook
- Deliver a daily morning news briefing at 6 AM via scheduled cron job

## 2. Architecture & Design Decisions

### 2.1 The Cloud-Only Multi-Provider Design

This is the most important architectural decision in the project. Rather than running a local LLM on the Pi's limited hardware, the system leverages multiple free-tier cloud providers with automatic failover — maximizing speed, reliability, and intelligence while keeping costs at zero.

```
┌─────────────────────────────────────────────────────────────────────┐
│                      ANDREW (Seattle, WA)                           │
│                                                                     │
│   ┌───────────┐         ┌──────────────┐                            │
│   │ Telegram   │         │ MacBook Pro  │                            │
│   │ (Phone)    │         │ (SSH / TUI)  │                            │
│   └─────┬─────┘         └──────┬───────┘                            │
│         │                      │                                    │
└─────────┼──────────────────────┼────────────────────────────────────┘
          │ Encrypted            │ Tailscale WireGuard Tunnel
          │ (Telegram Bot API)   │
          │                      │
┌─────────┼──────────────────────┼────────────────────────────────────┐
│         ▼                      ▼       RASPBERRY PI 5 (California)  │
│                                                                     │
│   ┌──────────────────────────────────────────────┐                  │
│   │          OpenClaw Gateway (:18789)            │                  │
│   │                                              │                  │
│   │   • Bound to 127.0.0.1 (loopback)           │                  │
│   │   • Proxied via Tailscale Serve (HTTPS)      │                  │
│   │   • Auth: 64-char cryptographic token        │                  │
│   │   • Telegram allowlist: [<your_telegram_id>] │                  │
│   │   • Runtime: Node.js 22 (systemd daemon)     │                  │
│   └───────┬──────────┬───────────┬───────────────┘                  │
│           │          │           │                                   │
│           ▼          ▼           ▼                                   │
│   ┌────────────┐ ┌─────────────────┐ ┌──────────────────┐          │
│   │ Groq       │ │ Google Gemini   │ │ OpenRouter       │          │
│   │ (PRIMARY)  │ │ (WEB SEARCH)    │ │ (FALLBACK)       │          │
│   │            │ │                 │ │                   │          │
│   │ Llama 3.3  │ │ Gemini 2.5      │ │ Llama 3.3 70B    │          │
│   │ 70B        │ │ Flash           │ │ :free             │          │
│   │ Free tier  │ │ 20 req/day      │ │ Free tier         │          │
│   │ ~30 RPM    │ │ Google Search   │ │ Rate limited      │          │
│   │            │ │ Grounding       │ │ Last resort       │          │
│   └────────────┘ └─────────────────┘ └──────────────────┘          │
│                                                                     │
│   Automatic Failover Chain:                                         │
│   Groq (primary) → Gemini (fallback #1) → OpenRouter (fallback #2) │
│                                                                     │
│   Background Services:                                              │
│   tailscaled, fail2ban, openclaw-gateway                            │
│                                                                     │
│   Active Skills:                                                    │
│   github, weather, healthcheck, skill-creator, video-frames         │
│                                                                     │
│   Hooks:                                                            │
│   session-memory, command-logger, boot-md                           │
│                                                                     │
│   Scheduled Jobs:                                                   │
│   Morning News Briefing (6 AM PT daily via Gemini)                  │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 Why Cloud-Only (No Local LLM)?

The project originally ran Ollama with Llama 3.2 3B (4-bit quantized) locally on the Pi. This was removed in favor of a cloud-only stack for several reasons:

| Factor | Local LLM (Ollama) | Cloud-Only (Current) |
|--------|-------------------|---------------------|
| Speed | ~12-15 tokens/sec (CPU-only) | Near-instant responses via Groq |
| Quality | 3B parameter model — limited reasoning | 70B parameter model — strong reasoning |
| RAM | ~2GB consumed by model | 0GB — all RAM available for the OS and gateway |
| Reliability | Single point of failure | 3-provider failover chain |
| Cost | Free (but slow) | Free (all providers on free tier) |
| Maintenance | Model updates, Ollama service management | Zero — providers handle infrastructure |

**Design decision:** The speed and quality improvement from Groq's 70B model over the local 3B model was dramatic. With three free-tier providers in the failover chain, reliability actually improved compared to the single local model.

### 2.3 Why "Mode A" (Cloud Grounding)?

When Claudius needs to research something on the web, there are two possible paths:

| | Mode A: Cloud Grounding | Mode B: Local Fetching |
|---|---|---|
| How it works | Pi sends the question to Gemini. Gemini searches Google on its own servers and returns a sanitized text summary. | Pi uses a local headless browser (Puppeteer) to visit websites directly and scrape their content. |
| Who visits the website | Google's crawlers | Your Raspberry Pi |
| Prompt injection risk | Low — malicious site code never reaches your Pi | High — hidden instructions on a website can trick the LLM into executing shell commands |
| Pi visibility | Invisible to external websites | Your Pi's IP address is exposed |
| Chosen for this project | ✅ Yes | ❌ No |

**Design decision:** Mode A was chosen because the Pi sits unattended in California. If a malicious website could trick the agent into running `rm -rf /` while the owner is 800 miles away in Seattle, there would be no way to intervene. By routing all web research through Gemini's infrastructure, the Pi never touches untrusted content.

The tradeoff: Gemini can only return text summaries, not download files or navigate complex web apps. For those tasks, the owner must SSH in directly.

### 2.4 Model Routing Strategy

The system uses a keyword-triggered routing strategy to conserve Gemini's limited free quota (20 requests/day) for web search tasks:

| Task | Model | How It's Triggered |
|------|-------|--------------------|
| Casual chat (default) | Groq Llama 3.3 70B | Automatic — all messages go here |
| Web search | Gemini 2.5 Flash | Manual — `/model gemini` when search keywords detected |
| Backup web search | OpenRouter Llama 3.3 (free) | Manual — `/model openrouter` if Gemini is exhausted |
| Rate limit recovery | Gemini → OpenRouter | Automatic — failover chain in `openclaw.json` |

**How routing works:** Claudius's system prompt (AGENTS.md) contains trigger phrases like "search for," "latest news," "what's happening today." When detected, Claudius prompts Andrew to switch to Gemini before answering. After the search is complete, Claudius suggests switching back to Groq to conserve quota.

**Important:** The `.md` files instruct Claudius to *suggest* model switches — they don't perform automatic routing. The actual failover chain (Groq → Gemini → OpenRouter) is configured in `openclaw.json` and handles rate-limit recovery automatically.

### 2.5 Scheduled Automation

A cron job runs daily at 6 AM Pacific using Gemini (isolated session, announced to Telegram):

```bash
openclaw cron add \
  --name "Morning News Briefing" \
  --cron "0 6 * * *" \
  --tz "America/Los_Angeles" \
  --model "google/gemini-2.5-flash" \
  --session isolated \
  --message "Search the web for today's top news headlines..." \
  --announce --channel telegram --to "<your_telegram_id>"
```

This uses 1 of the 20 daily Gemini requests, leaving 19 for manual web searches.

### 2.6 Why Node.js?

OpenClaw is built in TypeScript and runs on Node.js. This might seem unusual for an AI project, but there's a deliberate architectural reason:

- The orchestration (routing messages between Telegram, Gemini, Groq, and the filesystem) runs in Node.js, which excels at non-blocking I/O — handling multiple concurrent events (incoming messages, API responses, file operations) without freezing

Node.js acts as the "nervous system" connecting multiple cloud LLM providers to the outside world. Its event loop architecture means Claudius can receive a Telegram message, dispatch an API call to Groq, check a GitHub repo, and respond — all concurrently on a single-core process.

## 3. Hardware & Software Stack

### Hardware

| Component | Specification | Notes |
|-----------|--------------|-------|
| Board | Raspberry Pi 5 — 8GB RAM | LPDDR5, quad-core ARM Cortex-A76 |
| Power | CanaKit 45W USB-C PD | 5.1V @ 5A for Pi 5 |
| Cooling | Raspberry Pi 5 Active Cooler | Keeps CPU at ~47°C under idle load |
| Storage | SanDisk 64GB Extreme A2 microSDXC | 58GB usable |
| Network | Ethernet (primary) + Wi-Fi (backup) | Dual-homed for reliability |
| Client | Apple MacBook Pro (Seattle) | SSH via Tailscale tunnel |

### Software

| Layer | Technology | Purpose |
|-------|-----------|---------|
| OS | Raspberry Pi OS 64-bit (Debian 12 Bookworm) | Base operating system, kernel 6.12.62 |
| Runtime | Node.js 22 LTS | Required by OpenClaw agent framework |
| AI Agent | OpenClaw 2026.3.1 | Orchestrates LLMs, tools, and messaging channels |
| Primary LLM | Groq Llama 3.3 70B | Fast free-tier cloud inference for daily chat |
| Web Search LLM | Google Gemini 2.5 Flash | Web-grounded research via Google Search Grounding |
| Fallback LLM | OpenRouter Llama 3.3 70B (free) | Last-resort provider when others are rate-limited |
| VPN | Tailscale | WireGuard mesh network, MagicDNS |
| SSH Protection | Fail2Ban | Brute-force mitigation on SSH |
| Version Control | GitHub CLI (`gh`) | Authenticated as aqn96 via fine-grained PAT |
| Monitoring | btop, vcgencmd | System health dashboard and CPU temperature |
| Shell | Bash + custom MOTD via figlet | Personalized login experience with system stats |

## 4. Phase 1 — Base Server Setup

This phase transforms a bare Raspberry Pi into a secure, remotely accessible headless server.

### 4.1 OS Installation (Headless)

Using Raspberry Pi Imager on a Mac:

1. Device: Raspberry Pi 5
2. OS: Raspberry Pi OS (64-bit)
3. Storage: Select the microSD card
4. OS Customisation (click "Next" → "Edit Settings"):
   - General tab: Set hostname (`aqn-rpios`), username (`aqnguyen96`), password, Wi-Fi credentials, timezone, keyboard layout
   - Services tab: Enable SSH with password authentication
5. Write the image and eject the card

Insert the card into the Pi, connect Ethernet and power, wait 2–5 minutes for first boot.

### 4.2 Initial Configuration

```bash
# Find the Pi on your local network
ping aqn-rpios.local

# SSH in for the first time
ssh aqnguyen96@<LOCAL_IP_OR_HOSTNAME.local>

# CRITICAL: Change the default password immediately
passwd

# Update all system packages
sudo apt update && sudo apt upgrade -y
```

**Note on the initramfs.conf prompt:** During large upgrades, the system may ask whether to keep the current config or install the maintainer's version. On a Raspberry Pi, choose **N** (keep current) — the existing config contains Pi-specific boot parameters.

### 4.3 Tailscale — Secure Remote Access

Tailscale creates an encrypted WireGuard mesh network between your devices. No ports are opened on your home router, and no public IP is exposed.

```bash
# Install on the Pi
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate (follow the URL printed to authorize the device)
sudo tailscale up

# Verify the connection
tailscale status
```

**Critical post-setup steps:**

1. Install Tailscale on your client machine (Mac/PC) and log into the same account
2. In the Tailscale Admin Console, find `aqn-rpios` and **Disable Key Expiry** — without this, the Pi will silently disconnect after 180 days
3. Create an alias on your Mac so the CLI works:

```bash
# macOS (App Store version requires alias, not symlink)
echo "alias tailscale='/Applications/Tailscale.app/Contents/MacOS/Tailscale'" >> ~/.zshrc
source ~/.zshrc
```

**Why Tailscale over port forwarding:**

- No public IP exposure (the Pi is invisible to port scanners)
- Works through NAT, firewalls, and university networks
- MagicDNS means you can `ssh aqnguyen96@aqn-rpios` from anywhere
- Free tier supports 100 devices and 3 users

### 4.4 Fail2Ban — SSH Brute-Force Protection

```bash
# Install
sudo apt install fail2ban

# Install rsyslog if auth.log is missing (common on minimal Pi OS installs)
sudo apt install rsyslog
sudo systemctl enable --now rsyslog

# Create local config (never edit jail.conf directly)
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sudo nano /etc/fail2ban/jail.local
```

Key settings in `jail.local`:

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 <your_lan_cidr> <your_pi_tailscale_ip> <your_mac_tailscale_ip>
bantime  = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port    = ssh
```

```bash
# Apply and verify
sudo systemctl restart fail2ban
sudo fail2ban-client status sshd
```

### 4.5 SSH Performance Optimization

```bash
# Disable reverse DNS lookup (eliminates 10-15s delay over Tailscale)
echo "UseDNS no" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart ssh
```

### 4.6 Custom MOTD (Message of the Day)

```
Welcome to aqn-rpios!
----------------------------------------------------------------------
Date:           Monday, March 02, 2026 12:03:06 PM PST
OS Version:     Debian GNU/Linux 12 (bookworm) (6.12.25+rpt-rpi-2712)
Uptime:         up 0 minutes
----------------------------------------------------------------------
System Status:
  CPU Temp:      49.4'C
  Memory:        Total: 7.9Gi, Used: 643Mi, Free: 6.7Gi
  Disk (/):      Total: 58G, Used: 5.3G (10%)
----------------------------------------------------------------------
```

```bash
sudo apt install figlet
sudo usermod -aG video aqnguyen96
sudo cp scripts/10-custom-welcome.sh /etc/update-motd.d/10-custom-welcome
sudo chmod +x /etc/update-motd.d/10-custom-welcome
```

Script source: `scripts/10-custom-welcome.sh`

### 4.7 MacBook Client Aliases

```bash
# ~/.zshrc
alias tailscale='/Applications/Tailscale.app/Contents/MacOS/Tailscale'
alias pi='ssh <your_username>@<your_pi_tailscale_ip>'
```

## 5. Phase 2 — AI Agent Layer

This phase installs the AI infrastructure on top of the secured base server.

### 5.1 Node.js 22 (OpenClaw Dependency)

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v   # Should output v22.x.x
```

### 5.2 OpenClaw Installation

```bash
# Install globally via npm
sudo npm install -g openclaw@latest

# Run the onboarding wizard with daemon flag
openclaw onboard --install-daemon
```

The `--install-daemon` flag creates a systemd user service (`openclaw-gateway.service`) that starts automatically on boot, restarts if it crashes, and persists after SSH disconnects via `loginctl enable-linger`.

### 5.3 Cloud Provider Configuration

The system uses three free-tier LLM providers. API keys are stored in `~/.openclaw/.env`:

```bash
# Required keys (stored in ~/.openclaw/.env)
GROQ_API_KEY=gsk_...          # Primary model — fast chat
GEMINI_API_KEY=AIza...         # Web search + fallback
OPENROUTER_API_KEY=sk-or-v1-... # Free fallback
```

Model configuration in `openclaw.json`:

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "groq/llama-3.3-70b-versatile",
        "fallbacks": [
          "google/gemini-2.5-flash",
          "openrouter/meta-llama/llama-3.3-70b-instruct:free"
        ]
      }
    }
  }
}
```

Web search configuration:

```json
{
  "tools": {
    "web": {
      "search": {
        "enabled": true,
        "provider": "gemini"
      }
    }
  }
}
```

### 5.4 Onboarding Wizard — Key Choices

| Step | Choice | Reasoning |
|------|--------|-----------|
| Gateway type | Local (this machine) | The Pi is the host |
| Workspace | `~/.openclaw/workspace` (default) | The AI's sandboxed read/write area |
| Gateway bind | Loopback | Tailscale Serve handles external access |
| Gateway auth | Token (recommended) | 64-character cryptographic token |
| Tailscale exposure | Serve (private) | NOT Funnel (which would be public) |
| Service runtime | Node (recommended) | Bun has memory corruption on long-lived WebSocket connections |
| Chat channel | Telegram | Bot: `@rpi5_mropenclaw_bot` |
| DM access policy | Pairing (default) | Bot ignores all messages until a terminal-generated code is sent |

### 5.5 Claudius — The Persona

The bot's identity is defined across several workspace files:

| File | Purpose |
|------|---------|
| `IDENTITY.md` | Name, role, hardware, model stack |
| `SOUL.md` | Deep behavioral rules — confidence, honesty, destructive command gating |
| `USER.md` | Operator profile — Andrew's background, preferences, timezone |
| `AGENTS.md` | Model routing strategy, trigger phrases, fallback instructions, capabilities |
| `MEMORY.md` | Long-term setup context persisted across sessions |
| `TOOLS.md` | Environment-specific tool notes |
| `HEARTBEAT.md` | Periodic check-in checklist (currently empty) |

Safety guardrails baked into the persona:

- **Zero Hallucination Policy:** If a file is missing or a command is ambiguous, state the limitation immediately. Do not speculate.
- **Destructive Command Gate:** High-risk terminal commands require explicit "Go ahead, Claudius" from the operator.
- **Encryption/Privacy:** Gateway tokens and API keys must never be exposed outside encrypted Telegram.

### 5.6 Post-Wizard Configuration

```bash
# Lock bot to a single Telegram user
openclaw config set channels.telegram.allowFrom "['<your_telegram_id>']"

# Set Groq as primary model
openclaw config set agents.defaults.model.primary "groq/llama-3.3-70b-versatile"

# Configure fallback chain
openclaw config set agents.defaults.model.fallbacks '["google/gemini-2.5-flash", "openrouter/meta-llama/llama-3.3-70b-instruct:free"]'

# Set up daily morning news briefing
openclaw cron add \
  --name "Morning News Briefing" \
  --cron "0 6 * * *" \
  --tz "America/Los_Angeles" \
  --model "google/gemini-2.5-flash" \
  --session isolated \
  --message "Search the web for today's top news headlines — US and world. Give Andrew a brief morning briefing: 5-7 bullet points, most important stories first. Keep it concise and direct." \
  --announce --channel telegram --to "<your_telegram_id>"
```

### 5.7 Skills Status

| Status | Skill | Description |
|--------|-------|-------------|
| ✅ Ready | healthcheck | Host security auditing, firewall/SSH hardening, version checks |
| ✅ Ready | weather | Current conditions and forecasts via wttr.in (no API key needed) |
| ✅ Ready | skill-creator | Create and package custom AgentSkills |
| ✅ Ready | video-frames | Extract frames from video via ffmpeg |
| ✅ Installed | github | GitHub operations via `gh` CLI — issues, PRs, commits, code review |
| ⏳ Pending | himalaya | CLI email client (IMAP/SMTP) — blocked by missing `uv` |
| ⏳ Pending | summarize | URL/article/podcast summarization — blocked by missing Homebrew |
| ⏳ Pending | nano-pdf | PDF reading and natural-language editing — blocked by missing `uv` |

### 5.8 Service Management

```bash
systemctl --user status openclaw-gateway    # Check status
systemctl --user restart openclaw-gateway   # Restart after config changes
openclaw doctor                             # Full diagnostic
openclaw cron list                          # View scheduled jobs
openclaw cron status                        # Check scheduler status
```

## 6. Phase 3 — Security Hardening

Security is layered across four boundaries: network, SSH, agent gateway, and the AI model itself.

### 6.1 Network Layer — Tailscale

| Property | Implementation |
|----------|---------------|
| Protocol | WireGuard (encrypted, peer-to-peer) |
| Open ports on router | Zero — Tailscale uses NAT traversal |
| Public IP exposure | None — the Pi is invisible to port scanners |
| Key expiry | Disabled — prevents silent disconnection while owner is away |

### 6.2 SSH Layer — Fail2Ban + UseDNS

| Property | Implementation |
|----------|---------------|
| Brute-force protection | Fail2Ban: 3 failed attempts → 1 hour ban |
| Whitelisted IPs | Loopback, LAN CIDR, both Tailscale IPs |
| DNS lookup | Disabled (`UseDNS no`) — eliminates 10-15s delay over VPN |
| Authentication | Password (SSH key auth planned) |

### 6.3 Agent Gateway — OpenClaw

| Property | Implementation |
|----------|---------------|
| Network binding | `127.0.0.1` (loopback only) |
| External access | Tailscale Serve (private HTTPS reverse proxy) |
| Authentication | 64-character cryptographic token |
| Telegram restriction | `allowFrom` — only the operator's ID is accepted |
| Shell commands | Destructive commands require explicit approval |

### 6.4 AI Model Layer — Gemini Grounding (Mode A)

| Property | Implementation |
|----------|---------------|
| Web research method | Google Search Grounding via Gemini API |
| Who visits websites | Google's crawlers (not the Pi) |
| Prompt injection surface | Reduced — untrusted web content never enters the Pi's local context |

**Limitation:** A sufficiently clever injection could still trick Gemini into returning a "tool call" instruction that the local agent would execute. The shell confirmation gate and Docker sandbox (planned) provide additional defense layers.

## 7. Key Concepts & Learnings

### Cloud-Only Multi-Provider Architecture

The Pi doesn't need to run its own LLM. Three free-tier cloud providers (Groq, Gemini, OpenRouter) deliver faster responses, better reasoning quality, and higher reliability than a single local 3B model — at zero cost. The automatic failover chain in `openclaw.json` handles rate limits transparently, while the `.md` workspace files instruct Claudius to guide the user through manual model switches for web search tasks.

### The .md Files vs. openclaw.json

A critical lesson: the workspace `.md` files (AGENTS.md, IDENTITY.md, etc.) are instructions that the LLM reads and follows as suggestions. They do NOT control actual model routing. The real routing, failover, and provider configuration lives in `openclaw.json`. Both must be kept in sync.

### Mode A Cloud Grounding

When Claudius needs to research something, the query goes to Gemini's servers where Google performs the search. The Pi never visits external websites. This is the primary defense against indirect prompt injection for an unattended device managed from 800 miles away.

### Systemd Daemons

OpenClaw runs as a `systemd --user` service. With `loginctl enable-linger`, it persists across SSH disconnects and survives reboots. The service is named `openclaw-gateway.service` (not `openclaw.service`).

### Rate Limit Management

Free-tier providers have strict limits. Groq allows ~30 requests/minute, Gemini allows 20 requests/day, and OpenRouter's free tier is heavily throttled. The fallback chain handles this automatically, but aggressive testing can exhaust all three providers simultaneously. When this happens, the only fix is time — wait 15-30 minutes for limits to reset.

## 8. Troubleshooting Log

### Lesson 1: Fail2Ban Requires rsyslog
**Issue:** Fail2Ban failed to start. **Root cause:** rsyslog was not installed, so `/var/log/auth.log` didn't exist. **Fix:** `sudo apt install rsyslog`

### Lesson 2: Tailscale Key Expiry (The "102-Day Ghost")
**Issue:** Pi showed "offline, last seen 102d ago." **Root cause:** Default 180-day key expiry elapsed. **Fix:** Disable key expiry in the admin console during initial setup.

### Lesson 3: SSH Lag Over Tailscale
**Issue:** 10-15 second delay on login. **Root cause:** Reverse DNS lookup on Tailscale IPs times out. **Fix:** `UseDNS no` in sshd_config.

### Lesson 4: macOS Tailscale CLI Crash
**Issue:** `tailscale status` crashed with bundleIdentifier error. **Root cause:** App Store sandboxing. **Fix:** Use a shell alias instead of a symlink.

### Lesson 5: .local mDNS Fails When Remote
**Issue:** `aqn-rpios.local` hung when connecting from Seattle. **Root cause:** mDNS only works on the local network. **Fix:** Use Tailscale MagicDNS (`aqn-rpios`) or the Tailscale IP.

### Lesson 6: API Rate Limit Cascade
**Issue:** All three cloud providers rate-limited simultaneously after heavy testing. **Root cause:** Rapid testing exhausted Groq (~30 RPM), Gemini (20/day), and OpenRouter (low free-tier limits) within minutes. **Fix:** Wait 15-30 minutes for limits to reset. Avoid rapid-fire testing across all providers.

### Lesson 7: Together AI Invalid Key (402 Credit Exhausted)
**Issue:** Fallback chain showed "402 Credit limit exceeded" errors. **Root cause:** Together AI account had zero balance despite valid API key. **Fix:** Removed Together AI from the fallback chain entirely and replaced with OpenRouter free tier.

### Lesson 8: Redundant Primary in Fallback Array
**Issue:** Groq was listed as both primary and first fallback, causing it to fail twice on rate limits. **Fix:** Replaced the first fallback with Gemini so the chain actually recovers through different providers.

### Lesson 9: .md Files Don't Route Models
**Issue:** Trigger phrases in AGENTS.md were expected to automatically switch models. **Root cause:** The `.md` files are LLM instructions (suggestions), not config. Actual routing lives in `openclaw.json`. **Fix:** Keep both in sync — `.md` files for LLM guidance, `openclaw.json` for actual failover.

## 9. Future Plans

### Immediate
- Install `uv` and Homebrew to unblock himalaya, summarize, and nano-pdf skills
- Configure persistent journald logging with a 50MB cap
- Add Claude (Anthropic) as a provider for deep reasoning tasks

### Short-Term
- Configure himalaya for email triage (Northeastern Outlook + personal Gmail)
- Expand the morning briefing cron job to include calendar and email digest
- Create interview prep workflows with Claude

### Long-Term
- Migrate state directory to a USB SSD to reduce SD card wear
- Docker-sandbox the agent's shell access for defense-in-depth
- Implement SSH key authentication and disable password auth
- Add a smart plug for remote power cycling
- Explore paid tiers for higher rate limits as usage grows

## Repository Structure

```
rpi5-openclaw-assistant/
├── README.md                          # This file
├── scripts/
│   └── 10-custom-welcome.sh          # Custom MOTD script for SSH login
└── (future: config templates, automation scripts)
```

## Acknowledgments

- [OpenClaw](https://openclaw.ai) — The open-source AI agent framework
- [Tailscale](https://tailscale.com) — WireGuard mesh VPN
- [Fail2Ban](https://github.com/fail2ban/fail2ban) — SSH brute-force protection
- [Groq](https://groq.com) — Fast free-tier LLM inference
- [Google Gemini](https://ai.google.dev) — Web-grounded search via Google AI Studio

---

*First-generation college student, MSCS candidate at Northeastern University. Building the infrastructure that scales AI.*
