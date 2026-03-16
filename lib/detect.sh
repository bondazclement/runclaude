#!/usr/bin/env bash
# detect.sh — Détection de l'environnement d'exécution
# Retourne : "runpod", "local", ou "unknown"

detect_environment() {
    # Check 1 — Pod RunPod ?
    if [ -n "$RUNPOD_POD_ID" ] || [ -f /etc/runpod ] || hostname 2>/dev/null | grep -qi runpod; then
        echo "runpod"
        return 0
    fi

    # Check 2 — Machine utilisateur Linux ?
    if [ -n "$HOME" ] && [ "$HOME" != "/root" ] && [ -z "$RUNPOD_POD_ID" ]; then
        echo "local"
        return 0
    fi

    # Check 3 — Root sur une machine non-RunPod (peut être un serveur perso)
    if [ "$HOME" = "/root" ] && [ -z "$RUNPOD_POD_ID" ] && ! [ -f /etc/runpod ]; then
        echo "local"
        return 0
    fi

    echo "unknown"
    return 1
}

# Si exécuté directement (pas sourcé), afficher le résultat
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    detect_environment
fi
