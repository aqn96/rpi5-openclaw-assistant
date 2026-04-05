# rpi5-openclaw-assistant

> A Raspberry Pi 5 running 24/7 as a personal AI assistant — accessible from anywhere via Tailscale, controllable through Telegram. The Pi is the gateway; the brain is a local LLM running on a MacBook Pro over the same private network.

**Author:** Andrew Nguyen ([@aqn96](https://github.com/aqn96))
**Status:** Active — Pi in California, operator remote in Seattle
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

| Role | Model | Where |
|------|-------|-------|
| Primary | `qwen3:8b` | MacBook Pro (Apple Silicon, 18GB) via Tailscale |
| Web search + 6 AM cron | `gemini-2.5-flash` | Google API (Mode A grounding) |
| Offline emergency | `qwen3:1.7b` | Pi locally (not in routing chain) |

No cloud LLM fallbacks — by design. See [docs/architecture.md](docs/architecture.md).

## Hardware

| Component | Spec |
|-----------|------|
| Pi Board | Raspberry Pi 5 — 8GB RAM |
| Storage | SanDisk 64GB Extreme A2 microSDXC |
| Cooling | Raspberry Pi 5 Active Cooler |
| Power | CanaKit 45W USB-C PD |
| Inference Host | MacBook Pro (Apple Silicon, 18GB unified memory) |

## Software Stack

| Layer | Technology |
|-------|-----------|
| OS | Raspberry Pi OS 64-bit (Debian 12 Bookworm) |
| Runtime | Node.js 22 LTS |
| AI Agent | OpenClaw 2026.3.1 (systemd daemon on Pi) |
| LLM Runtime | Ollama on Mac (Metal GPU acceleration) |
| Primary Model | qwen3:8b — tool calling, instruction following |
| Coding Agent | Claude Code — SSH from Mac → Pi |
| VPN | Tailscale (WireGuard mesh, MagicDNS) |
| SSH Protection | Fail2Ban (3 attempts → 1h ban) |
| Version Control | GitHub CLI (`gh`) as [@aqn96](https://github.com/aqn96) |

## Setup

### Phase 1 — Base Server (Pi)

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

### Phase 2 — AI Agent Layer (Pi)

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

# Point to Mac Ollama (replace with your Mac's Tailscale IP)
openclaw config set models.providers.ollama.baseUrl "http://<mac-tailscale-ip>:11434"
openclaw config set models.providers.ollama.apiKey "ollama-local"
openclaw config set models.providers.ollama.api "ollama"
openclaw config set models.providers.ollama.models \
  '[{"id":"qwen3:8b","name":"Qwen3 8B","contextWindow":32768,"maxTokens":8192,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}]'
openclaw config set agents.defaults.model.primary "ollama/qwen3:8b"
openclaw config set agents.defaults.model.fallbacks '[]'

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

API key in `~/.openclaw/.env`:

```bash
GEMINI_API_KEY=AIza...
OLLAMA_API_KEY=ollama-local
```

### Phase 3 — Ollama on Mac

```bash
# Install Ollama via brew
brew install ollama

# Pull the model
ollama pull qwen3:8b

# Expose to Tailscale network + set keep-alive
launchctl setenv OLLAMA_HOST "0.0.0.0"
launchctl setenv OLLAMA_KEEP_ALIVE "10m"
brew services restart ollama
```

### Phase 4 — Security Hardening

See [docs/architecture.md](docs/architecture.md#security-layers) for the full security model.

Key decisions:
- Gateway bound to `127.0.0.1`, exposed only via Tailscale Serve (private HTTPS)
- Telegram `allowFrom` restricts access to a single user ID
- Mode A web search — Gemini fetches content, Pi never visits external sites
- Ollama on Mac only reachable via Tailscale (private network, not public internet)

## Service Management

```bash
# Pi
systemctl --user status openclaw-gateway    # Check status
systemctl --user restart openclaw-gateway   # Restart after config changes
openclaw doctor                             # Full diagnostic
openclaw doctor --fix                       # Auto-migrate breaking config changes
openclaw models list                        # Verify model routing
openclaw cron list                          # View scheduled jobs

# Mac
brew services list | grep ollama            # Check Ollama status
ollama list                                 # List available models
ollama ps                                   # Check active inference
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
