---
name: runpod-core
description: >
  Charger ce skill dès qu'un pod RunPod est impliqué dans la tâche,
  quel que soit le projet (ML, API, scaling, data pipeline).
  Prérequis : install.sh lancé sur le pod ET port 2222 exposé RunPod.
  Ce skill est le prérequis de runpod-monitor.
  Module optionnel : runpod-monitor pour tâches longues (> 30 minutes).
  Tunnel Jupyter disponible si JupyterLab tourne sur le pod.
---

# RunPod Core — Pilotage de Pod depuis Claude Code

## 1 — Prérequis et contrat

### Ce que install.sh garantit sur le pod

- `podctl` installé dans `/usr/local/bin/podctl` ET sauvegardé dans `/workspace/claude/podctl`
- `logd.py` daemon tournant en background, écrit dans `/workspace/claude/stream.jsonl`
- sshd dédié sur le port 2222 (séparé du port humain)
- Structure `/workspace/claude/`, `/workspace/logs/`, `/workspace/pids/`
- Script `/workspace/start.sh` pour relancer les services après reboot
- Fichiers persistants dans `/workspace/claude/` (survivent aux reboots)

### Ce que la machine locale doit avoir configuré

- Clé SSH ED25519 : `~/.ssh/claude_code_ed25519`
- Alias SSH dans `~/.ssh/config` pour chaque pod (format `runpod-{alias}`)
- ControlMaster activé pour multiplexage des canaux

### Procédure de début de session (OBLIGATOIRE)

Exécuter dans cet ordre exact. Ne pas sauter une étape.

**Étape 1 — Test de connectivité**

```bash
ssh runpod-{alias} "echo connection_ok" 2>&1
```

Si échoue : Pod inaccessible. Dire à l'utilisateur : "Pod inaccessible. Vérifiez que le pod est démarré et que le port 2222 est exposé dans la configuration RunPod." Arrêter.

**Étape 2 — Vérification des services**

```bash
ssh runpod-{alias} "podctl health"
```

Si `command not found` : install.sh n'a pas été lancé. Dire : "podctl absent. Lancez install.sh sur le pod." Arrêter.

Si `healthy: true` : continuer directement.

Si `healthy: false` : tenter la relance automatique :

```bash
ssh runpod-{alias} "/workspace/start.sh"
sleep 3
ssh runpod-{alias} "podctl health"
```

Si toujours `healthy: false` après start.sh : Dire : "Services non récupérables. Le pod a peut-être été recréé. Relancez install.sh sur le pod." Arrêter.

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

### podctl health

Évaluation binaire de l'état du pod.

```bash
ssh runpod-{alias} "podctl health"
```

Retour : `healthy: true/false` avec détails par check (logd, sshd, stream, disk, gpu).

### podctl watch

Boucle de polling intégrée.

```bash
ssh runpod-{alias} "podctl watch 30"    # poll toutes les 30s
ssh runpod-{alias} "podctl watch 60"    # poll toutes les 60s
```

Émet un JSON summary par cycle. Arrêt propre sur SIGTERM/SIGINT.

### podctl logs

Logs filtrés depuis `stream.jsonl`.

```bash
ssh runpod-{alias} "podctl logs recent 5m"
ssh runpod-{alias} "podctl logs filter error 1h"
ssh runpod-{alias} "podctl logs search 'cuda|oom' 30m"
ssh runpod-{alias} "podctl logs kernel a3f9bc 20"
```

### podctl ps

Processus actifs, triés par CPU%.

```bash
ssh runpod-{alias} "podctl ps"
```

### podctl gpu

État GPU détaillé.

```bash
ssh runpod-{alias} "podctl gpu"
```

### podctl exec

Exécuter une commande avec retour structuré.

```bash
ssh runpod-{alias} "podctl exec 'pip list | grep torch'"
```

Options : `--timeout 60` pour les commandes longues.

### podctl summary

Résumé compact (<300 tokens). Idéal pour le polling en mode monitor.

```bash
ssh runpod-{alias} "podctl summary"
```

### podctl jupyter

Opérations Jupyter (si module installé).

```bash
ssh runpod-{alias} "podctl jupyter kernels"
ssh runpod-{alias} "podctl jupyter outputs a3f9bc 20"
```

## 4 — SSH brut (quand podctl ne suffit pas)

Claude Code a un accès root complet sur le pod.

### Créer un fichier distant

```bash
ssh runpod-{alias} "cat > /workspace/config.yaml << 'FILEEOF'
learning_rate: 0.001
batch_size: 32
FILEEOF"
```

### Lancer un process en background

```bash
ssh runpod-{alias} "PYTHONUNBUFFERED=1 nohup python3 /workspace/train.py > /workspace/logs/training.log 2>&1 & echo \$! > /workspace/pids/training.pid"
```

logd.py capturera automatiquement les logs écrits dans `/workspace/logs/training.log`.

### Transférer des fichiers

```bash
scp -F ~/.ssh/config local_file.py runpod-{alias}:/workspace/
scp -F ~/.ssh/config runpod-{alias}:/workspace/results.json ./
```

## 5 — Gestion multi-pods

Convention : `runpod-{projet}` ou `runpod-{rôle}`.

La clé `~/.ssh/claude_code_ed25519` est partagée entre tous les pods. Déposer la clé publique sur chaque pod dans `/workspace/claude/authorized_keys`.

```bash
ssh runpod-btc "podctl summary"
ssh runpod-api "podctl summary"
```

## 6 — Tunnel Jupyter (API REST)

### Ouvrir le tunnel

```bash
ssh -N -L 8888:localhost:8888 runpod-{alias} &
echo $! > /tmp/jupyter_tunnel_runpod_{alias}.pid
```

### Obtenir le token Jupyter

```bash
ssh runpod-{alias} "podctl exec 'jupyter server list --json 2>/dev/null'"
```

Le token est dans le champ `token` du JSON retourné.

### Vérifier que le tunnel fonctionne

```bash
curl -s http://localhost:8888/api -H "Authorization: token {TOKEN}" | python3 -m json.tool
```

### Lister les kernels actifs

```bash
curl -s http://localhost:8888/api/kernels \
  -H "Authorization: token {TOKEN}"
```

### Fermer le tunnel

```bash
kill $(cat /tmp/jupyter_tunnel_runpod_{alias}.pid)
```

### Quand utiliser le tunnel vs podctl jupyter

- `podctl jupyter kernels` : état rapide, pas besoin de tunnel
- `podctl jupyter outputs` : logs des cellules, pas besoin de tunnel
- API REST directe : pour exécuter du code programmatiquement dans un kernel
- Utiliser le tunnel uniquement quand nécessaire, fermer après usage
