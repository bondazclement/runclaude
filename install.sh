#!/usr/bin/env bash
# install.sh — Point d'entrée unique pour RunPod × Claude Code Tool System

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

print_header() { echo ""; echo -e "${BOLD}════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  RunPod × Claude Code — Installation${NC}"; echo -e "${BOLD}════════════════════════════════════════════════════${NC}"; echo ""; }
print_step() { echo -e "${BLUE}[$1]${NC} $2"; }
print_ok() { echo -e "  ${GREEN}✓${NC} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
print_err() { echo -e "  ${RED}✗${NC} $1"; }

handle_error() {
  local line="$1"
  print_err "Échec installation à la ligne ${line}."
  echo "Cause probable: dépendance manquante, permissions SSH, ou environnement inattendu."
  echo "Action: relancer avec RUNPOD_TOOL_DEBUG=1 bash install.sh pour diagnostic détaillé."
}
trap 'handle_error $LINENO' ERR

source "${SCRIPT_DIR}/lib/detect.sh"

print_header
print_step "0/1" "Détection de l'environnement..."
ENV="$(detect_environment || true)"

case "${ENV}" in
  runpod)
    print_ok "Environnement RunPod détecté (pod: ${RUNPOD_POD_ID:-inconnu})"
    source "${SCRIPT_DIR}/lib/install_pod.sh"
    install_pod "${SCRIPT_DIR}"
    ;;
  local)
    print_ok "Machine locale détectée"
    echo ""
    echo "Configurer les clés SSH locales pour accéder aux pods ?"
    read -r -p "[o/n] : " REPLY
    if [[ "$REPLY" =~ ^[oOyY]$ ]]; then
      source "${SCRIPT_DIR}/lib/install_local.sh"
      install_local "${SCRIPT_DIR}"
    else
      echo "Installation locale annulée."
    fi
    ;;
  ambiguous)
    print_warn "Environnement ambigu (Docker non RunPod)."
    print_warn "Refus de continuer sans confirmation explicite."
    exit 1
    ;;
  *)
    print_err "Environnement non reconnu."
    echo "Ce script doit être lancé sur pod RunPod ou machine locale.";
    exit 1
    ;;
esac
