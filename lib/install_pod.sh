#!/usr/bin/env bash
# install_pod.sh — Installation complète sur pod RunPod
# Appelé par install.sh quand l'environnement RunPod est détecté.

install_pod() {
    local SCRIPT_DIR="$1"
    local WORKSPACE="${WORKSPACE:-/workspace}"
    local CLAUDE_DIR="${WORKSPACE}/claude"

    # ──────────────────────────────────────────────
    # [1/7] Vérification des prérequis
    # ──────────────────────────────────────────────
    print_step "1/7" "Vérification des prérequis"

    local HAS_NVIDIA=false

    # Python3
    if command -v python3 &>/dev/null; then
        print_ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"
    else
        print_err "python3 non trouvé — requis"
        echo "  Action : apt-get install python3 python3-pip"
        exit 1
    fi

    # pip
    if python3 -m pip --version &>/dev/null; then
        print_ok "pip disponible"
    else
        print_err "pip non trouvé — requis"
        echo "  Action : apt-get install python3-pip"
        exit 1
    fi

    # sshd
    if command -v sshd &>/dev/null || [ -f /usr/sbin/sshd ]; then
        print_ok "sshd disponible"
    else
        print_warn "sshd non trouvé — tentative d'installation..."
        apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null 2>&1
        if [ -f /usr/sbin/sshd ]; then
            print_ok "sshd installé"
        else
            print_err "Impossible d'installer sshd"
            echo "  Action : apt-get update && apt-get install openssh-server"
            exit 1
        fi
    fi

    # nvidia-smi (optionnel)
    if command -v nvidia-smi &>/dev/null; then
        HAS_NVIDIA=true
        print_ok "nvidia-smi disponible (GPU)"
    else
        print_warn "nvidia-smi absent — métriques GPU désactivées"
    fi

    echo ""

    # ──────────────────────────────────────────────
    # [2/7] Structure /workspace standard
    # ──────────────────────────────────────────────
    print_step "2/7" "Création de la structure /workspace"

    mkdir -p "${CLAUDE_DIR}"
    mkdir -p "${CLAUDE_DIR}/hostkeys"
    mkdir -p "${WORKSPACE}/logs"
    mkdir -p "${WORKSPACE}/pids"

    # Initialiser stream.jsonl s'il n'existe pas
    touch "${CLAUDE_DIR}/stream.jsonl"

    # Initialiser monitor_state.json
    if [ ! -f "${CLAUDE_DIR}/monitor_state.json" ]; then
        echo '{"status": "idle", "alerts": [], "last_check": null}' > "${CLAUDE_DIR}/monitor_state.json"
    fi

    print_ok "${CLAUDE_DIR}/"
    print_ok "${CLAUDE_DIR}/hostkeys/"
    print_ok "${WORKSPACE}/logs/"
    print_ok "${WORKSPACE}/pids/"

    echo ""

    # ──────────────────────────────────────────────
    # [3/7] Installation podctl + logd
    # ──────────────────────────────────────────────
    print_step "3/7" "Installation podctl + logd"

    # Copier podctl vers /usr/local/bin/ (actif immédiatement)
    cp "${SCRIPT_DIR}/pod/podctl" /usr/local/bin/podctl
    chmod +x /usr/local/bin/podctl
    print_ok "podctl → /usr/local/bin/podctl"

    # Copier podctl dans /workspace/claude/ (persiste entre reboots)
    cp "${SCRIPT_DIR}/pod/podctl" "${CLAUDE_DIR}/podctl"
    chmod +x "${CLAUDE_DIR}/podctl"
    print_ok "podctl → ${CLAUDE_DIR}/podctl (persistant)"

    # Copier logd.py
    cp "${SCRIPT_DIR}/pod/logd.py" "${CLAUDE_DIR}/logd.py"
    chmod +x "${CLAUDE_DIR}/logd.py"
    print_ok "logd.py → ${CLAUDE_DIR}/logd.py"

    # Installer les dépendances Python
    python3 -m pip install --quiet psutil watchdog 2>/dev/null
    print_ok "Dépendances Python installées (psutil, watchdog)"

    # Test podctl
    if podctl --help >/dev/null 2>&1; then
        print_ok "podctl opérationnel"
    else
        print_err "podctl installé mais non fonctionnel"
        exit 1
    fi

    echo ""

    # ──────────────────────────────────────────────
    # [4/7] Génération hostkeys persistantes
    # ──────────────────────────────────────────────
    print_step "4/7" "Clés et configuration SSH persistantes"

    # Générer les hostkeys dans /workspace/claude/hostkeys/ (persiste)
    if [ ! -f "${CLAUDE_DIR}/hostkeys/ssh_host_ed25519_key" ]; then
        ssh-keygen -t ed25519 \
            -f "${CLAUDE_DIR}/hostkeys/ssh_host_ed25519_key" \
            -N "" -q
        print_ok "Host keys générées dans ${CLAUDE_DIR}/hostkeys/"
    else
        print_ok "Host keys existantes dans ${CLAUDE_DIR}/hostkeys/"
    fi

    # Stocker le template sshd avec des placeholders
    cat > "${CLAUDE_DIR}/sshd_claude.conf.template" << 'SSHD_TEMPLATE'
# sshd configuration dédiée Claude Code
Port 2222
ListenAddress 0.0.0.0
HostKey HOSTKEYS_DIR/ssh_host_ed25519_key
AuthorizedKeysFile AUTH_KEYS_FILE

# Authentification
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin yes
ChallengeResponseAuthentication no
UsePAM no

# Sécurité
X11Forwarding no
PrintMotd no

# Keepalive
ClientAliveInterval 30
ClientAliveCountMax 10

# Logging
LogLevel INFO

# Subsystems
Subsystem sftp /usr/lib/openssh/sftp-server

# Autoriser le forwarding pour Jupyter tunnel
AllowTcpForwarding yes
GatewayPorts no
SSHD_TEMPLATE

    print_ok "Template sshd → ${CLAUDE_DIR}/sshd_claude.conf.template"

    # Créer authorized_keys s'il n'existe pas
    if [ ! -f "${CLAUDE_DIR}/authorized_keys" ]; then
        touch "${CLAUDE_DIR}/authorized_keys"
        chmod 600 "${CLAUDE_DIR}/authorized_keys"
    fi

    # Copier les clés depuis /root/.ssh/authorized_keys si disponibles et authorized_keys vide
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ] && [ ! -s "${CLAUDE_DIR}/authorized_keys" ]; then
        cp /root/.ssh/authorized_keys "${CLAUDE_DIR}/authorized_keys"
        local KEY_COUNT
        KEY_COUNT=$(wc -l < "${CLAUDE_DIR}/authorized_keys")
        print_ok "Clés copiées depuis /root/.ssh/authorized_keys (${KEY_COUNT} clé(s))"
    fi

    echo ""

    # ──────────────────────────────────────────────
    # [5/7] Second sshd sur port 2222
    # ──────────────────────────────────────────────
    print_step "5/7" "Démarrage sshd dédié (port 2222)"

    local SSHD_CONFIG="/etc/ssh/sshd_claude.conf"

    # Vérifier si déjà en cours d'exécution
    if pgrep -f "sshd.*sshd_claude" >/dev/null 2>&1; then
        print_warn "sshd dédié déjà en cours d'exécution — skip"
    else
        # Générer la config active depuis le template
        cp "${CLAUDE_DIR}/sshd_claude.conf.template" "$SSHD_CONFIG"
        sed -i "s|HOSTKEYS_DIR|${CLAUDE_DIR}/hostkeys|g" "$SSHD_CONFIG"
        sed -i "s|AUTH_KEYS_FILE|${CLAUDE_DIR}/authorized_keys|g" "$SSHD_CONFIG"
        print_ok "Configuration sshd active créée"

        # Démarrer le sshd dédié
        /usr/sbin/sshd -f "$SSHD_CONFIG"
        print_ok "sshd démarré sur port 2222"
    fi

    # Test sshd
    if pgrep -f "sshd.*sshd_claude" >/dev/null 2>&1; then
        print_ok "sshd port 2222 actif"
    else
        print_err "sshd port 2222 non démarré"
        echo "  Cause probable : /usr/sbin/sshd absent ou config incorrecte"
        echo "  Action : apt-get install openssh-server && bash install.sh"
        exit 1
    fi

    echo ""

    # ──────────────────────────────────────────────
    # [6/7] Démarrage logd en background
    # ──────────────────────────────────────────────
    print_step "6/7" "Démarrage logd"

    # Vérifier si déjà en cours d'exécution
    if [ -f "${WORKSPACE}/pids/logd.pid" ] && kill -0 "$(cat "${WORKSPACE}/pids/logd.pid")" 2>/dev/null; then
        print_warn "logd déjà en cours d'exécution (PID $(cat "${WORKSPACE}/pids/logd.pid")) — skip"
    else
        PYTHONUNBUFFERED=1 nohup python3 "${CLAUDE_DIR}/logd.py" \
            > "${WORKSPACE}/logs/logd.log" 2>&1 &
        echo $! > "${WORKSPACE}/pids/logd.pid"
        print_ok "logd démarré (PID $(cat "${WORKSPACE}/pids/logd.pid"))"
    fi

    # Test logd (attendre 2s qu'il démarre)
    sleep 2
    if kill -0 "$(cat "${WORKSPACE}/pids/logd.pid" 2>/dev/null)" 2>/dev/null; then
        print_ok "logd actif"
    else
        print_err "logd s'est arrêté — voir ${WORKSPACE}/logs/logd.log"
        tail -20 "${WORKSPACE}/logs/logd.log" 2>/dev/null
        exit 1
    fi

    echo ""

    # ──────────────────────────────────────────────
    # [7/7] Écriture start.sh (persistance reboot)
    # ──────────────────────────────────────────────
    print_step "7/7" "Écriture start.sh"

    cp "${SCRIPT_DIR}/pod/start.sh" "${WORKSPACE}/start.sh"
    chmod +x "${WORKSPACE}/start.sh"
    print_ok "start.sh → ${WORKSPACE}/start.sh"

    echo ""

    # ──────────────────────────────────────────────
    # Résumé final
    # ──────────────────────────────────────────────
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Pod configuré.${NC}"
    echo ""

    # Guidage dépôt clé publique
    if [ -s "${CLAUDE_DIR}/authorized_keys" ]; then
        echo "Clés autorisées actuelles :"
        echo ""
        cat "${CLAUDE_DIR}/authorized_keys"
    else
        echo ""
        echo "════════════════════════════════════════════════════════"
        echo "⚠  Aucune clé Claude Code configurée."
        echo ""
        echo "Sur votre MACHINE LOCALE, exécutez :"
        echo ""
        echo "  cat ~/.ssh/claude_code_ed25519.pub | ssh -p {PORT_22} root@{HOST} \\"
        echo "    'cat >> /workspace/claude/authorized_keys'"
        echo ""
        echo "Ou copiez-collez votre clé publique directement :"
        echo "  (contenu de ~/.ssh/claude_code_ed25519.pub sur votre machine)"
        echo ""
        echo "Puis testez depuis votre machine :"
        echo "  ssh -p 2222 root@{HOST} 'podctl status'"
        echo "════════════════════════════════════════════════════════"
    fi

    echo ""
    echo "Fichiers persistants (survivent aux reboots) :"
    echo "  ${CLAUDE_DIR}/podctl"
    echo "  ${CLAUDE_DIR}/sshd_claude.conf.template"
    echo "  ${CLAUDE_DIR}/hostkeys/"
    echo "  ${CLAUDE_DIR}/authorized_keys"
    echo ""
    echo "Après un reboot du pod, lancez :"
    echo "  /workspace/start.sh"
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
}
