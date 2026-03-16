---
name: runpod-monitor
description: >
  Charger ce skill EN PLUS de runpod-core quand l'utilisateur
  demande de surveiller une tâche longue de façon autonome,
  ou quand une tâche estimée > 30 minutes est lancée sur un pod.
  Prérequis : runpod-core chargé et pod configuré.
  Ne pas charger pour des tâches courtes (< 30 minutes) —
  utiliser runpod-core seul suffit.
---

## Section 1 : Phase de reconnaissance
### 1.1 Commandes de reconnaissance
```bash
ssh runpod-{alias} "podctl health"
ssh runpod-{alias} "podctl summary"
ssh runpod-{alias} "podctl ps"
```

### 1.2 Format du plan de surveillance (template exact)
```text
PLAN_MONITOR:
- objectif:
- durée_estimée:
- fréquence_initiale:
- seuils_anomalies:
- actions_auto:
- besoin_validation_humaine:
```

### 1.3 Règle de validation par l'utilisateur
Toujours faire valider le plan avant d'activer la boucle autonome.

## Section 2 : Boucle de polling structuré
### 2.1 Structure d'un cycle (format exact)
```text
CYCLE N
1) podctl summary
2) podctl logs recent <fenêtre>
3) Analyse anomalies
4) Action auto ou escalade
5) Rapport compact
```

### 2.2 Adaptation de la fréquence (tableau)
| État | Fréquence |
|---|---|
| Stable | 60s |
| Activité élevée | 30s |
| Incident en cours | 10s |

### 2.3 Rapports périodiques (format compact)
```text
[HH:MM] état=OK|WARN|CRIT, gpu=%, erreurs=N, action=...
```

## Section 3 : Gestion du contexte — auto-estimation
### 3.1 Calcul du budget (formule complète)
`budget_restant = budget_total - (tokens_prompt + tokens_logs + tokens_rapports)`

### 3.2 Tableau des trois modes (LÉGER/ÉCONOMIQUE/HANDOFF)
| Mode | Usage |
|---|---|
| LÉGER | logs complets, incidents faibles |
| ÉCONOMIQUE | résumé + erreurs |
| HANDOFF | arrêt monitor, transfert état |

## Section 4 : Mécanisme de handoff
### 4.1 Déclencheurs
- budget contexte faible
- incident critique persistant
- demande utilisateur explicite

### 4.2 Format exact du fichier monitor_handoff.json
```json
{
  "pod": "runpod-alias",
  "ts": 1700000000,
  "last_cycle": 42,
  "state": "warn",
  "open_incidents": [],
  "next_actions": []
}
```

### 4.3 Message à l'utilisateur (template)
```text
HANDOFF: surveillance transférée. Voir /workspace/claude/monitor_handoff.json
```

### 4.4 Procédure de reprise
1. Lire `monitor_handoff.json`
2. Relancer reconnaissance
3. Reprendre à fréquence incident

## Section 5 : Arbre de décision sur les anomalies
### 5.1 Récupérable automatiquement (tableau)
| Anomalie | Action auto |
|---|---|
| logd arrêté | `/workspace/start.sh` |
| sshd dédié arrêté | `/workspace/start.sh` |
| pic GPU court | observer 2 cycles |

### 5.2 Décision humaine requise (tableau avec messages exacts)
| Cas | Message |
|---|---|
| disque <10GB | "Espace faible: valider purge de fichiers ?" |
| job bloqué | "Processus stable sans progrès: redémarrer le job ?" |

### 5.3 Critique — escalade immédiate (tableau)
| Cas | Action |
|---|---|
| OOM répété | alerte immédiate + pause actions |
| stream indisponible | alerte + diagnostic stockage |

### 5.4 Règle d'or
Ne jamais masquer une anomalie critique ; notifier immédiatement.

## Section 6 : Mode multi-agent
### 6.1 Architecture (orchestrateur + DEV + MONITOR)
- Orchestrateur: coordination globale
- DEV: exécution/modification
- MONITOR: surveillance périodique

### 6.2 Format exact de monitor_state.json
```json
{
  "status": "idle|running|warning|critical",
  "last_check": 1700000000,
  "cycle": 0,
  "alerts": []
}
```

### 6.3 Règles de coexistence (liste numérotée)
1. MONITOR ne modifie pas le code applicatif.
2. DEV annonce les redémarrages au MONITOR.
3. Orchestrateur arbitre les conflits d'action.

### 6.4 Gestion du contexte en multi-agent
- MONITOR publie uniquement résumés + anomalies.
- DEV lit les snapshots avant action.
- Handoff si budget global < 20%.
