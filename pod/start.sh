#!/usr/bin/env bash
# start.sh — Relance complète après reboot du pod RunPod
# /workspace/ persiste, /etc/ et /usr/ sont réinitialisés à chaque boot

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
CLAUDE_DIR="${WORKSPACE}/claude"
LOGS_DIR="${WORKSPACE}/logs"
PIDS_DIR="${WORKSPACE}/pids"

echo "═══ Claude Code services — start.sh ═══"
mkdir -p "$LOGS_DIR" "$PIDS_DIR"

# ── 1. Réinstaller podctl (perdu au reboot) ──────────────────────────
if [ -f "${CLAUDE_DIR}/podctl" ]; then
    cp "${CLAUDE_DIR}/podctl" /usr/local/bin/podctl
    chmod +x /usr/local/bin/podctl
    echo "✓ podctl réinstallé"
else
    echo "✗ podctl absent de ${CLAUDE_DIR} — relancez install.sh"
    echo "  Action : git clone https://github.com/bondazclement/runpod-claude-tool.git && cd runpod-claude-tool && bash install.sh"
fi

# ── 2. Recréer sshd_claude_config (perdu au reboot) ──────────────────
SSHD_CONFIG="/etc/ssh/sshd_claude.conf"
SSHD_TEMPLATE="${CLAUDE_DIR}/sshd_claude.conf.template"
HOSTKEYS_DIR="${CLAUDE_DIR}/hostkeys"
AUTH_KEYS="${CLAUDE_DIR}/authorized_keys"

if [ -f "$SSHD_TEMPLATE" ]; then
    cp "$SSHD_TEMPLATE" "$SSHD_CONFIG"
    # Mettre à jour les chemins dans la config copiée
    sed -i "s|HOSTKEYS_DIR|${HOSTKEYS_DIR}|g" "$SSHD_CONFIG"
    sed -i "s|AUTH_KEYS_FILE|${AUTH_KEYS}|g" "$SSHD_CONFIG"
    echo "✓ sshd_claude.conf recréé"
else
    echo "✗ Template sshd absent — relancez install.sh"
    echo "  Cause probable : install.sh n'a jamais été lancé ou /workspace/claude/ a été supprimé"
    echo "  Action : git clone https://github.com/bondazclement/runpod-claude-tool.git && cd runpod-claude-tool && bash install.sh"
fi

# ── 3. Démarrer sshd dédié ───────────────────────────────────────────
if pgrep -f "sshd.*sshd_claude" >/dev/null 2>&1; then
    echo "✓ sshd (port 2222) déjà actif"
elif [ -f "$SSHD_CONFIG" ] && [ -f "${HOSTKEYS_DIR}/ssh_host_ed25519_key" ]; then
    /usr/sbin/sshd -f "$SSHD_CONFIG"
    echo "✓ sshd (port 2222) démarré"
else
    echo "✗ sshd non démarré — config ou hostkeys manquantes"
    echo "  Cause probable : /usr/sbin/sshd absent ou config incorrecte"
    echo "  Action : apt-get install openssh-server && bash install.sh"
fi

# ── 4. Démarrer logd ─────────────────────────────────────────────────
LOGD_SCRIPT="${CLAUDE_DIR}/logd.py"
LOGD_PID_FILE="${PIDS_DIR}/logd.pid"

if [ -f "$LOGD_PID_FILE" ] && kill -0 "$(cat "$LOGD_PID_FILE")" 2>/dev/null; then
    echo "✓ logd déjà actif (PID $(cat "$LOGD_PID_FILE"))"
elif [ -f "$LOGD_SCRIPT" ]; then
    PYTHONUNBUFFERED=1 nohup python3 "$LOGD_SCRIPT" \
        > "${LOGS_DIR}/logd.log" 2>&1 &
    echo $! > "$LOGD_PID_FILE"
    echo "✓ logd démarré (PID $(cat "$LOGD_PID_FILE"))"
else
    echo "✗ logd.py absent — relancez install.sh"
    echo "  Cause probable : install.sh n'a jamais été lancé"
    echo "  Action : bash install.sh"
fi

echo "═══ Vérification finale ═══"
sleep 1
podctl health 2>/dev/null || echo "podctl health check failed — podctl n'est peut-être pas installé"
