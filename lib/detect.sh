#!/usr/bin/env bash
# detect.sh — Détection robuste de l'environnement

detect_environment() {
    # Critère A — Variables d'environnement RunPod officielles
    if [ -n "${RUNPOD_POD_ID:-}" ] || \
       [ -n "${RUNPOD_DC_ID:-}" ] || \
       [ -n "${RUNPOD_POD_HOSTNAME:-}" ]; then
        echo "runpod"; return 0
    fi

    # Critère B — Fichier marqueur Docker + /workspace accessible en écriture
    if [ -f "/.dockerenv" ] && [ -d "/workspace" ] && [ -w "/workspace" ]; then
        echo "runpod"; return 0
    fi

    # Critère C — Hostname contient "runpod"
    if hostname 2>/dev/null | grep -qi "runpod"; then
        echo "runpod"; return 0
    fi

    # Critère D — /etc/runpod existe (certaines images)
    if [ -f "/etc/runpod" ]; then
        echo "runpod"; return 0
    fi

    # Machine locale — tout le reste
    echo "local"
    return 0
}

# Mode debug — afficher tous les critères évalués
print_detection_debug() {
    echo "=== Detection Debug ==="
    echo "RUNPOD_POD_ID=${RUNPOD_POD_ID:-<unset>}"
    echo "RUNPOD_DC_ID=${RUNPOD_DC_ID:-<unset>}"
    echo "RUNPOD_POD_HOSTNAME=${RUNPOD_POD_HOSTNAME:-<unset>}"
    echo "/.dockerenv exists: $([ -f /.dockerenv ] && echo yes || echo no)"
    echo "/workspace exists+writable: $([ -d /workspace ] && [ -w /workspace ] && echo yes || echo no)"
    echo "hostname: $(hostname 2>/dev/null || echo unknown)"
    echo "HOME=$HOME"
    echo "========================"
}

# Si RUNPOD_TOOL_DEBUG=1, afficher le debug avant de détecter
if [ "${RUNPOD_TOOL_DEBUG:-0}" = "1" ]; then
    print_detection_debug
fi

# Si exécuté directement
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    detect_environment
fi
