#!/usr/bin/env bash
# install_local.sh — Configuration SSH sur machine locale
# Appelé par install.sh quand l'environnement local est détecté.

install_local() {
    local SCRIPT_DIR="$1"
    local SSH_DIR="$HOME/.ssh"
    local KEY_NAME="claude_code_ed25519"
    local KEY_PATH="${SSH_DIR}/${KEY_NAME}"

    echo ""

    # ──────────────────────────────────────────────
    # [1/3] Génération clé SSH dédiée Claude Code
    # ──────────────────────────────────────────────
    print_step "1/3" "Génération clé SSH dédiée Claude Code"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    if [ -f "$KEY_PATH" ]; then
        print_warn "Clé existante détectée : ${KEY_PATH}"
        read -r -p "  Regénérer la clé ? (les pods devront être mis à jour) [o/n] : " REGEN
        if [[ "$REGEN" =~ ^[oOyY]$ ]]; then
            ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "claude-code-$(hostname)-$(date +%Y%m%d)" -q
            print_ok "Clé regénérée : ${KEY_PATH}"
        else
            print_ok "Clé existante conservée"
        fi
    else
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "claude-code-$(hostname)-$(date +%Y%m%d)" -q
        print_ok "Clé générée : ${KEY_PATH}"
    fi

    echo ""

    # ──────────────────────────────────────────────
    # [2/3] Configuration de l'alias SSH
    # ──────────────────────────────────────────────
    print_step "2/3" "Configuration de l'alias SSH"

    local CONFIG_FILE="${SSH_DIR}/config"
    touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo ""
    read -r -p "  Alias du pod (ex: runpod-btc) : " POD_ALIAS

    if [ -z "$POD_ALIAS" ]; then
        print_err "Alias requis"
        exit 1
    fi

    # Vérifier si l'alias existe déjà
    if grep -q "^Host ${POD_ALIAS}$" "$CONFIG_FILE" 2>/dev/null; then
        print_warn "Alias '${POD_ALIAS}' existe déjà dans ${CONFIG_FILE}"
        read -r -p "  Écraser la configuration existante ? [o/n] : " OVERWRITE
        if [[ "$OVERWRITE" =~ ^[oOyY]$ ]]; then
            # Supprimer l'ancien bloc (du Host jusqu'au prochain Host ou fin de fichier)
            local TMP_CONFIG
            TMP_CONFIG=$(mktemp)
            awk -v alias="Host ${POD_ALIAS}" '
                $0 == alias { skip=1; next }
                /^Host / { skip=0 }
                !skip { print }
            ' "$CONFIG_FILE" > "$TMP_CONFIG"
            mv "$TMP_CONFIG" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            print_ok "Ancienne configuration supprimée"
        else
            print_ok "Configuration existante conservée — skip"
            echo ""
            # Passer directement au nettoyage
            _install_local_cleanup "$SCRIPT_DIR" "$KEY_PATH"
            return
        fi
    fi

    read -r -p "  Host SSH RunPod (ex: ssh.runpod.io ou IP) : " SSH_HOST
    read -r -p "  Port SSH RunPod (défaut: 2222) : " SSH_PORT
    SSH_PORT="${SSH_PORT:-2222}"

    # Ajouter le bloc dans ~/.ssh/config
    cat >> "$CONFIG_FILE" <<SSH_EOF

Host ${POD_ALIAS}
  HostName ${SSH_HOST}
  Port ${SSH_PORT}
  User root
  IdentityFile ${KEY_PATH}
  ControlMaster auto
  ControlPath ${SSH_DIR}/cm_%r@%h:%p
  ControlPersist 10m
  StrictHostKeyChecking accept-new
SSH_EOF

    print_ok "Alias '${POD_ALIAS}' ajouté dans ${CONFIG_FILE}"

    echo ""

    # ──────────────────────────────────────────────
    # [3/3] Nettoyage
    # ──────────────────────────────────────────────
    _install_local_cleanup "$SCRIPT_DIR" "$KEY_PATH"
}

_install_local_cleanup() {
    local SCRIPT_DIR="$1"
    local KEY_PATH="$2"

    print_step "3/3" "Nettoyage"

    # Pas de fichiers pod à supprimer sur la machine locale
    # (le repo est intact, on ne touche qu'à ~/.ssh/)
    print_ok "Aucun fichier pod à nettoyer"

    echo ""

    # ──────────────────────────────────────────────
    # Résumé final
    # ──────────────────────────────────────────────
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Configuration terminée.${NC}"
    echo ""
    echo "Clé publique à déposer sur le pod :"
    echo ""
    cat "${KEY_PATH}.pub"
    echo ""
    echo "Déposez-la sur le pod RunPod :"
    echo ""
    echo "  cat ~/.ssh/claude_code_ed25519.pub | ssh -p {PORT_22} root@{HOST} \\"
    echo "    'cat >> /workspace/claude/authorized_keys'"
    echo ""
    echo "Puis testez la connexion :"
    echo "  ssh runpod-{alias} 'podctl status'"
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
}
