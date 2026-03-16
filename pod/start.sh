#!/usr/bin/env bash
# start.sh — Relance des services Claude Code après reboot du pod
# Placé dans /workspace/start.sh pour persister entre les redémarrages.

set -euo pipefail

echo "═══ Claude Code services — start.sh ═══"

# ─── sshd dédié port 2222 ────────────────────────────────────────────

SSHD_CONFIG="/etc/ssh/sshd_claude_config"

if pgrep -f "sshd.*sshd_claude_config" >/dev/null 2>&1; then
    echo "✓ sshd (port 2222) déjà en cours"
else
    if [ -f "$SSHD_CONFIG" ]; then
        /usr/sbin/sshd -f "$SSHD_CONFIG"
        echo "✓ sshd (port 2222) démarré"
    else
        echo "✗ sshd config absente — relancez install.sh"
    fi
fi

# ─── logd ─────────────────────────────────────────────────────────────

LOGD_SCRIPT="/workspace/claude/logd.py"
LOGD_PID_FILE="/workspace/pids/logd.pid"

if [ -f "$LOGD_PID_FILE" ] && kill -0 "$(cat "$LOGD_PID_FILE")" 2>/dev/null; then
    echo "✓ logd déjà en cours (PID $(cat "$LOGD_PID_FILE"))"
else
    if [ -f "$LOGD_SCRIPT" ]; then
        mkdir -p /workspace/pids /workspace/logs
        nohup python3 "$LOGD_SCRIPT" > /workspace/logs/logd.log 2>&1 &
        echo $! > "$LOGD_PID_FILE"
        echo "✓ logd démarré (PID $(cat "$LOGD_PID_FILE"))"
    else
        echo "✗ logd.py absent — relancez install.sh"
    fi
fi

echo "═══ Tous les services vérifiés ═══"
