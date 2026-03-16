#!/usr/bin/env bash
# start.sh — Relance services Claude après reboot RunPod.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
CLAUDE_DIR="${WORKSPACE}/claude"
LOGS_DIR="${WORKSPACE}/logs"
PIDS_DIR="${WORKSPACE}/pids"
SSHD_TEMPLATE="${CLAUDE_DIR}/sshd_claude_config.template"
SSHD_CONFIG="/etc/ssh/sshd_claude_config"

mkdir -p "${LOGS_DIR}" "${PIDS_DIR}" "${CLAUDE_DIR}"

echo "═══ Claude Code services — start.sh ═══"

# Réinstallation podctl depuis volume persistant
if [[ -x "${CLAUDE_DIR}/podctl" ]]; then
  install -m 0755 "${CLAUDE_DIR}/podctl" /usr/local/bin/podctl
  echo "✓ podctl réinstallé"
else
  echo "✗ ${CLAUDE_DIR}/podctl absent — relancez install.sh"
fi

# Reconstruction config sshd depuis template persistant
if [[ -f "${SSHD_TEMPLATE}" ]]; then
  install -m 0644 "${SSHD_TEMPLATE}" "${SSHD_CONFIG}"
  pkill -f "sshd.*sshd_claude_config" >/dev/null 2>&1 || true
  /usr/sbin/sshd -f "${SSHD_CONFIG}"
  echo "✓ sshd (port 2222) actif"
else
  echo "✗ template sshd absent (${SSHD_TEMPLATE})"
fi

LOGD_PID_FILE="${PIDS_DIR}/logd.pid"
if [[ -f "${LOGD_PID_FILE}" ]] && kill -0 "$(cat "${LOGD_PID_FILE}")" 2>/dev/null; then
  echo "✓ logd déjà en cours"
else
  if [[ -f "${CLAUDE_DIR}/logd.py" ]]; then
    PYTHONUNBUFFERED=1 nohup python3 "${CLAUDE_DIR}/logd.py" > "${LOGS_DIR}/logd.log" 2>&1 &
    echo $! > "${LOGD_PID_FILE}"
    echo "✓ logd démarré"
  else
    echo "✗ logd.py absent (${CLAUDE_DIR}/logd.py)"
  fi
fi

echo "═══ Tous les services vérifiés ═══"
