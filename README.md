# RunPod × Claude Code Tool

Tooling pour piloter des pods RunPod via un `sshd` dédié et `podctl`.

## Pré-requis critiques
- Exposer **le port 2222** à la création du pod (canal dédié Claude Code).
- Lancer `bash install.sh` sur le pod.
- Configurer la machine locale (`~/.ssh/config`, clé `claude_code_ed25519`).

## Persistance RunPod
Sur RunPod, seul `/workspace` persiste.

- Persistants : `/workspace/claude`, `/workspace/logs`, `/workspace/start.sh`.
- Non persistants : `/etc`, `/usr/local/bin`, `/root/.ssh`.

Conséquence : `start.sh` réinstalle `podctl` et régénère `/etc/ssh/sshd_claude_config` depuis `/workspace/claude/sshd_claude_config.template`.

## Installation
```bash
git clone https://github.com/bondazclement/runpod-claude-tool.git
cd runpod-claude-tool
bash install.sh
```

## Commandes utiles
```bash
podctl status
podctl summary
podctl health
podctl watch 30
```
