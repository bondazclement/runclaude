#!/usr/bin/env bash
# detect.sh — Détection robuste de l'environnement d'exécution.
# Retourne: runpod | local | ambiguous | unknown

print_detection_debug() {
    if [[ "${RUNPOD_TOOL_DEBUG:-0}" != "1" ]]; then
        return 0
    fi

    {
        echo "[detect] RUNPOD_POD_ID=${RUNPOD_POD_ID:-}"
        echo "[detect] RUNPOD_DC_ID=${RUNPOD_DC_ID:-}"
        echo "[detect] RUNPOD_POD_HOSTNAME=${RUNPOD_POD_HOSTNAME:-}"
        echo "[detect] HOME=${HOME:-}"
        echo "[detect] hostname=$(hostname 2>/dev/null || echo unknown)"
        echo "[detect] /.dockerenv exists=${_crit_docker_file}"
        echo "[detect] /workspace exists=${_crit_workspace_exists}"
        echo "[detect] /workspace writable=${_crit_workspace_writable}"
        echo "[detect] crit_a_runpod_pod_id=${_crit_a}"
        echo "[detect] crit_b_runpod_dc_id=${_crit_b}"
        echo "[detect] crit_c_runpod_hostname=${_crit_c}"
        echo "[detect] crit_d_docker_workspace=${_crit_d}"
        echo "[detect] crit_e_hostname_contains_runpod=${_crit_e}"
    } >&2
}

confirm_ambiguous_environment() {
    local prompt
    prompt="Environnement ambigu détecté (container Docker non identifié RunPod). Continuer comme 'local' ? [y/N]: "

    if [[ ! -t 0 ]]; then
        echo "ambiguous"
        return 1
    fi

    read -r -p "$prompt" reply
    if [[ "$reply" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "local"
        return 0
    fi

    echo "ambiguous"
    return 1
}

detect_environment() {
    _crit_a=false
    _crit_b=false
    _crit_c=false
    _crit_docker_file=false
    _crit_workspace_exists=false
    _crit_workspace_writable=false
    _crit_d=false
    _crit_e=false

    [[ -n "${RUNPOD_POD_ID:-}" ]] && _crit_a=true
    [[ -n "${RUNPOD_DC_ID:-}" ]] && _crit_b=true
    [[ -n "${RUNPOD_POD_HOSTNAME:-}" ]] && _crit_c=true

    [[ -f /.dockerenv ]] && _crit_docker_file=true
    [[ -d /workspace ]] && _crit_workspace_exists=true
    [[ -w /workspace ]] && _crit_workspace_writable=true
    if [[ "${_crit_docker_file}" == true && "${_crit_workspace_exists}" == true && "${_crit_workspace_writable}" == true ]]; then
        _crit_d=true
    fi

    if hostname 2>/dev/null | grep -Eiq 'runpod'; then
        _crit_e=true
    fi

    print_detection_debug

    if [[ "${_crit_a}" == true || "${_crit_b}" == true || "${_crit_c}" == true || "${_crit_d}" == true || "${_crit_e}" == true ]]; then
        echo "runpod"
        return 0
    fi

    if [[ "${_crit_docker_file}" == true && "${_crit_d}" != true ]]; then
        confirm_ambiguous_environment
        return $?
    fi

    if [[ -n "${HOME:-}" ]]; then
        echo "local"
        return 0
    fi

    echo "unknown"
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    detect_environment
fi
