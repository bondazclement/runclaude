#!/usr/bin/env bash
# install_pod.sh — Installation complète sur pod RunPod
# Appelé par install.sh quand l'environnement RunPod est détecté.

install_pod() {
    local SCRIPT_DIR="$1"

    # ──────────────────────────────────────────────
    # [1/6] Vérification des prérequis
    # ──────────────────────────────────────────────
    print_step "1/6" "Vérification des prérequis"

    local HAS_NVIDIA=false

    # Python3
    if command -v python3 &>/dev/null; then
        print_ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"
    else
        print_err "python3 non trouvé — requis"
        exit 1
    fi

    # pip
    if python3 -m pip --version &>/dev/null; then
        print_ok "pip disponible"
    else
        print_err "pip non trouvé — requis"
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
    # [2/6] Structure /workspace standard
    # ──────────────────────────────────────────────
    print_step "2/6" "Création de la structure /workspace"

    mkdir -p /workspace/claude
    mkdir -p /workspace/logs
    mkdir -p /workspace/pids

    # Initialiser stream.jsonl s'il n'existe pas
    touch /workspace/claude/stream.jsonl

    # Initialiser monitor_state.json
    if [ ! -f /workspace/claude/monitor_state.json ]; then
        echo '{"status": "idle", "alerts": [], "last_check": null}' > /workspace/claude/monitor_state.json
    fi

    print_ok "/workspace/claude/"
    print_ok "/workspace/logs/"
    print_ok "/workspace/pids/"

    echo ""

    # ──────────────────────────────────────────────
    # [3/6] Installation podctl + logd
    # ──────────────────────────────────────────────
    print_step "3/6" "Installation podctl + logd"

    # Copier podctl
    cp "${SCRIPT_DIR}/pod/podctl" /usr/local/bin/podctl
    chmod +x /usr/local/bin/podctl
    print_ok "podctl → /usr/local/bin/podctl"

    # Copier logd.py
    cp "${SCRIPT_DIR}/pod/logd.py" /workspace/claude/logd.py
    chmod +x /workspace/claude/logd.py
    print_ok "logd.py → /workspace/claude/logd.py"

    # Installer les dépendances Python
    python3 -m pip install --quiet psutil watchdog 2>/dev/null
    print_ok "Dépendances Python installées (psutil, watchdog)"

    echo ""

    # ──────────────────────────────────────────────
    # [4/6] Second sshd sur port 2222
    # ──────────────────────────────────────────────
    print_step "4/6" "Configuration sshd dédié (port 2222)"

    local SSHD_CLAUDE_CONFIG="/etc/ssh/sshd_claude_config"
    local SSHD_CLAUDE_KEYS="/etc/ssh/sshd_claude_authorized_keys"
    local SSHD_CLAUDE_HOSTKEY_DIR="/etc/ssh/claude_hostkeys"

    # Vérifier si déjà en cours d'exécution
    if pgrep -f "sshd.*sshd_claude_config" >/dev/null 2>&1; then
        print_warn "sshd dédié déjà en cours d'exécution — skip"
    else
        # Créer le répertoire pour les host keys dédiées
        mkdir -p "$SSHD_CLAUDE_HOSTKEY_DIR"

        # Générer des host keys dédiées si absentes
        if [ ! -f "${SSHD_CLAUDE_HOSTKEY_DIR}/ssh_host_ed25519_key" ]; then
            ssh-keygen -t ed25519 -f "${SSHD_CLAUDE_HOSTKEY_DIR}/ssh_host_ed25519_key" -N "" -q
            print_ok "Host keys dédiées générées"
        else
            print_ok "Host keys dédiées existantes"
        fi

        # Créer le fichier authorized_keys s'il n'existe pas
        if [ ! -f "$SSHD_CLAUDE_KEYS" ]; then
            touch "$SSHD_CLAUDE_KEYS"
            chmod 600 "$SSHD_CLAUDE_KEYS"
        fi

        # Copier la clé publique depuis authorized_keys root si elle existe
        if [ -f /root/.ssh/authorized_keys ] && [ ! -s "$SSHD_CLAUDE_KEYS" ]; then
            cp /root/.ssh/authorized_keys "$SSHD_CLAUDE_KEYS"
            print_ok "Clés autorisées copiées depuis /root/.ssh/authorized_keys"
        fi

        # Générer la config sshd dédiée
        cat > "$SSHD_CLAUDE_CONFIG" <<SSHD_EOF
# sshd configuration dédiée Claude Code
Port 2222
ListenAddress 0.0.0.0
HostKey ${SSHD_CLAUDE_HOSTKEY_DIR}/ssh_host_ed25519_key
AuthorizedKeysFile ${SSHD_CLAUDE_KEYS}

# Authentification
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin yes
ChallengeResponseAuthentication no
UsePAM no

# Sécurité
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*

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
SSHD_EOF

        print_ok "Configuration sshd dédiée créée"

        # Démarrer le sshd dédié
        /usr/sbin/sshd -f "$SSHD_CLAUDE_CONFIG"
        print_ok "sshd démarré sur port 2222"
    fi

    echo ""

    # ──────────────────────────────────────────────
    # [5/6] Démarrage logd en background
    # ──────────────────────────────────────────────
    print_step "5/6" "Démarrage logd"

    # Vérifier si déjà en cours d'exécution
    if [ -f /workspace/pids/logd.pid ] && kill -0 "$(cat /workspace/pids/logd.pid)" 2>/dev/null; then
        print_warn "logd déjà en cours d'exécution (PID $(cat /workspace/pids/logd.pid)) — skip"
    else
        nohup python3 /workspace/claude/logd.py > /workspace/logs/logd.log 2>&1 &
        echo $! > /workspace/pids/logd.pid
        print_ok "logd démarré (PID $(cat /workspace/pids/logd.pid))"
    fi

    echo ""

    # ──────────────────────────────────────────────
    # [6/6] Écriture start.sh (persistance reboot)
    # ──────────────────────────────────────────────
    print_step "6/6" "Écriture start.sh"

    cp "${SCRIPT_DIR}/pod/start.sh" /workspace/start.sh
    chmod +x /workspace/start.sh
    print_ok "start.sh → /workspace/start.sh"

    echo ""

    # ──────────────────────────────────────────────
    # Résumé final
    # ──────────────────────────────────────────────
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Pod configuré.${NC}"
    echo ""

    if [ -s "$SSHD_CLAUDE_KEYS" ]; then
        echo "Clés autorisées actuelles :"
        echo ""
        cat "$SSHD_CLAUDE_KEYS"
    else
        echo "Aucune clé publique configurée."
        echo "Déposez votre clé publique Claude Code dans :"
        echo "  ${SSHD_CLAUDE_KEYS}"
    fi

    echo ""
    echo "Pour configurer votre machine locale :"
    echo ""
    echo "  git clone https://github.com/bondazclement/runpod-claude-tool.git"
    echo "  cd runpod-claude-tool && bash install.sh"
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
}
