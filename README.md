# RunPod × Claude Code Tool System

A complete system for Claude Code to pilot RunPod pods remotely via SSH — execute commands, monitor processes, manage files, and run autonomous long-duration tasks.

## Architecture

```
Machine locale (Fedora)                  Pod RunPod (Docker, Ubuntu 24.04)
┌──────────────────────────┐             ┌─────────────────────────────────┐
│ Claude Code              │             │ Tool installé via install.sh    │
│ + Skill runpod-core      │◄──SSH──────►│ ├── podctl  (CLI principale)   │
│ + Skill runpod-monitor   │  port 2222  │ ├── logd.py (daemon collecteur)│
│                          │             │ └── sshd    (port 2222 dédié)  │
└──────────────────────────┘             └─────────────────────────────────┘
```

## Important: Port 2222

Le port **2222 doit être exposé à la création du pod** dans l'interface RunPod (ou via l'API RunPod). C'est le port dédié à Claude Code, séparé du port 22 humain.

## Persistance /workspace

Sur RunPod, seul `/workspace/` (Network Volume) persiste entre les redémarrages. Les répertoires `/etc/`, `/usr/local/bin/`, `/root/` sont réinitialisés à chaque boot. C'est pourquoi :

- `podctl` est sauvegardé dans `/workspace/claude/podctl`
- La config sshd est dans `/workspace/claude/sshd_claude.conf.template`
- Les hostkeys sont dans `/workspace/claude/hostkeys/`
- Les clés autorisées sont dans `/workspace/claude/authorized_keys`
- `/workspace/start.sh` réinstalle tout depuis `/workspace/claude/` au reboot

## Quick Start

### Sur un pod RunPod

```bash
git clone https://github.com/bondazclement/runpod-claude-tool.git
cd runpod-claude-tool
bash install.sh
```

Après chaque reboot du pod :

```bash
/workspace/start.sh
```

### Sur votre machine locale

```bash
git clone https://github.com/bondazclement/runpod-claude-tool.git
cd runpod-claude-tool
bash install.sh
```

Le script détecte automatiquement l'environnement et installe uniquement ce qui est pertinent.

## Composants

### podctl

CLI Python — interface unique de Claude Code vers le pod. Toutes les sorties sont en JSON.

```bash
podctl status       # Snapshot global du pod
podctl health       # Évaluation binaire de l'état
podctl watch 30     # Boucle de polling (30s par cycle)
podctl logs recent 5m  # Logs des 5 dernières minutes
podctl ps           # Processus actifs
podctl gpu          # État GPU
podctl exec 'cmd'   # Exécuter une commande
podctl summary      # Résumé compact (<300 tokens)
podctl jupyter kernels  # Kernels Jupyter
```

### logd.py

Daemon collecteur en background. Écrit dans `/workspace/claude/stream.jsonl` :
- Métriques GPU (nvidia-smi) toutes les 5s — skip si absent
- Métriques CPU/RAM/disk (psutil) toutes les 5s
- État de tous les processus actifs (incluant idle) toutes les 5s
- Tail des fichiers dans `/workspace/logs/*.log`
- Messages kernel critiques (OOM killer, etc.)
- Détection Jupyter au démarrage

Ring buffer : 50MB max, rotation automatique.

### Module Jupyter (optionnel)

Extension Jupyter Server qui capture tous les outputs de notebooks et les écrit dans `stream.jsonl`. Deux stratégies automatiques :
- Event hook (jupyter_server >= 2.0)
- Notebook polling fallback (30s)

Tags `"origin": "human"` vs `"origin": "api"` pour distinguer la source.

Installation : `pip install modules/jupyter/`

### Skills Claude Code

- **runpod-core** : Skill principal — procédure de début de session, commandes podctl, SSH, multi-pods, tunnel Jupyter
- **runpod-monitor** : Skill autonome — surveillance de tâches longues, polling structuré, multi-agent, handoff

## Structure du repo

```
├── install.sh                  ← point d'entrée unique
├── lib/
│   ├── detect.sh               ← détection environnement (robuste)
│   ├── install_pod.sh          ← installation complète pod RunPod
│   └── install_local.sh        ← configuration SSH machine locale
├── pod/
│   ├── podctl                  ← CLI Python, commande principale
│   ├── logd.py                 ← daemon collecteur
│   └── start.sh                ← script de relance au reboot
├── modules/
│   └── jupyter/
│       ├── pyproject.toml      ← package pip installable (PEP 517)
│       └── jupyter_logstream/
│           ├── __init__.py     ← ExtensionApp entry point
│           └── handlers.py     ← capture strategies
├── skill/
│   ├── runpod-core/
│   │   └── SKILL.md            ← skill pilotage pod
│   └── runpod-monitor/
│       └── SKILL.md            ← skill surveillance autonome
└── README.md
```

## Sécurité

- SSH ED25519 dédié (`~/.ssh/claude_code_ed25519`)
- Second sshd sur port 2222 (isolé du port humain)
- PasswordAuthentication désactivé
- ControlMaster pour multiplexage des canaux
- Accès root complet sur le pod via le canal dédié

## Prérequis

### Pod RunPod
- Image de référence : `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404`
- Python 3.x avec pip
- **Port 2222 exposé** à la création du pod
- nvidia-smi (optionnel, pour métriques GPU)

### Machine locale
- SSH client
- Bash

## Licence

MIT
