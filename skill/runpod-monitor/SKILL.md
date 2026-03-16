---
name: runpod-monitor
description: >
  Charger ce skill EN PLUS de runpod-core quand l'utilisateur
  demande de surveiller une tâche longue de façon autonome,
  ou quand une tâche > 30 minutes est lancée sur un pod.
  Prérequis : runpod-core chargé et pod configuré.
  Décrit : mode autonome, polling structuré, multi-agent,
  gestion du contexte, handoff.
---

# RunPod Monitor — Surveillance autonome de tâches longues

## 1 — Phase de reconnaissance

Avant toute surveillance, faire un audit complet du pod.

### Commandes de reconnaissance

```bash
ssh runpod-{alias} "podctl status"          # état global
ssh runpod-{alias} "podctl ps"              # tous les process
ssh runpod-{alias} "podctl gpu"             # GPU disponible ?
ssh runpod-{alias} "podctl logs recent 10m" # ce qui s'est passé récemment
ssh runpod-{alias} "df -h /workspace"       # espace disque
ssh runpod-{alias} "ls /workspace/logs/"    # quels fichiers de logs existent
```

### Plan de surveillance

À partir de la reconnaissance, générer et présenter ce plan à l'utilisateur AVANT de démarrer :

```
PLAN DE SURVEILLANCE — {nom de la tâche}
═══════════════════════════════════════════════════════
Process critique    : {nom} (PID {x}) — mort = action immédiate
Métriques GPU       : util >80% normal | <30% suspect | 0% = crash
                      RAM : {x}GB/{total}GB attendu | >{seuil}GB = alerte
Logs à surveiller   : {liste des fichiers}
Fréquence polling   : {x}s standard | {y}s si anomalie
Durée estimée       : {x}h
Mode sélectionné    : {LÉGER | ÉCONOMIQUE | HANDOFF} (voir Section 3)

Failure modes anticipés et actions :
  - {failure mode 1} → {action prévue}
  - {failure mode 2} → {action prévue}
  - {failure mode 3} → escalade utilisateur

Confirmer pour démarrer ? [o/n]
```

L'utilisateur DOIT valider le plan avant que la boucle démarre.

## 2 — Boucle de polling structuré

### Structure d'un cycle

```
CYCLE N — {timestamp}
│
├── 1. Snapshot rapide (toujours)
│      ssh pod "podctl summary"
│      → process vivants ? GPU nominal ? RAM OK ? disk OK ?
│
├── 2. Logs depuis dernier cycle
│      ssh pod "podctl logs recent {intervalle}"
│      → nouveaux events ? erreurs ? progression ?
│
├── 3. Évaluation contre le plan
│      → Tout nominal    → attendre {intervalle}
│      → Anomalie mineure → polling accéléré (÷2)
│      → Alerte critique  → intervenir selon arbre de décision
│
└── 4. Rapport de cycle
       → Nominal : une ligne compacte dans la conversation
         "Cycle 12 — Epoch 23/50, loss=0.71, GPU 94%, OK"
       → Anomalie : rapport détaillé avec contexte
```

### Adaptation de la fréquence

| État | Fréquence |
|------|-----------|
| Nominal | poll toutes les {N}s (défini dans le plan) |
| Anomalie détectée | poll toutes les {N/2}s |
| Anomalie critique | poll toutes les 5s + intervention |
| Résolution anomalie | retour à la fréquence nominale |

### Rapports périodiques

| Mode | Fréquence rapport |
|------|-------------------|
| LÉGER | toutes les 10 minutes |
| ÉCONOMIQUE | toutes les 30 minutes |

Format : résumé de période, pas dump de cycles bruts.

## 3 — Gestion du contexte : auto-estimation

Claude Code calcule son budget AVANT de lancer la boucle.

### Calcul du budget

```
Durée estimée de la tâche         : X heures

Tokens par cycle (estimation) :
  podctl summary                  : ~100 tokens
  podctl logs recent {intervalle} : ~200-400 tokens
  analyse + décision              : ~100 tokens
  rapport compact                 : ~50 tokens
  Total par cycle                 : ~450-650 tokens (utiliser 600)

Budget context window monitoring  : 100 000 tokens réservés
Cycles possibles avant saturation : 100 000 / 600 = ~166 cycles

Durée couverte selon fréquence :
  poll 30s → 166 × 30s = ~1h 23min
  poll 60s → 166 × 60s = ~2h 46min
  poll 120s → 166 × 120s = ~5h 32min
```

### Sélection automatique du mode

| Mode | Durée estimée | Fréquence | Logs | Rapports | Compression |
|------|---------------|-----------|------|----------|-------------|
| LÉGER | < 2h | 30s | complets | 10 min | aucune |
| ÉCONOMIQUE | 2-6h | 60-120s | filtrés (erreurs + progression) | 30 min | résumé toutes les 30min |
| HANDOFF | > 6h ou contexte > 80% | 120s | filtrés | 30 min | agressive — 1 ligne/cycle |

## 4 — Mécanisme de handoff

### Déclencheurs

- Contexte atteint 80% d'utilisation
- Durée estimée dépasse les capacités du mode ÉCONOMIQUE

### Fichier de handoff

Générer `/workspace/claude/monitor_handoff.json` :

```json
{
  "generated_at": "2026-03-15T16:00:00Z",
  "reason": "context_80pct",
  "task": {
    "name": "Entraînement TFT BTC",
    "started_at": "2026-03-15T10:00:00Z",
    "estimated_end": "2026-03-15T19:30:00Z"
  },
  "progress": {
    "description": "Epoch 23/50 en cours",
    "last_metric": "loss=0.634, val_loss=0.671",
    "checkpoint_last": "/workspace/checkpoints/epoch_22.pt"
  },
  "surveillance_plan": { "...plan complet..." },
  "last_10_events": [ "...10 derniers events du stream.jsonl..." ],
  "active_alerts": [],
  "pod_state": {
    "gpu_util_pct": 94,
    "ram_used_gb": 45,
    "disk_free_gb": 234,
    "process_pid": 4521,
    "process_alive": true
  },
  "resume_instruction": "Reprendre surveillance depuis epoch 23. Seuils inchangés. Prochain checkpoint attendu dans ~30min."
}
```

### Message à l'utilisateur

```
Mon contexte approche la limite (80%). J'ai sauvegardé l'état complet
dans monitor_handoff.json.

État actuel : Epoch 23/50, loss=0.634, tout nominal. ETA fin : ~3h30

Pour continuer la surveillance, dites-moi :
"Reprends le monitoring" — je chargerai le handoff et continuerai.
```

### Reprise du monitoring

Le nouveau monitor agent :
1. Charge `/workspace/claude/monitor_handoff.json`
2. Vérifie l'état actuel du pod avec `podctl status`
3. Compare avec l'état sauvegardé
4. Reprend la boucle de polling exactement là où l'ancien s'est arrêté

## 5 — Arbre de décision sur les anomalies

### Récupérable automatiquement (agir seul)

| Anomalie | Action |
|----------|--------|
| Disk > 90% | Identifier les checkpoints anciens, supprimer tout sauf les 3 derniers, logger l'action |
| Connexion SSH perdue | Attendre 10s, reconnecter via ControlMaster, escalade après 3 échecs |
| Process zombie (état Z) | `kill -9 {pid}`, escalade immédiate si process critique |

### Décision humaine requise (proposer, attendre confirmation)

| Anomalie | Message |
|----------|---------|
| CUDA OOM | "batch_size actuel = {x}. Suggère {x/2}. Relancer ? [o/n]" |
| Loss NaN ou divergence | "Loss est NaN depuis {n} epochs. Learning rate trop élevé probable. Arrêter l'entraînement ? [o/n]" |
| GPU utilisation = 0% > 2min | "Training potentiellement bloqué (GPU idle depuis {x}min). Investiguer ? [o/n]" |
| Erreur inconnue | Présenter les 20 dernières lignes de log brutes, demander instruction |

### Critique — escalade immédiate (arrêt du mode autonome)

| Anomalie | Action |
|----------|--------|
| Process critique mort sans raison | Sortir du mode autonome, présenter contexte complet, attendre instruction |
| Perte de données potentielle | NE RIEN FAIRE sur le pod, alerter immédiatement |
| Comportement totalement inattendu | Sortir du mode autonome, présenter observations, attendre instruction |

### Règle d'or

> Claude Code n'intervient JAMAIS sur une action irréversible sans confirmation humaine explicite.
> Les actions automatiques sont limitées au nettoyage disk et à la reconnexion SSH.

## 6 — Mode multi-agent

### Architecture

```
Orchestrateur Claude Code
│
├── spawn → Agent DEV
│           Travaille sur le code, modifie des fichiers,
│           debug, itère sur l'architecture
│           Accès : lecture/écriture libre sur le pod
│
└── spawn → Agent MONITOR
            Boucle de polling, surveille le pod,
            détecte les anomalies, rapport structuré
            Accès : lecture seule par défaut
```

### Communication inter-agents

Via `/workspace/claude/monitor_state.json` (MONITOR écrit, DEV lit) :

```json
{
  "last_check": "2026-03-15T14:23:00Z",
  "status": "nominal",
  "alerts": [],
  "current_epoch": 12,
  "gpu_util_pct": 94,
  "ram_used_gb": 45,
  "disk_free_gb": 312,
  "process_alive": true,
  "last_log_line": "Epoch 12/50, loss=0.743, val_loss=0.791",
  "next_check_in_seconds": 60
}
```

### Règles de coexistence

1. **MONITOR** : lecture seule sur le pod par défaut.
   Exception : nettoyage disk et reconnexion SSH (voir arbre décision).

2. **DEV** : lecture/écriture libre, ne modifie pas `monitor_state.json`.

3. **Intervention MONITOR** sur le pod : UNIQUEMENT si validée par l'orchestrateur.

4. Les deux agents **n'écrivent JAMAIS sur le pod simultanément**.
   Arbitrage par l'orchestrateur si conflit.

5. **Niveaux d'alerte MONITOR** :

| Niveau | Comportement |
|--------|-------------|
| INFO | Silencieux, DEV non interrompu |
| WARNING | Dans `monitor_state.json`, DEV informé au prochain point de synchronisation |
| CRITICAL | Orchestrateur interrompt DEV immédiatement, présente la situation à l'utilisateur |

### Gestion du contexte multi-agent

Le MONITOR fait des résumés toutes les 30 minutes (MODE ÉCONOMIQUE).
Il ne garde pas l'historique brut des cycles en contexte.
Seul `monitor_state.json` + le dernier résumé de période restent.
