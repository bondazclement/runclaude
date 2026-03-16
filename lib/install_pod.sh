#!/usr/bin/env bash
# install_pod.sh — Installation complète sur pod RunPod (idempotente).

install_pod() {
    local SCRIPT_DIR="$1"
    local WORKSPACE="${WORKSPACE:-/workspace}"
    local CLAUDE_DIR="${WORKSPACE}/claude"
    local LOGS_DIR="${WORKSPACE}/logs"
    local PIDS_DIR="${WORKSPACE}/pids"
    local STREAM_FILE="${CLAUDE_DIR}/stream.jsonl"
    local SSHD_TEMPLATE="${CLAUDE_DIR}/sshd_claude_config.template"
    local SSHD_KEYS_PERSIST="${CLAUDE_DIR}/authorized_keys"
    local HOSTKEY_DIR="${CLAUDE_DIR}/hostkeys"

    print_step "1/8" "Vérification des prérequis"
    command -v python3 >/dev/null 2>&1 && print_ok "python3 détecté" || { print_err "python3 non trouvé"; exit 1; }
    python3 -m pip --version >/dev/null 2>&1 && print_ok "pip détecté" || { print_err "pip non trouvé"; exit 1; }

    if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
        print_warn "sshd absent, installation openssh-server"
        apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-server >/dev/null 2>&1 || {
            print_err "Installation openssh-server échouée"; exit 1;
        }
    fi
    print_ok "sshd disponible"

    print_step "2/8" "Création structure persistante ${WORKSPACE}"
    mkdir -p "${CLAUDE_DIR}" "${LOGS_DIR}" "${PIDS_DIR}" "${HOSTKEY_DIR}"
    touch "${STREAM_FILE}"
    [[ -f "${CLAUDE_DIR}/monitor_state.json" ]] || echo '{"status":"idle","alerts":[],"last_check":null}' > "${CLAUDE_DIR}/monitor_state.json"
    print_ok "Structure persistante prête"

    print_step "3/8" "Installation podctl + logd + start.sh"
    install -m 0755 "${SCRIPT_DIR}/pod/podctl" /usr/local/bin/podctl
    install -m 0755 "${SCRIPT_DIR}/pod/podctl" "${CLAUDE_DIR}/podctl"
    install -m 0755 "${SCRIPT_DIR}/pod/logd.py" "${CLAUDE_DIR}/logd.py"
    install -m 0755 "${SCRIPT_DIR}/pod/start.sh" "${WORKSPACE}/start.sh"
    print_ok "Binaires/scripts installés"

    python3 -m pip install --quiet psutil >/dev/null 2>&1 || print_warn "psutil non installé (mode dégradé)"
    if /usr/local/bin/podctl --help >/dev/null 2>&1; then
        print_ok "podctl opérationnel"
    else
        print_err "podctl installé mais non exécutable"
        exit 1
    fi

    print_step "4/8" "Configuration sshd dédié Claude (port 2222)"
    local SSHD_CONFIG="/etc/ssh/sshd_claude_config"
    local SSHD_KEYS="/etc/ssh/sshd_claude_authorized_keys"

    [[ -f "${HOSTKEY_DIR}/ssh_host_ed25519_key" ]] || ssh-keygen -t ed25519 -f "${HOSTKEY_DIR}/ssh_host_ed25519_key" -N "" -q
    chmod 600 "${HOSTKEY_DIR}/ssh_host_ed25519_key"

    touch "${SSHD_KEYS_PERSIST}"
    chmod 600 "${SSHD_KEYS_PERSIST}"

    if [[ -s /root/.ssh/authorized_keys ]]; then
      local copied=0
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! grep -Fxq "$line" "${SSHD_KEYS_PERSIST}"; then
          echo "$line" >> "${SSHD_KEYS_PERSIST}"
          copied=$((copied + 1))
          print_ok "Clé copiée: $(echo "$line" | awk '{print $1" "$3}')"
        fi
      done < /root/.ssh/authorized_keys
      [[ $copied -gt 0 ]] && print_ok "${copied} clé(s) copiée(s) depuis /root/.ssh/authorized_keys"
    fi

    ln -sf "${SSHD_KEYS_PERSIST}" "${SSHD_KEYS}"

    cat > "${SSHD_TEMPLATE}" <<TEMPLATE_EOF
Port 2222
ListenAddress 0.0.0.0
HostKey ${HOSTKEY_DIR}/ssh_host_ed25519_key
AuthorizedKeysFile ${SSHD_KEYS}
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin yes
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AllowTcpForwarding yes
GatewayPorts no
ClientAliveInterval 30
ClientAliveCountMax 10
Subsystem sftp /usr/lib/openssh/sftp-server
TEMPLATE_EOF

    install -m 0644 "${SSHD_TEMPLATE}" "${SSHD_CONFIG}"
    pkill -f "sshd.*sshd_claude_config" >/dev/null 2>&1 || true
    /usr/sbin/sshd -f "${SSHD_CONFIG}"
    sleep 1
    if pgrep -f "sshd.*sshd_claude_config" >/dev/null 2>&1; then
        print_ok "sshd port 2222 actif"
    else
        print_err "sshd port 2222 ne démarre pas — vérifier /var/log/auth.log"
        exit 1
    fi

    print_step "5/8" "Démarrage logd"
    if [[ -f "${PIDS_DIR}/logd.pid" ]] && kill -0 "$(cat "${PIDS_DIR}/logd.pid")" 2>/dev/null; then
        print_ok "logd déjà actif"
    else
        PYTHONUNBUFFERED=1 nohup python3 "${CLAUDE_DIR}/logd.py" > "${LOGS_DIR}/logd.log" 2>&1 &
        echo $! > "${PIDS_DIR}/logd.pid"
    fi
    sleep 2
    if kill -0 "$(cat "${PIDS_DIR}/logd.pid")" 2>/dev/null; then
        print_ok "logd démarré et actif"
    else
        print_err "logd s'est arrêté immédiatement — voir ${LOGS_DIR}/logd.log"
        tail -20 "${LOGS_DIR}/logd.log" || true
        exit 1
    fi

    print_step "6/8" "Validation santé"
    /usr/local/bin/podctl health >/dev/null 2>&1 && print_ok "podctl health exécutable" || print_warn "podctl health remonte des avertissements"

    print_step "7/8" "Installation optionnelle module Jupyter"
    echo ""
    echo "Voulez-vous installer le module Jupyter (capture des outputs notebooks) ?"
    echo "Requis : JupyterLab ou Jupyter Server installé sur ce pod."
    read -r -p "[o/n] : " INSTALL_JUPYTER
    if [[ "${INSTALL_JUPYTER}" =~ ^[oOyY]$ ]]; then
        if command -v jupyter >/dev/null 2>&1; then
            python3 -m pip install "${SCRIPT_DIR}/modules/jupyter/" --quiet >/dev/null 2>&1 && print_ok "Module Jupyter installé" || print_warn "Échec installation module Jupyter"
            print_warn "Redémarrez Jupyter Server pour activer l'extension"
        else
            print_warn "Jupyter non trouvé — module non installé"
            print_warn "Pour installer plus tard : pip install <repo>/modules/jupyter/"
        fi
    fi

    print_step "8/8" "Résumé final"
    if [[ ! -s "${SSHD_KEYS_PERSIST}" ]]; then
cat <<'MSG'
════════════════════════════════════════════════════════
⚠ Aucune clé Claude Code configurée.

Pour autoriser l'accès de Claude Code à ce pod, exécutez
cette commande sur votre MACHINE LOCALE :

  ssh-copy-id -i ~/.ssh/claude_code_ed25519.pub \
    -p {PORT_22_DU_POD} root@{HOST_DU_POD}

Puis ajoutez manuellement la clé dans le bon fichier :
  ssh root@{HOST} -p {PORT} \
    "cat /root/.ssh/authorized_keys | tail -1 >> \
    /etc/ssh/sshd_claude_authorized_keys"

Ou collez directement votre clé publique :
  ssh root@{HOST} -p {PORT} \
    "echo 'VOTRE_CLE_PUBLIQUE_ICI' >> \
    /etc/ssh/sshd_claude_authorized_keys"

Après dépôt de la clé, testez :
  ssh -p 2222 root@{HOST} "podctl status"
════════════════════════════════════════════════════════
MSG
    else
        print_ok "Clés Claude configurées dans ${SSHD_KEYS_PERSIST}"
    fi

    print_ok "Installation pod terminée"
}
