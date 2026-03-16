# RunPod × Claude Code Tool System

A complete system for Claude Code to pilot RunPod pods remotely via SSH — execute commands, monitor processes, manage files, and run autonomous long-duration tasks.

## Architecture

```
Machine locale (Fedora)                  Pod RunPod
┌──────────────────────────┐             ┌─────────────────────────────┐
│ Claude Code              │             │ Tool installé via install.sh│
│ + Skill runpod-core      │◄──SSH──────►│ ├── podctl (CLI principale) │
│ + Skill runpod-monitor   │  port 2222  │ ├── logd.py (daemon)        │
│                          │             │ └── sshd dédié port 2222    │
└──────────────────────────┘             └─────────────────────────────┘
```

## Quick Start

### Sur un pod RunPod

```bash
curl -sL https://raw.githubusercontent.com/bondazclement/runpod-claude-tool/main/install.sh | bash
```

Ou cloner et lancer :

```bash
git clone https://github.com/bondazclement/runpod-claude-tool.git
cd runpod-claude-tool
bash install.sh
```

### Sur votre machine locale

```bash
git clone https://github.com/bondazclement/runpod-claude-tool.git
cd runpod-claude-tool
bash install.sh
```

Le script détecte automatiquement l'environnement et installe uniquement ce qui est pertinent.

## Composants

### install.sh
Point d'entrée unique. Détecte si vous êtes sur un pod RunPod ou sur votre machine locale et adapte l'installation.

### podctl
CLI Python — interface unique de Claude Code vers le pod. Toutes les sorties sont en JSON.

```bash
podctl status       # Snapshot global du pod
podctl logs recent 5m  # Logs des 5 dernières minutes
podctl ps           # Processus actifs
podctl gpu          # État GPU
podctl exec 'cmd'   # Exécuter une commande
podctl summary      # Résumé compact (<300 tokens)
```

### logd.py
Daemon collecteur en background. Écrit dans `/workspace/claude/stream.jsonl` :
- Métriques GPU (nvidia-smi) toutes les 5s
- Métriques CPU/RAM/disk (psutil) toutes les 5s
- État des processus actifs toutes les 5s
- Tail des fichiers dans `/workspace/logs/*.log`
- Messages kernel critiques (OOM killer, etc.)

Ring buffer : 50MB max, rotation automatique.

### Module Jupyter (optionnel)
Extension Jupyter Server qui capture tous les outputs de notebooks (stdout, stderr, résultats, erreurs, plots) et les écrit dans le même `stream.jsonl`.

### Skills Claude Code

- **runpod-core** : Skill principal — comment piloter un pod configuré (SSH, podctl, multi-pods)
- **runpod-monitor** : Skill autonome — surveillance de tâches longues, polling structuré, multi-agent, handoff

## Structure du repo

```
├── install.sh                  ← point d'entrée unique
├── lib/
│   ├── detect.sh               ← détection environnement
│   ├── install_pod.sh          ← installation complète pod RunPod
│   └── install_local.sh        ← configuration SSH machine locale
├── pod/
│   ├── podctl                  ← CLI Python, commande principale
│   ├── logd.py                 ← daemon collecteur
│   └── start.sh                ← script de relance au reboot
├── modules/
│   └── jupyter/
│       ├── setup.py            ← package pip installable
│       └── jupyter_logstream/
│           └── __init__.py     ← extension Jupyter Server
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
- ControlMaster pour multiplexage des canaux
- Accès root complet sur le pod via le canal dédié

## Prérequis

### Pod RunPod
- Python 3.x avec pip
- sshd installé
- nvidia-smi (optionnel, pour métriques GPU)

### Machine locale
- SSH client
- Bash

## Licence

MIT
