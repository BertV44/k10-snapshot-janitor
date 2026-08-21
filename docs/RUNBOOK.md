# Purge automatisée des snapshots K10 hors seuil d'âge

Versions cibles : **Veeam Kasten 8.5.x et 9.0.x** (CRD `apps.kio.kasten.io/v1alpha1`), OpenShift 4.x et Kubernetes 1.27+.
CLI : `oc` en priorité (autodétection OpenShift), repli `kubectl`.

## Contenu

| Fichier | Rôle |
|---|---|
| `bin/k10-snapshot-janitor.sh` | Script de purge, dry-run par défaut |
| `deploy/cronjob.yaml` | ServiceAccount, RBAC least-privilege, ConfigMap de paramètres, PVC de rapports, CronJob quotidien |
| `deploy/Containerfile` | Image UBI9-minimal + `oc` + `jq` pour le CronJob |
| `test/run-tests.sh` | Suite de tests du moteur de decision, hors cluster |

---

## 1. Ce que le script cible, et pourquoi

### Objet manipulé : `RestorePointContent`, pas `RestorePoint`

[disponible] La documentation est explicite : supprimer un `RestorePoint` **ne libère pas** les artefacts sous-jacents. Seule la suppression du `RestorePointContent` (cluster-scoped) déclenche un `RetireAction` qui réclame les snapshots et les données. Le script agit donc exclusivement sur les `RestorePointContents`.

### Discrimination snapshot local vs export

Le périmètre demandé est **snapshot uniquement, jamais export**. Le discriminant retenu est le label `k10.kasten.io/exportProfile` :

- label absent  -> snapshot local, éligible
- label présent -> restore point exporté vers un location profile, **toujours conservé**

[à valider en lab sur ta version cible] La page « Restore Points » de la doc 9.0.3 ne liste explicitement que `appName`, `appNamespace` et `appType` dans sa section sur les labels automatiques. Le label `exportProfile` est documenté par ailleurs comme moyen de distinguer les restore points exportés. Avant la première exécution en `--apply`, contrôle sur ton cluster :

```bash
# Combien de RPC exportés vs locaux ?
oc get restorepointcontents.apps.kio.kasten.io \
  -l 'k10.kasten.io/exportProfile' -o name | wc -l
oc get restorepointcontents.apps.kio.kasten.io \
  -l '!k10.kasten.io/exportProfile' -o name | wc -l
```

Croise ce comptage avec le dashboard K10. Si l'écart n'est pas cohérent, ne passe pas en `--apply`.

### Horodatage de référence

Le script prend, dans cet ordre : `status.actionTime`, puis `status.scheduledTime`, puis `metadata.creationTimestamp`. [disponible] `scheduledTime` peut être `null` pour les actions on-demand, d'où l'ordre retenu. Un horodatage non parsable donne une décision `KEEP` avec la raison `timestamp-unparseable`, jamais une suppression.

### Avertissement de fond

> [disponible, docs.kasten.io] « Deletion of a RestorePointContent is permanent and overrides retention by a Policy. »

Un snapshot de plus de X jours n'est **pas** nécessairement un orphelin. Une policy GFS légitime conserve des points mensuels ou annuels. Lancer le script avec un seuil de 7 jours et sans restriction supprimera ces points malgré la policy. C'est pour cette raison que le script propose deux modes de restriction, décrits ci-dessous, et que le mode conservateur est celui à privilégier sur un cluster de production.

### Rappel du mécanisme natif

[disponible] Le Garbage Collector K10 nettoie déjà les `RestorePointContents` des backups manuels dont le champ `spec.expiresAt` est dépassé (réglable via l'API ou la page de snapshot manuel de l'UI). Ce script couvre ce que le GC ne couvre pas : les snapshots sans `expiresAt`, ceux issus de policies supprimées, et ceux d'applications retirées du cluster.

---

## 2. Modes de sélection

| Mode | Options | Ce qui est supprimé |
|---|---|---|
| Âge seul (par défaut) | `-d 7` | tout snapshot local de plus de 7 jours, y compris ceux couverts par une policy active |
| Orphelins de policy | `--orphan-policy-only` | snapshots on-demand (sans label `policyName`) et snapshots dont la policy référencée n'existe plus |
| Applications disparues | `--require-unbound` | snapshots dont le `RestorePointContent` est en state `Unbound`, c'est-à-dire dont l'application ou le namespace a été supprimé |
| Conservateur (recommandé) | `--require-unbound --orphan-policy-only` | intersection des deux : uniquement les vrais orphelins |

Le mode conservateur correspond à `CONSERVATIVE_MODE: "true"` dans la ConfigMap.

## 3. Garde-fous

| Garde-fou | Comportement |
|---|---|
| Dry-run par défaut | Aucune suppression sans `--apply`. Le rapport est produit dans tous les cas. |
| `--min-keep N` | Conserve toujours les N snapshots les plus récents par application (`appNamespace/appName`), même hors seuil. Défaut 1 : aucune application ne peut se retrouver sans aucun point de restauration. |
| `--wait-retire N` | Après un `--apply`, attendre jusqu'à N secondes que les `RetireActions` déclenchées passent en `Complete`. 0 = pas d'attente, valeur par défaut du CronJob. Le dépassement du délai est un avertissement, pas une erreur : sur de gros exports, la réclamation est longue. |
| `--max-deletions N` | Sous `--apply`, abandon immédiat en code retour 2 si le nombre de candidats dépasse N. Défaut 50. Protège d'une erreur de filtre ou d'un label manquant. En dry-run, le dépassement est signalé dans le résumé et par la métrique `k10_janitor_over_cap`, mais le code retour reste 0 : un rapport d'identification n'est pas un échec. |
| `--exclude-namespace`, `--exclude-policy`, `--exclude-app` | Exclusions répétables. |
| `--include-namespace` | Restriction à un périmètre, pour un déploiement progressif. |
| Label d'exemption | `k10-janitor/exempt=true` sur un `RestorePointContent` le sort définitivement du périmètre. |
| Exports intouchables | `--include-exports` existe mais est déconseillé et non utilisé par le CronJob. |

Exempter un objet précis :

```bash
oc label restorepointcontents.apps.kio.kasten.io <nom> k10-janitor/exempt=true
```

## 4. Rapports et audit

Chaque exécution écrit dans `--report-dir` quatre fichiers horodatés, le dernier uniquement sous `--apply` par `run_id` :

- `k10-janitor-<run_id>.csv` : une ligne par `RestorePointContent` inventorié, avec `decision`, `reason`, âge, application, policy, tailles, rang
- `k10-janitor-<run_id>.jsonl` : même contenu en JSON Lines, exploitable par `jq` ou une ingestion SIEM
- `k10-janitor-<run_id>.summary.txt` : synthèse lisible, dont la répartition des raisons de conservation
- `k10-janitor-<run_id>.jsonl.audit` : produit uniquement en mode `--apply`, une ligne par suppression avec `deletedAt` et `deleteResult`

Chaque suppression est également tracée sur stderr avec le préfixe `AUDIT`, ce qui la rend récupérable dans les logs du pod et par la chaîne de collecte du cluster.

Métriques Prometheus via `--metrics-file` (format textfile collector) :

```
k10_janitor_last_run_timestamp_seconds
k10_janitor_dry_run
k10_janitor_retention_days
k10_janitor_restorepointcontents_total
k10_janitor_candidates_total
k10_janitor_over_cap
k10_janitor_deleted_total
k10_janitor_failed_total
k10_janitor_reclaimable_bytes
```

[non vérifié] Le textfile collector n'est pas exploitable directement depuis un pod de CronJob sans node-exporter monté sur le même volume. Pour une remontée Grafana, le plus simple est un Pushgateway ou un scrape du PVC par un sidecar. À arbitrer selon le socle de monitoring du client.

## 5. Codes retour

| Code | Signification |
|---|---|
| 0 | Succès, ou dry-run terminé |
| 1 | Au moins une suppression en échec, ou erreur d'exécution |
| 2 | Plafond `--max-deletions` dépassé sous `--apply`, aucune suppression effectuée |
| 3 | Prérequis manquant : `jq`, `oc`/`kubectl` ou API injoignable **ou** `--orphan-policy-only` demandé alors que les policies sont illisibles ou qu'aucune n'a été trouvée dans le namespace K10 |

Sur une sortie 1 de validation d'arguments et sur toutes les sorties 3, aucun
rapport n'est écrit : l'abandon a lieu avant `write_reports`. Les métriques ne
sont pas rafraîchies non plus, le fichier `.prom` conserve donc les valeurs du
run précédent. Surveiller `k10_janitor_last_run_timestamp_seconds` pour
détecter ces abandons.

## 6. Mise en oeuvre

### Exécution manuelle depuis un bastion

```bash
chmod +x bin/k10-snapshot-janitor.sh

# Identification seule
./bin/k10-snapshot-janitor.sh -d 7 -r ./reports

# Périmètre réel, mode conservateur, suppression
./bin/k10-snapshot-janitor.sh -d 7 \
  --require-unbound --orphan-policy-only \
  --exclude-namespace prod-db \
  --min-keep 2 --max-deletions 25 \
  -r ./reports --apply
```

### CronJob in-cluster

```bash
# 1. Image
podman build -t k10-snapshot-janitor:1.0.0 -f deploy/Containerfile .
# puis push vers le registre interne, et remplacer REGISTRY/k10-snapshot-janitor:1.0.0
# dans deploy/cronjob.yaml

# 2. Script dans une ConfigMap
oc -n kasten-io create configmap k10-snapshot-janitor-script \
  --from-file=k10-snapshot-janitor.sh=./bin/k10-snapshot-janitor.sh

# 3. RBAC, PVC, CronJob (livré en dry-run)
oc apply -f deploy/cronjob.yaml

# 4. Test immédiat sans attendre 03:00
oc -n kasten-io create job k10-janitor-manual-01 \
  --from=cronjob/k10-snapshot-janitor
oc -n kasten-io logs -f job/k10-janitor-manual-01
```

Bascule en suppression réelle, après validation des rapports :

```bash
oc -n kasten-io patch configmap k10-snapshot-janitor-config \
  --type merge -p '{"data":{"PURGE_APPLY":"true"}}'
```

Consultation des rapports persistés :

```bash
oc -n kasten-io debug job/k10-janitor-manual-01 -- ls -l /reports
```

Mise à jour du script après modification :

```bash
oc -n kasten-io create configmap k10-snapshot-janitor-script \
  --from-file=k10-snapshot-janitor.sh=./bin/k10-snapshot-janitor.sh \
  --dry-run=client -o yaml | oc apply -f -
```

## 7. Séquence de mise en production recommandée

1. Dry-run manuel sur l'ensemble du cluster, seuil réaliste, sans exclusion. Lire le `summary.txt`, contrôler la répartition des raisons de conservation.
2. Recouper la ligne `dont exports (jamais purges)` avec le nombre d'exports attendu. Un écart signifie que le discriminant `exportProfile` ne se comporte pas comme prévu sur cette version : arrêter là.
3. Passer en `--apply` sur un seul namespace non critique avec `--include-namespace`, puis vérifier dans l'UI K10 que les points attendus ont disparu et que les `RetireActions` sont `Complete`.
4. Élargir le périmètre en mode conservateur, `--max-deletions` bas au départ.
5. Basculer `PURGE_APPLY` à `true` dans la ConfigMap et laisser le CronJob tourner.

## 8. Limites connues

- La réclamation d'espace n'est ni immédiate ni proportionnelle. [disponible] Déduplication, données partagées entre restore points, rétention de versions pour les backups immuables et fenêtres de sécurité peuvent retarder ou annuler le gain. Le champ `reclaimable_bytes` du rapport est une borne supérieure indicative fondée sur `status.physicalSizeBytes`. **[non vérifié]** ce champ était absent sur l'intégralité de l'inventaire du cluster de validation, où le script rapporte donc 0 : voir la section 9.
- Le script ne touche pas aux `ClusterRestorePoints` (ressources cluster-scoped issues des `BackupClusterAction`). À traiter séparément si le besoin apparaît.
- Le script ne cherche pas les `VolumeSnapshots` CSI orphelins au niveau storage, c'est-à-dire non référencés par un `RestorePointContent`. C'est un cas de fuite distinct, à traiter avec une logique dédiée.
- `k10.kasten.io/appType` peut être absent sur les restore points créés par d'anciennes versions de Kasten. **[disponible]** présent sur l'intégralité de l'inventaire en 9.0.3, valeur `namespace`. Le script traite l'absence comme `namespace` et ne s'appuie pas sur ce label pour décider.

## 9. Validation en laboratoire

Constats relevés sur un cluster OpenShift 4.20 (Kubernetes 1.33) portant
**Kasten K10 9.0.3**, sur un inventaire de 8 `RestorePointContents`.
Aucune exécution `--apply` n'a été faite : tout ce qui suit vient de lectures
et de dry-runs.

### Ce qui est confirmé sur 9.0.3

| Hypothèse | Statut |
|---|---|
| Le label `k10.kasten.io/exportProfile` est bien émis sur les restore points exportés | **[disponible]** présent sur 6 des 8 objets, avec des valeurs de profil réelles |
| Son absence identifie un snapshot local | **[disponible]** les 2 objets sans le label sont les snapshots locaux, classés comme tels par le script |
| Le label n'est jamais émis avec une valeur vide | **[non vérifié]** aucune valeur vide sur cet échantillon, mais 6 objets ne prouvent rien. Le moteur teste désormais la présence du label et non sa valeur, l'hypothèse n'a donc plus besoin d'être vraie |
| `RestorePointContent` est cluster-scoped | **[disponible]** confirmé par `oc api-resources` |
| `status.state`, `status.actionTime`, `status.scheduledTime`, `status.restorePointRef` sont présents | **[disponible]** présents sur les 8 objets |
| `k10.kasten.io/appName` et `appNamespace` sont toujours renseignés | **[non vérifié]** présents sur les 8, mais tous sont `Bound`. Le cas à risque reste un objet `Unbound` sans `appName` |

Dry-run de contrôle : 8 objets inventoriés, 2 snapshots locaux, 6 exports,
0 candidat. Les 6 exports sortent en `KEEP export-restorepoint`, les 2
snapshots locaux en `KEEP min-keep-guard` puisque chacun est le seul de son
application. La classification recoupe exactement la présence du label.

### Ce que le laboratoire a corrigé

- **`RestorePointContent` n'est pas un CRD.** Kasten le sert par une APIService
  agrégée, `v1alpha1.apps.kio.kasten.io` vers `aggregatedapis-svc`. Le contrôle
  `oc get crd` de `check_prereqs` échoue donc sur toute installation normale.
  Il émettait un avertissement accusant le RBAC à tort ; c'est désormais une
  ligne d'information.
- **La version K10 se lit dans un label**, `app.kubernetes.io/version` du
  déploiement `app=k10`. L'image est référencée par digest et n'apprend rien.
  Le script lit maintenant le label en priorité.

### Ce qui reste à valider

- **8.5.x.** Rien de ce qui précède n'a été vérifié sur cette version.
- **`status.physicalSizeBytes` et `logicalSizeBytes`** sont absents des 8
  objets, qui sont tous de type `appConfigOnly`, sans données de volume. Le
  script les défaute à 0, donc `reclaimable_bytes` et la ligne « Taille
  physique candidate » rapportent 0. À revalider sur un cluster portant de
  vrais snapshots de volumes avant de se fier à ces chiffres.
- **Comportement d'un export dont le snapshot source a été retiré.** Non
  testé : cela suppose une suppression réelle.
- **Un objet `Unbound` sans `appName`**, cas qui ferait s'effondrer le
  regroupement par application. Absent de cet inventaire.
- Un label supplémentaire, `k10.kasten.io/exportType` (valeur observée
  `appConfigOnly`), co-occurre exactement avec `exportProfile`. Le script ne
  l'utilise pas. Piste pour un discriminant de secours.

## 10. Tests réalisés

Le moteur de décision a été validé hors cluster sur un jeu de 17 `RestorePointContents` simulés couvrant : export récent et export très ancien, snapshot dans le seuil, snapshot hors seuil avec policy active, snapshot dont la policy a été supprimée, snapshot on-demand, snapshot en state `Unbound`, snapshot porteur du label d'exemption, application n'ayant qu'un seul snapshot, horodatage non parsable, namespace exclu, inventaire vide.

Cas de sortie vérifiés : dry-run sans effet de bord, `--apply` avec piste d'audit complète, dépassement de `--max-deletions` sous `--apply` avec code 2 et zéro suppression, dépassement en dry-run avec code 0, échec de suppression avec code 1, `--min-keep 2`, `--include-namespace`, `--require-unbound --orphan-policy-only`.

---

## Sources

- [API and Command Line](https://docs.kasten.io/latest/api/cli)
- [Restore Points](https://docs.kasten.io/latest/api/restorepoints)
- [Actions (RetireAction)](https://docs.kasten.io/latest/api/actions)
- [Garbage Collector](https://docs.kasten.io/latest/operating/garbagecollector)
