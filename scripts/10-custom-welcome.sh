#!/bin/bash

C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[0;37m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RESET='\033[0m'

# ── Header ────────────────────────────────────────────────────────────────────
echo -e "${C_CYAN}${C_BOLD}"
figlet -f big "CLAUDIUS"
echo -e "${C_RESET}"
echo -e "  ${C_WHITE}${C_BOLD}MrOpenClaw${C_RESET}${C_DIM} — Raspberry Pi 5 Command Center${C_RESET}"
echo -e "  ${C_DIM}OpenClaw 2026.4.2  ·  Groq · Gemini · OpenRouter  ·  Tailscale${C_RESET}"
echo ""

# ── System stats ──────────────────────────────────────────────────────────────
HOSTNAME=$(hostname)
KERNEL=$(uname -r)
UPTIME=$(uptime -p)
DATE=$(date +"%a %b %d %Y  %I:%M %p %Z")

if command -v vcgencmd &> /dev/null; then
    CPU_TEMP=$(vcgencmd measure_temp | cut -d'=' -f2)
else
    RAW=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    CPU_TEMP=$([[ -n "$RAW" ]] && printf "%.1f'C" "$(echo "$RAW / 1000" | bc -l)" || echo "N/A")
fi

MEM_INFO=$(free -h | awk '/^Mem:/ {printf "%-6s used  /  %-6s free  /  %-6s total", $3, $4, $2}')
DISK_INFO=$(df -h / | awk 'NR==2 {printf "%-6s used  /  %-6s free  /  %-6s total  (%s)", $3, $4, $2, $5}')

ETH0_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+')
WLAN0_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP 'inet \K[\d.]+')
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "offline")

UPDATES=$(apt list --upgradable 2>/dev/null | grep -vc "Listing...")
if [[ "$UPDATES" -gt 0 ]]; then
    UPDATE_STR="${C_YELLOW}${UPDATES} packages can be upgraded${C_RESET}"
else
    UPDATE_STR="${C_GREEN}up to date${C_RESET}"
fi

# ── OpenClaw gateway status (works when script runs as root) ──────────────────
OC_UID=$(id -u aqnguyen96 2>/dev/null)
if [[ -n "$OC_UID" ]]; then
    OC_STATUS=$(sudo -u aqnguyen96 XDG_RUNTIME_DIR=/run/user/$OC_UID systemctl --user is-active openclaw-gateway 2>/dev/null)
else
    OC_STATUS="unknown"
fi

if [[ "$OC_STATUS" == "active" ]]; then
    OC_SINCE=$(sudo -u aqnguyen96 XDG_RUNTIME_DIR=/run/user/$OC_UID systemctl --user show openclaw-gateway \
        --property=ActiveEnterTimestamp 2>/dev/null | cut -d'=' -f2 \
        | xargs -I{} date -d "{}" +"%b %d, %I:%M %p" 2>/dev/null)
    OC_STR="${C_GREEN}${C_BOLD}● running${C_RESET}${C_DIM}  since ${OC_SINCE}${C_RESET}"
else
    OC_STR="${C_RED}${C_BOLD}● stopped${C_RESET}"
fi

# ── Output ────────────────────────────────────────────────────────────────────
echo -e "  ${C_DIM}──────────────────────────────────────────────────────────────────${C_RESET}"
echo -e "  ${C_WHITE}Host:${C_RESET}           ${C_BOLD}$HOSTNAME${C_RESET}   ${C_DIM}($KERNEL)${C_RESET}"
echo -e "  ${C_WHITE}Date:${C_RESET}           $DATE"
echo -e "  ${C_WHITE}Uptime:${C_RESET}         $UPTIME"
echo -e "  ${C_DIM}──────────────────────────────────────────────────────────────────${C_RESET}"
echo -e "  ${C_MAGENTA}System${C_RESET}"
echo -e "  ${C_WHITE}  CPU Temp:${C_RESET}      $CPU_TEMP"
echo -e "  ${C_WHITE}  Memory:${C_RESET}        $MEM_INFO"
echo -e "  ${C_WHITE}  Disk (/):${C_RESET}      $DISK_INFO"
echo -e "  ${C_WHITE}  Updates:${C_RESET}       $(echo -e $UPDATE_STR)"
echo -e "  ${C_DIM}──────────────────────────────────────────────────────────────────${C_RESET}"
echo -e "  ${C_BLUE}Network${C_RESET}"
echo -e "  ${C_WHITE}  Ethernet:${C_RESET}      ${ETH0_IP:-N/A}"
echo -e "  ${C_WHITE}  Wi-Fi:${C_RESET}         ${WLAN0_IP:-N/A}"
echo -e "  ${C_WHITE}  Tailscale:${C_RESET}     $TAILSCALE_IP"
echo -e "  ${C_DIM}──────────────────────────────────────────────────────────────────${C_RESET}"
echo -e "  ${C_CYAN}OpenClaw${C_RESET}"
echo -e "  ${C_WHITE}  Gateway:${C_RESET}       $(echo -e $OC_STR)"
echo -e "  ${C_DIM}──────────────────────────────────────────────────────────────────${C_RESET}"
echo ""
