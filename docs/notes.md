# Troubleshooting Log & Notes

## Troubleshooting Log

### Issue 1: Fail2Ban Won't Start
**Symptom:** Fail2Ban fails to start after install.
**Root cause:** rsyslog not installed — `/var/log/auth.log` doesn't exist.
**Fix:** `sudo apt install rsyslog && sudo systemctl enable --now rsyslog`

### Issue 2: Tailscale "Offline, Last Seen 102d Ago"
**Symptom:** Pi disappears from Tailscale network.
**Root cause:** Default 180-day key expiry elapsed silently.
**Fix:** Disable Key Expiry in the Tailscale Admin Console during initial setup. Do this immediately after first auth.

### Issue 3: 10-15 Second SSH Login Delay
**Symptom:** Long pause after entering SSH password.
**Root cause:** sshd performs reverse DNS lookup on Tailscale IPs, which times out.
**Fix:** `echo "UseDNS no" | sudo tee -a /etc/ssh/sshd_config && sudo systemctl restart ssh`

### Issue 4: macOS Tailscale CLI Crash
**Symptom:** `tailscale status` crashes with bundleIdentifier error.
**Root cause:** App Store sandboxing prevents symlinks from working correctly.
**Fix:** Use a shell alias instead of a symlink: `alias tailscale='/Applications/Tailscale.app/Contents/MacOS/Tailscale'`

### Issue 5: `.local` Hostname Hangs When Remote
**Symptom:** `ssh user@hostname.local` hangs when connecting from outside the local network.
**Root cause:** mDNS (`.local`) only works on the same local network segment.
**Fix:** Use Tailscale MagicDNS hostname or direct Tailscale IP instead.

### Issue 6: API Rate Limit Cascade
**Symptom:** All cloud providers fail simultaneously.
**Root cause:** Heavy testing exhausted Groq (~30 RPM), Gemini (20 req/day), and OpenRouter free tier within minutes.
**Fix:** Wait 15-30 minutes. Avoid rapid-fire testing across all providers simultaneously.

### Issue 7: Together AI 402 Error
**Symptom:** Fallback chain shows "402 Credit limit exceeded."
**Root cause:** Together AI account had zero balance despite a valid API key.
**Fix:** Removed Together AI from the fallback chain entirely; replaced with OpenRouter free tier.

### Issue 8: Groq Listed as Both Primary and First Fallback
**Symptom:** On rate limits, Groq fails twice before recovering.
**Root cause:** Groq was accidentally added to the fallback array while also being the primary.
**Fix:** Removed Groq from fallbacks — fallback chain should only contain providers different from primary.

### Issue 9: `.md` Files Don't Route Models
**Symptom:** Trigger phrases in AGENTS.md don't automatically switch models.
**Root cause:** The `.md` workspace files are LLM instructions (suggestions), not configuration. Actual routing is in `openclaw.json`.
**Fix:** Keep both in sync. `.md` files guide the LLM's behavior; `openclaw.json` controls actual failover.

### Issue 10: Exec Defaults Changed to YOLO Mode (2026.4.2)
**Symptom:** After upgrading to 2026.4.2, shell commands sent via Telegram execute without a confirmation prompt.
**Root cause:** 2026.4.2 changed the gateway exec default to `security=full, ask=off`. On an unattended Pi this is dangerous.
**Fix:** Explicitly set exec approval policy in `~/.openclaw/exec-approvals.json` or via `openclaw config`. Note: SOUL.md destructive-command gate is a model-layer check, not a hard system block.

### Issue 11: Config Migration Required After 2026.4.2 Upgrade
**Symptom:** Firecrawl web fetch or xAI search configs silently stop working after upgrade.
**Root cause:** 2026.4.2 moved these from `tools.web.*` to `plugins.entries.*` paths.
**Fix:** Run `openclaw doctor --fix` immediately after every upgrade. Make it part of the upgrade routine.

### Issue 12: `providers` Key Breaks OpenClaw Startup
**Symptom:** Service crashes on startup with "Unrecognized key: providers" after a doctor run or config edit.
**Root cause:** The `providers` key (used to configure Ollama's base URL) became an unrecognized key in newer versions. OpenClaw auto-detects local Ollama at `127.0.0.1:11434` without it.
**Fix:** Run `openclaw doctor --fix` to remove the stale key. Ollama provider works without it.

### Issue 13: gemma4:e4b Too Large for Pi 5
**Symptom:** 9.6 GB model pulled, leaving minimal disk headroom and consuming most RAM.
**Root cause:** The E4B variant was pulled without checking its actual size first.
**Fix:** Removed with `ollama rm gemma4:e4b`. Switched to phi4-mini (2.5 GB) which fits comfortably in 8GB RAM.

---

## Local Model Notes

phi4-mini was selected after evaluating several edge-optimized models:

| Model | Size | Verdict |
|-------|------|---------|
| gemma4:e4b | 9.6 GB | Too large — nearly fills all RAM |
| gemma4:e2b | 7.2 GB | Marginal — insufficient headroom |
| phi4-mini | 2.5 GB | Selected — best reasoning/instruction quality for size |
| qwen3:4b | 2.5 GB | Strong alternative if phi4 underperforms |
| qwen3:1.7b | 1.1 GB | Backup option if RAM becomes constrained |

Ollama auto-detected at `http://127.0.0.1:11434/v1` — no manual provider config needed.

---

## Future Plans

### Immediate
- Install `uv` and Homebrew to unblock himalaya, summarize, and nano-pdf skills
- Configure persistent journald logging with a 50MB cap
- Implement SSH key authentication and disable password auth
- Review exec approval policy (Issue 10 above)

### Short-Term
- Configure himalaya for email triage (school + personal Gmail)
- Expand morning briefing to include calendar and email digest
- Create interview prep workflows using Claude Code (SSH from Mac → Pi)

### Long-Term
- Migrate state directory to USB SSD to reduce SD card wear
- Docker-sandbox the agent's shell access for defense-in-depth
- Add a smart plug for remote power cycling
- Explore paid tiers (Groq, Gemini) as usage grows
