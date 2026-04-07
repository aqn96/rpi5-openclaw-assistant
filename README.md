# rpi5-openclaw-assistant

> A Raspberry Pi 5 running 24/7 as a personal AI assistant — accessible from anywhere via Tailscale, controllable through two dedicated Telegram bots. The Pi is the always-on gateway; inference is split between a local Mac (free, private) and Claude Code via Anthropic (subscription-backed coding agent).

**Author:** Andrew Nguyen ([@aqn96](https://github.com/aqn96))
**Status:** Active — Pi in California, operator remote in Seattle

## Two-Bot Architecture

| Bot | Name | Purpose | Model |
|-----|------|---------|-------|
| Bot 1 | Claudius (MrOpenClaw) | General assistant — chat, web search, Pi tools, morning briefing | qwen3:8b local on Mac |
| Bot 2 | Apollius | Coding agent — full Claude Code CLI session on Pi | Claude Sonnet (Anthropic, Claude Pro subscription) |

### Bot 1 — Claudius (General Assistant)

- Responds to natural language via Telegram from anywhere
- Searches the live web via Gemini's Google Search Grounding (Pi never visits external sites)
- Runs terminal commands on the Pi with confirmation gating
- Delivers a daily morning news briefing at 6 AM (Pacific)
- Tracks GitHub repos, commits, and PRs via `gh` CLI
- Reports system health on demand
- Remembers context across sessions via session-memory hook
- **Free to run** — inference on local Mac via Ollama, Gemini free tier for web search

### Bot 2 — Apollius (Coding Agent)

- Full Claude Code CLI session running on the Pi, accessible via Telegram
- Direct Telegram → Claude Code path — no local model in the middle
- Runs as a persistent systemd service (`apollius.service`) backed by a tmux PTY
- Requires Claude Pro subscription ($20/month) — uses Anthropic's servers
- Custom slash commands defined in `~/CLAUDE.md`:
  - `/commands` — list available commands
  - `/health` — Pi system health (disk, RAM, CPU temp, uptime)
  - `/reset` — clear session memory and start fresh
  - `/restart` — restart the Apollius service
  - `/clear` — wipe full conversation history (built-in)
  - `/compact` — compress long conversation history (built-in)
- `--dangerously-skip-permissions` enabled — CLAUDE.md handles application-level approval logic instead
- Approval logic: clarify intent first, ask before destructive/irreversible actions only

## Model Stack

| Role | Model | Where |
|------|-------|-------|
| Claudius primary | `qwen3:8b` | MacBook Pro (Apple Silicon, 18GB) via Tailscale |
| Apollius coding agent | `claude-sonnet-4-6` | Anthropic API (Claude Pro subscription) |
| Web search + 6 AM cron | `gemini-2.5-flash` | Google API (Mode A grounding) |
| Offline emergency | `qwen3:1.7b` | Pi locally (not in routing chain) |

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
| General Agent | OpenClaw 2026.3.1 (systemd daemon) |
| Coding Agent | Claude Code CLI v2.1.92 (systemd daemon via tmux PTY) |
| LLM Runtime | Ollama on Mac (Metal GPU acceleration) |
| Primary Model | qwen3:8b — tool calling, instruction following |
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

### Phase 2 — Claudius (General Assistant Bot)

```bash
# Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# OpenClaw
sudo npm install -g openclaw@latest
openclaw onboard --install-daemon
# Wizard: local gateway, loopback bind, token auth,
# Tailscale Serve (NOT Funnel), Node runtime, Telegram channel

# Lock bot to your Telegram ID
openclaw config set channels.telegram.allowFrom "['<your_telegram_id>']"

# Enable streaming so responses appear progressively in Telegram
openclaw config set channels.telegram.streaming partial

# Point to Mac Ollama (replace with your Mac's Tailscale IP)
openclaw config set models.providers.ollama.baseUrl "http://<mac-tailscale-ip>:11434"
openclaw config set models.providers.ollama.apiKey "ollama-local"
openclaw config set models.providers.ollama.api "ollama"
openclaw config set models.providers.ollama.models \
  '[{"id":"qwen3:8b","name":"Qwen3 8B","contextWindow":32768,"maxTokens":8192,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}]'
openclaw config set agents.defaults.model.primary "ollama/qwen3:8b"
openclaw config set agents.defaults.model.fallbacks '[]'

# Session management — auto-reset after 30 min idle
openclaw config set session.reset.idleMinutes 30
openclaw config set agents.defaults.contextPruning.mode "cache-ttl"

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

### Phase 4 — Apollius (Coding Agent Bot)

Requires Claude Pro subscription ($20/month) and Claude Code CLI installed.

```bash
# Install Bun (required by Telegram plugin)
curl -fsSL https://bun.sh/install | bash
source ~/.bashrc

# Install the Telegram plugin for Claude Code
claude plugin install telegram@claude-plugins-official

# Save bot token
mkdir -p ~/.claude/channels/telegram
echo "TELEGRAM_BOT_TOKEN=<your_bot_token>" > ~/.claude/channels/telegram/.env
chmod 600 ~/.claude/channels/telegram/.env

# Pre-trust home directory (avoids interactive dialog on service start)
# Add to ~/.claude/settings.json:
# { "enabledPlugins": {"telegram@claude-plugins-official": true}, "trustedDirectories": ["/home/<user>"] }

# Create CLAUDE.md in home dir — defines slash commands and behavior rules
# See ~/CLAUDE.md in this repo

# Create wrapper script for systemd (needs tmux for real PTY)
sudo apt install tmux
cat > ~/.local/bin/apollius-start.sh << 'EOF'
#!/bin/bash
export PATH="$HOME/.bun/bin:$PATH"
tmux kill-session -t apollius 2>/dev/null
tmux new-session -d -s apollius "claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"
for i in $(seq 1 20); do
    sleep 2
    PANE=$(tmux capture-pane -t apollius -p 2>/dev/null)
    if echo "$PANE" | grep -q "Yes, I trust this folder"; then
        tmux send-keys -t apollius "1" ""
    elif echo "$PANE" | grep -q "Yes, I accept"; then
        tmux send-keys -t apollius "2" ""
    elif echo "$PANE" | grep -q "Listening for channel"; then
        break
    fi
done
EOF
chmod +x ~/.local/bin/apollius-start.sh

# Install as systemd user service
# See ~/.config/systemd/user/apollius.service

systemctl --user daemon-reload
systemctl --user enable apollius
systemctl --user start apollius
```

First-time pairing (one-time):
```bash
# DM your bot on Telegram → it replies with a 6-char code
# Then inside a Claude Code session:
/telegram:access pair <code>
/telegram:access policy allowlist
```

### Phase 5 — Security Hardening

See [docs/architecture.md](docs/architecture.md#security-layers) for the full security model.

Key decisions:
- Claudius gateway bound to `127.0.0.1`, exposed only via Tailscale Serve (private HTTPS)
- Both bots locked to a single Telegram user ID via allowlist policy
- Mode A web search — Gemini fetches content, Pi never visits external sites
- Ollama on Mac only reachable via Tailscale (not public internet)
- Apollius runs `--dangerously-skip-permissions` but CLAUDE.md enforces approval logic

## Service Management

```bash
# Claudius (OpenClaw)
systemctl --user status openclaw-gateway
systemctl --user restart openclaw-gateway
openclaw doctor
openclaw doctor --fix
openclaw models list

# Apollius (Claude Code)
systemctl --user status apollius
systemctl --user restart apollius
tmux attach -t apollius          # Attach to live session for debugging

# Mac (Ollama)
brew services list | grep ollama
ollama list
ollama ps
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
