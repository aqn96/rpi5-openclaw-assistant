# rpi5-openclaw-assistant

> A Raspberry Pi 5 (8GB) running as a 24/7 AI personal assistant — accessible from anywhere via Tailscale, controllable through Telegram. Powered by OpenClaw with a local-first hybrid model stack.

**Author:** Andrew Nguyen ([@aqn96](https://github.com/aqn96))
**Status:** Active — managed remotely from a secondary location (~800 miles away)
**Bot:** MrOpenClaw (codename: Claudius)

## What It Does

- Responds to natural language commands via Telegram from anywhere in the world
- Searches the live web via Gemini's Google Search Grounding (Pi never visits external sites)
- Runs terminal commands on the Pi with confirmation gating for destructive operations
- Delivers a daily morning news briefing at 6 AM (Pacific) via scheduled cron job
- Tracks GitHub repos, commits, and PRs via the authenticated `gh` CLI
- Reports system health (CPU temp, RAM, disk, network) on demand
- Remembers context across sessions via the session-memory hook

## Model Stack

| Role | Model | Notes |
|------|-------|-------|
| Primary | `ollama/phi4-mini` (local) | All chat — zero API cost, fully offline |
| Fallback 1 | `groq/llama-3.3-70b-versatile` | Cloud LLM fallback |
| Fallback 2 | `openrouter/llama-3.3-70b:free` | Last-resort cloud fallback |
| Web search | `google/gemini-2.5-flash` | Pinned for web search tool + 6 AM cron only |

## Hardware

| Component | Spec |
|-----------|------|
| Board | Raspberry Pi 5 — 8GB RAM |
| Storage | SanDisk 64GB Extreme A2 microSDXC |
| Cooling | Raspberry Pi 5 Active Cooler |
| Power | CanaKit 45W USB-C PD |
| Network | Ethernet (primary) + Wi-Fi (backup) |

## Software Stack

| Layer | Technology |
|-------|-----------|
| OS | Raspberry Pi OS 64-bit (Debian 12 Bookworm) |
| Runtime | Node.js 22 LTS |
| AI Agent | OpenClaw 2026.3.1 |
| Local LLM | Ollama + phi4-mini (2.5 GB, Q4) |
| Coding Agent | Claude Code — SSH from Mac → Pi |
| VPN | Tailscale (WireGuard mesh, MagicDNS) |
| SSH Protection | Fail2Ban (3 attempts → 1h ban) |
| Version Control | GitHub CLI (`gh`) as [@aqn96](https://github.com/aqn96) |

## Setup

### Phase 1 — Base Server

```bash
# Flash Raspberry Pi OS (64-bit) via Raspberry Pi Imager
# Enable SSH, set hostname/user/password in OS Customisation

# First boot — SSH in and update
ssh <user>@<hostname>.local
passwd  # Change default password immediately
sudo apt update && sudo apt upgrade -y

# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# → Disable Key Expiry in Tailscale Admin Console

# SSH performance (eliminates 10-15s delay over VPN)
echo "UseDNS no" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart ssh

# Fail2Ban
sudo apt install fail2ban rsyslog
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
# Edit jail.local: bantime=1h, maxretry=3, ignoreip includes your Tailscale IPs
sudo systemctl restart fail2ban

# Custom MOTD
sudo apt install figlet
sudo cp scripts/10-custom-welcome.sh /etc/update-motd.d/10-custom-welcome
sudo chmod +x /etc/update-motd.d/10-custom-welcome
```

### Phase 2 — AI Agent Layer

```bash
# Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# OpenClaw
sudo npm install -g openclaw@latest
openclaw onboard --install-daemon
# Wizard choices: local gateway, loopback bind, token auth,
# Tailscale Serve (NOT Funnel), Node runtime, Telegram channel

# Lock bot to your Telegram ID
openclaw config set channels.telegram.allowFrom "['<your_telegram_id>']"

# Model routing (local-first)
openclaw config set agents.defaults.model.primary "ollama/phi4-mini"
openclaw config set agents.defaults.model.fallbacks \
  '["groq/llama-3.3-70b-versatile", "openrouter/meta-llama/llama-3.3-70b-instruct:free"]'

# Ollama + phi4-mini (local offline model)
curl -fsSL https://ollama.com/install.sh | sh
ollama pull phi4-mini

# Morning news briefing (6 AM daily, Gemini with web search)
openclaw cron add \
  --name "Morning News Briefing" \
  --cron "0 6 * * *" \
  --tz "America/Los_Angeles" \
  --model "google/gemini-2.5-flash" \
  --session isolated \
  --message "Search the web for today's top news headlines — US and world. Brief morning briefing: 5-7 bullet points, most important stories first. Keep it concise and direct." \
  --announce --channel telegram --to "<your_telegram_id>"
```

API keys go in `~/.openclaw/.env`:

```bash
GROQ_API_KEY=gsk_...
GEMINI_API_KEY=AIza...
OPENROUTER_API_KEY=sk-or-v1-...
```

### Phase 3 — Security Hardening

See [docs/architecture.md](docs/architecture.md#security-layers) for the full security model.

Key decisions:
- Gateway bound to `127.0.0.1`, exposed only via Tailscale Serve (private HTTPS)
- Telegram `allowFrom` restricts access to a single user ID
- Mode A web search — Gemini fetches content, Pi never visits external sites

## Service Management

```bash
systemctl --user status openclaw-gateway    # Check status
systemctl --user restart openclaw-gateway   # Restart after config changes
openclaw doctor                             # Full diagnostic
openclaw doctor --fix                       # Auto-migrate breaking config changes
openclaw models status                      # Verify model routing
openclaw cron list                          # View scheduled jobs
```

## Repository Structure

```
rpi5-openclaw-assistant/
├── README.md                    # This file — summary and setup
├── docs/
│   ├── architecture.md          # Design decisions and model routing
│   ├── notes.md                 # Troubleshooting log and future plans
│   └── bitnet-build-guide.md   # Legacy: BitNet local build notes
└── scripts/
    └── 10-custom-welcome.sh    # Custom MOTD for SSH login
```

## Docs

- [Architecture & Design Decisions](docs/architecture.md)
- [Troubleshooting & Notes](docs/notes.md)

---

*Andrew Nguyen ([@aqn96](https://github.com/aqn96)) — First-generation MSCS student. Building infrastructure that scales AI.*
