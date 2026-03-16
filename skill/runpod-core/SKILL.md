---
name: runpod-core
description: >
  Charger ce skill dès qu'un pod RunPod est impliqué dans la tâche,
  quel que soit le projet (ML, API, scaling, data pipeline).
  Prérequis : install.sh a été lancé sur le pod.
  Ce skill est le prérequis de runpod-monitor.
  Modules optionnels disponibles : runpod-monitor (tâches longues autonomes),
  runpod-jupyter (si JupyterLab tourne sur le pod).
---

# RunPod Core — Pilotage de Pod depuis Claude Code

## 1 — Prérequis et contrat

### Ce que install.sh garantit sur le pod

- `podctl` installé dans `/usr/local/bin/podctl`
- `logd.py` daemon tournant en background, écrit dans `/workspace/claude/stream.jsonl`
- sshd dédié sur le port 2222 (séparé du port humain)
- Structure `/workspace/claude/`, `/workspace/logs/`, `/workspace/pids/`
- Script `/workspace/start.sh` pour relancer les services après reboot

### Ce que la machine locale doit avoir configuré

- Clé SSH ED25519 : `~/.ssh/claude_code_ed25519`
- Alias SSH dans `~/.ssh/config` pour chaque pod (format `runpod-{alias}`)
- ControlMaster activé pour multiplexage des canaux

### Vérification avant de commencer

Au début de CHAQUE session impliquant un pod, exécuter :

```bash
ssh runpod-{alias} "podctl status"
```

Si la commande échoue ou si les services sont down :

```bash
ssh runpod-{alias} "/workspace/start.sh"
```

Puis re-vérifier avec `podctl status`.

## 2 — Connexion SSH

### Format de connexion standard

```bash
ssh runpod-{alias} "commande"
```

L'alias est défini dans `~/.ssh/config`. Le ControlMaster gère automatiquement le multiplexage.

### Configurer un nouveau pod

Lancer `install.sh` sur la machine locale et suivre les instructions pour ajouter un nouvel alias.

Manuellement :

```
Host runpod-{alias}
  HostName ssh.runpod.io
  Port 2222
  User root
  IdentityFile ~/.ssh/claude_code_ed25519
  ControlMaster auto
  ControlPath ~/.ssh/cm_%r@%h:%p
  ControlPersist 10m
  StrictHostKeyChecking accept-new
```

### Test de connexion

```bash
ssh runpod-{alias} "podctl status"
```

Le JSON retourné contient hostname, uptime, CPU, RAM, GPU, disk, services.

## 3 — Commandes podctl (référence complète)

Toutes les commandes retournent du JSON.

### podctl status

Snapshot global du pod.

```bash
ssh runpod-{alias} "podctl status"
```

Retour :
```json
{
  "ts": 1700000123,
  "type": "status",
  "hostname": "runpod-abc123",
  "uptime": "up 4 hours, 23 minutes",
  "cpu_pct": 12.3,
  "ram": {"used_gb": 45.2, "total_gb": 64.0, "pct": 70.6},
  "disk": {"used_gb": 120.0, "total_gb": 500.0, "free_gb": 380.0, "pct": 24.0},
  "gpu": [{"index": 0, "name": "A100-SXM4-80GB", "util_pct": 94, "mem_used_mb": 72000, "mem_total_mb": 81920, "temp_c": 62}],
  "services": {"logd": {"pid": 1234, "alive": true}, "sshd_claude": {"pid": 5678, "alive": true}},
  "stream_size_mb": 12.3
}
```

### podctl logs

Logs filtrés depuis `stream.jsonl`.

```bash
# Logs récents
ssh runpod-{alias} "podctl logs recent 5m"

# Filtrer par niveau
ssh runpod-{alias} "podctl logs filter error 1h"

# Recherche par pattern regex
ssh runpod-{alias} "podctl logs search 'cuda|oom' 30m"

# Logs d'un kernel Jupyter spécifique
ssh runpod-{alias} "podctl logs kernel a3f9bc 20"
```

Retour `logs recent` :
```json
{
  "type": "logs_recent",
  "duration": "5m",
  "count": 42,
  "entries": [
    {"ts": 1700000123, "source": "training", "level": "INFO", "msg": "Epoch 42, loss=0.234"},
    {"ts": 1700000125, "source": "system.gpu", "util_pct": 94, "mem_used_mb": 72000, "mem_total_mb": 81920}
  ]
}
```

### podctl ps

Processus actifs, triés par CPU%.

```bash
ssh runpod-{alias} "podctl ps"
```

Retour :
```json
{
  "type": "ps",
  "count": 15,
  "processes": [
    {"pid": 4521, "name": "python3", "cmd": "python3 train.py --epochs 50", "cpu_pct": 340.0, "ram_mb": 12400, "uptime_s": 14400}
  ]
}
```

### podctl gpu

État GPU détaillé.

```bash
ssh runpod-{alias} "podctl gpu"
```

Retour :
```json
{
  "type": "gpu",
  "available": true,
  "gpus": [
    {"index": 0, "name": "A100-SXM4-80GB", "util_pct": 94, "mem_used_mb": 72000, "mem_total_mb": 81920, "temp_c": 62}
  ]
}
```

### podctl exec

Exécuter une commande avec retour structuré.

```bash
ssh runpod-{alias} "podctl exec 'pip list | grep torch'"
```

Retour :
```json
{
  "type": "exec",
  "command": "pip list | grep torch",
  "returncode": 0,
  "stdout": "torch   2.8.0\ntorchaudio   2.8.0\ntorchvision   0.20.0",
  "stderr": "",
  "elapsed_s": 1.23
}
```

Options : `--timeout 60` pour les commandes longues.

### podctl summary

Résumé compact (<300 tokens). Idéal pour le polling en mode monitor.

```bash
ssh runpod-{alias} "podctl summary"
```

Retour :
```json
{
  "ts": 1700000123,
  "type": "summary",
  "services": {"logd": {"pid": 1234, "alive": true}, "sshd_claude": {"pid": 5678, "alive": true}},
  "gpu": "94% util, 72000/81920MB",
  "ram": "45.2/64.0GB (70.6%)",
  "disk": "380.0GB free (24.0% used)",
  "top_proc": "python3 (PID 4521) 340.0% CPU",
  "last_event": {"ts": 1700000120, "source": "training", "msg": "Epoch 42, loss=0.234"}
}
```

### podctl jupyter

Opérations Jupyter (si module installé).

```bash
# Lister les kernels
ssh runpod-{alias} "podctl jupyter kernels"

# Outputs d'un kernel
ssh runpod-{alias} "podctl jupyter outputs a3f9bc 20"
```

## 4 — SSH brut (quand podctl ne suffit pas)

Claude Code a un accès root complet sur le pod. Utiliser SSH brut pour tout ce que podctl ne couvre pas.

### Créer un fichier distant

```bash
ssh runpod-{alias} "cat > /workspace/config.yaml << 'FILEEOF'
learning_rate: 0.001
batch_size: 32
epochs: 50
FILEEOF"
```

### Modifier un fichier distant

```bash
ssh runpod-{alias} "sed -i 's/batch_size: 32/batch_size: 16/' /workspace/config.yaml"
```

### Lire un fichier distant

```bash
ssh runpod-{alias} "cat /workspace/config.yaml"
```

### Transférer des fichiers

```bash
# Local → Pod
scp -F ~/.ssh/config local_file.py runpod-{alias}:/workspace/

# Pod → Local
scp -F ~/.ssh/config runpod-{alias}:/workspace/results.json ./
```

### Lancer un process en background

```bash
ssh runpod-{alias} "nohup python3 /workspace/train.py > /workspace/logs/training.log 2>&1 & echo \$! > /workspace/pids/training.pid"
```

logd.py capturera automatiquement les logs écrits dans `/workspace/logs/training.log`.

### Tuer un process

```bash
ssh runpod-{alias} "kill \$(cat /workspace/pids/training.pid)"
```

### Explorer le filesystem

```bash
ssh runpod-{alias} "ls -la /workspace/"
ssh runpod-{alias} "find /workspace -name '*.py' -type f"
ssh runpod-{alias} "du -sh /workspace/*"
```

## 5 — Gestion multi-pods

### Nommage des alias SSH

Convention : `runpod-{projet}` ou `runpod-{rôle}`

Exemples :
- `runpod-btc` — pod pour le projet BTC
- `runpod-api` — pod servant l'API de production
- `runpod-worker` — pod worker pour les tâches batch

### Vérifier tous les pods

```bash
ssh runpod-btc "podctl summary"
ssh runpod-api "podctl summary"
```

### Coordonner des actions sur plusieurs pods

Exemple : déployer une mise à jour sur pod-api et pod-worker :

```bash
# 1. Upload le nouveau code
scp -F ~/.ssh/config app.py runpod-api:/workspace/app.py
scp -F ~/.ssh/config worker.py runpod-worker:/workspace/worker.py

# 2. Redémarrer les services
ssh runpod-api "kill \$(cat /workspace/pids/api.pid) && nohup python3 /workspace/app.py > /workspace/logs/api.log 2>&1 & echo \$! > /workspace/pids/api.pid"
ssh runpod-worker "kill \$(cat /workspace/pids/worker.pid) && nohup python3 /workspace/worker.py > /workspace/logs/worker.log 2>&1 & echo \$! > /workspace/pids/worker.pid"

# 3. Vérifier
ssh runpod-api "podctl status"
ssh runpod-worker "podctl status"
```

### Même clé SSH pour tous les pods

La clé `~/.ssh/claude_code_ed25519` est partagée entre tous les pods. Déposer la clé publique sur chaque pod via `install.sh` ou manuellement dans `/etc/ssh/sshd_claude_authorized_keys`.
