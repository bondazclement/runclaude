#!/usr/bin/env bash
# install.sh — Point d'entrée unique pour RunPod × Claude Code Tool System
# Détecte l'environnement et lance l'installation appropriée.
# Idempotent — peut être relancé sans rien casser.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  RunPod × Claude Code — Installation${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}[$1]${NC} $2"
}

print_ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

print_err() {
    echo -e "  ${RED}✗${NC} $1"
}

# Source la détection d'environnement
source "${SCRIPT_DIR}/lib/detect.sh"

print_header

# Détection
print_step "0/1" "Détection de l'environnement..."
ENV=$(detect_environment)

case "$ENV" in
    runpod)
        print_ok "Environnement RunPod détecté (pod: ${RUNPOD_POD_ID:-inconnu})"
        echo ""
        source "${SCRIPT_DIR}/lib/install_pod.sh"
        install_pod "${SCRIPT_DIR}"
        ;;
    local)
        print_ok "Machine locale détectée"
        echo ""
        echo -e "Cet outil est conçu pour s'installer sur un pod RunPod."
        echo -e "Sur votre machine, voulez-vous configurer les clés SSH pour accéder à vos pods ?"
        echo ""
        read -r -p "[o/n] : " REPLY
        if [[ "$REPLY" =~ ^[oOyY]$ ]]; then
            source "${SCRIPT_DIR}/lib/install_local.sh"
            install_local "${SCRIPT_DIR}"
        else
            echo ""
            echo "Installation annulée."
        fi
        ;;
    *)
        print_err "Environnement non reconnu."
        echo ""
        echo "Ce script doit être lancé soit :"
        echo "  - Sur un pod RunPod (installation complète)"
        echo "  - Sur votre machine locale (configuration SSH)"
        exit 1
        ;;
esac
