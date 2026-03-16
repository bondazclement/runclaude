---
name: runpod-core
description: >
  Charger ce skill dès qu'un pod RunPod est impliqué dans la tâche,
  quel que soit le projet (ML, API, scaling, data pipeline).
  Prérequis : install.sh a été lancé sur le pod ET le port 2222 est
  exposé dans la configuration RunPod.
  Ce skill est le prérequis de runpod-monitor.
  Modules optionnels disponibles :
    - runpod-monitor : tâches longues autonomes (> 30 minutes)
  Tunnel Jupyter disponible si JupyterLab tourne sur le pod.
---

## Section 1 : Prérequis et contrat

### 1.1 Ce que install.sh garantit sur le pod
- `podctl` installé et disponible.
- `logd.py` actif et écrit dans `/workspace/claude/stream.jsonl`.
- `sshd` dédié sur port `2222` avec clé ED25519.
- `/workspace/start.sh` relance les services après reboot.

### 1.2 Ce que la machine locale doit avoir
- Une clé `~/.ssh/claude_code_ed25519`.
- Une entrée `~/.ssh/config` (`Host runpod-{alias}`) pointant vers port `2222`.
- `ssh`, `scp`, `python3` disponibles.

### 1.3 Procédure de début de session (OBLIGATOIRE)
Étape 1 — Vérification de la connexion
```bash
ssh runpod-{alias} "echo ok" 2>&1
```
Si échec → message: _"Impossible de se connecter au pod {alias}. Vérifiez que le pod est démarré et que le port 2222 est exposé sur RunPod."_ puis stop.

Étape 2 — Vérification des services
```bash
ssh runpod-{alias} "podctl status"
```
Si `podctl` absent/échec → message: _"podctl non trouvé. Lancez install.sh sur le pod."_ puis stop.

Si services down :
```bash
ssh runpod-{alias} "/workspace/start.sh"
sleep 3
ssh runpod-{alias} "podctl status"
```
Si toujours down → message: _"Services non récupérables. Le pod a peut-être été recréé. Relancez install.sh sur le pod."_ puis stop.

## Section 2 : Connexion SSH

### 2.1 Format de connexion standard
```bash
ssh runpod-{alias}
```

### 2.2 Configurer un nouveau pod
```bash
bash install.sh
```
Puis configurer `~/.ssh/config` local.

### 2.3 Test de connexion
```bash
ssh runpod-{alias} "podctl health"
```

## Section 3 : Commandes podctl (référence complète)
- `status`
```bash
ssh runpod-{alias} "podctl status"
```
```json
{"type":"status","services":{"logd":{"alive":true}}}
```
- `logs recent/filter/search/kernel`
```bash
ssh runpod-{alias} "podctl logs recent 10m"
ssh runpod-{alias} "podctl logs filter warning 1h"
ssh runpod-{alias} "podctl logs search OOM 1h"
ssh runpod-{alias} "podctl logs kernel abc123 20"
```
- `ps`
```bash
ssh runpod-{alias} "podctl ps"
```
- `gpu`
```bash
ssh runpod-{alias} "podctl gpu"
```
- `exec`
```bash
ssh runpod-{alias} "podctl exec 'python train.py' --timeout 120"
```
- `summary`
```bash
ssh runpod-{alias} "podctl summary"
```
- `health`
```bash
ssh runpod-{alias} "podctl health"
```
- `jupyter`
```bash
ssh runpod-{alias} "podctl jupyter kernels"
```
- `watch`
```bash
ssh runpod-{alias} "podctl watch 30"
```

## Section 4 : SSH brut
- Créer/modifier/lire:
```bash
ssh runpod-{alias} "cat > /workspace/app.py <<'PY'\nprint('ok')\nPY"
ssh runpod-{alias} "cat /workspace/app.py"
```
- Transférer (`scp`):
```bash
scp local.txt runpod-{alias}:/workspace/local.txt
```
- Background:
```bash
ssh runpod-{alias} "nohup python3 train.py > /workspace/logs/train.log 2>&1 & echo $!"
```
- Tuer:
```bash
ssh runpod-{alias} "kill <pid>"
```
- Explorer:
```bash
ssh runpod-{alias} "find /workspace -maxdepth 2 -type f"
```

## Section 5 : Gestion multi-pods
- Convention: `runpod-{projet}-{role}`.
- Vérifier plusieurs pods:
```bash
for h in runpod-a runpod-b; do ssh "$h" "podctl summary"; done
```
- Coordonner:
```bash
ssh runpod-a "podctl exec 'cmd1'" & ssh runpod-b "podctl exec 'cmd2'" & wait
```

## 6 — Tunnel Jupyter (API REST)

### Ouvrir le tunnel
```bash
ssh -N -L 8888:localhost:8888 runpod-{alias} &
echo $! > /tmp/jupyter_tunnel.pid
```

### Obtenir le token Jupyter
```bash
ssh runpod-{alias} "jupyter server list --json 2>/dev/null | python3 -c \
  \"import sys,json; d=json.load(sys.stdin); print(d.get('token',''))\""
```

Ou via podctl exec :
```bash
ssh runpod-{alias} "podctl exec 'jupyter server list --json 2>/dev/null'"
```

### Exécuter une cellule via l'API REST
```python
import requests

JUPYTER_URL = "http://localhost:8888"
TOKEN = "{token}"

headers = {"Authorization": f"token {TOKEN}"}

kernels = requests.get(f"{JUPYTER_URL}/api/kernels", headers=headers).json()
kernel_id = kernels[0]["id"]
```

### Fermer le tunnel
```bash
kill $(cat /tmp/jupyter_tunnel.pid)
```

### Quand utiliser le tunnel vs podctl jupyter
- `podctl jupyter kernels` → état rapide.
- API REST directe → exécution, lecture notebooks, gestion kernels.
- Ouvrir le tunnel uniquement au besoin puis fermer.
