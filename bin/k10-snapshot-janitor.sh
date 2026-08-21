#!/usr/bin/env bash
# =============================================================================
# k10-snapshot-janitor.sh
#
# OUTIL COMMUNAUTAIRE - NON SUPPORTE PAR VEEAM
#   Projet independant, sans affiliation avec Veeam Software, ni approbation
#   ni parrainage de sa part. Veeam, Kasten et K10 sont des marques de Veeam
#   Software Group GmbH, citees ici au seul titre de l'identification des
#   produits avec lesquels cet outil interagit.
#   Fourni sans aucune garantie. Aucun canal de support editeur ne le couvre :
#   n'ouvrez pas de ticket de support Veeam a son sujet.
#   Cet outil SUPPRIME DES SAUVEGARDES de maniere definitive. Validez-le en
#   lab sur vos propres versions avant toute execution avec --apply.
#
# Purge des RestorePointContents de type SNAPSHOT LOCAL restes au-dela d'un
# seuil d'age (7 jours par defaut) sur Veeam Kasten (K10).
#
# Cible produit  : Veeam Kasten 8.5.x / 9.0.x  (CRD apps.kio.kasten.io/v1alpha1)
# Plateformes    : OpenShift 4.x (oc) et Kubernetes vanilla (kubectl)
# Dependances    : oc ou kubectl, jq >= 1.6, bash >= 4, coreutils
#                  (date, mktemp, wc, tr, cat, cp, mv, tee, sleep, basename).
#                  Ni sed, ni awk, ni grep : toute mise en forme passe par jq.
#                  Aucune syntaxe GNU specifique, le script tourne aussi sur BSD.
#
# MODELE DE DONNEES (documente, docs.kasten.io/latest/api/restorepoints) :
#   - RestorePoint         : namespace de l'application, apps.kio.kasten.io/v1alpha1
#   - RestorePointContent  : cluster-scoped, porte les artefacts reels
#   - Supprimer un RestorePoint ne libere PAS les artefacts sous-jacents.
#     Seule la suppression du RestorePointContent declenche un RetireAction
#     qui reclame les snapshots / donnees exportees.
#   => Ce script agit donc exclusivement sur les RestorePointContents.
#
# DISCRIMINATION SNAPSHOT vs EXPORT :
#   Les restore points exportes vers un location profile portent le label
#   k10.kasten.io/exportProfile. Absence de ce label = snapshot local.
#   Le script ne supprime QUE les objets sans ce label (--include-exports
#   existe mais est volontairement non recommande).
#
# AVERTISSEMENT (docs.kasten.io) :
#   "Deletion of a RestorePointContent is permanent and overrides retention
#    by a Policy."
#   Confirmer qu'un restore point n'est plus necessaire avant de le supprimer.
#
# Codes retour : 0 succes | 1 erreur | 2 plafond de suppression depasse (--apply)
#                3 prerequis manquant
# =============================================================================

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.0.0"
readonly RPC_CRD="restorepointcontents.apps.kio.kasten.io"
readonly POLICY_CRD="policies.config.kio.kasten.io"
readonly RETIRE_CRD="retireactions.actions.kio.kasten.io"
readonly LBL_EXPORT="k10.kasten.io/exportProfile"
readonly LBL_APP="k10.kasten.io/appName"
readonly LBL_NS="k10.kasten.io/appNamespace"
readonly LBL_APPTYPE="k10.kasten.io/appType"
readonly LBL_POLICY="k10.kasten.io/policyName"
readonly LBL_POLICY_NS="k10.kasten.io/policyNamespace"
readonly LBL_RUN="k10.kasten.io/runActionName"
# Cle du label d'exemption. Surchargeable via --exempt-label uniquement, et
# volontairement PAS depuis l'environnement : le CronJob monte sa ConfigMap
# avec envFrom, donc toute cle qui y serait ajoutee deviendrait une variable
# d'environnement. Un LBL_EXEMPT pose la desactiverait en silence toutes les
# exemptions posees sur les objets.
LBL_EXEMPT="k10-janitor/exempt"

# ----------------------------- Valeurs par defaut ----------------------------
# usage() est appelee depuis la boucle de parsing : sans copie figee, un
# "--min-keep 5 -h" afficherait "defaut: 5". On garde donc les defauts a part.
RETENTION_DAYS=7
K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
CLI=""
DRY_RUN=1                # dry-run par defaut : suppression uniquement avec --apply
MAX_DELETIONS=50          # 0 = illimite
MIN_KEEP=1                # nb de snapshots les plus recents toujours conserves par application
REQUIRE_UNBOUND=0         # 1 = ne cibler que les RPC dont l'application a disparu
ORPHAN_POLICY_ONLY=0      # 1 = ne cibler que les RPC sans policy ou dont la policy n'existe plus
POLICY_COUNT="?"          # nombre de policies K10 lues, "?" si la lecture a echoue
OVER_CAP=0                # 1 = candidats au-dela de --max-deletions
INCLUDE_EXPORTS=0         # 1 = inclure aussi les restore points exportes (deconseille)
WAIT_RETIRE=0             # secondes d'attente de completion des RetireActions
REPORT_DIR="${REPORT_DIR:-./k10-janitor-reports}"
METRICS_FILE=""
QUIET=0
declare -a EXCLUDE_NS=()
declare -a INCLUDE_NS=()
declare -a EXCLUDE_POLICY=()
declare -a EXCLUDE_APP=()

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

# --------------------------------- Logging -----------------------------------
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { [[ $QUIET -eq 1 ]] && return 0; printf '%s [%-5s] %s\n' "$(_ts)" "INFO" "$*" >&2; }
warn() { printf '%s [%-5s] %s\n' "$(_ts)" "WARN" "$*" >&2; }
err()  { printf '%s [%-5s] %s\n' "$(_ts)" "ERROR" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Invariant : les codes retour restent 0, 1, 2 ou 3. Sans ce piege, l'echec
# d'un jq ou d'un utilitaire propage son propre code via 'set -e' (jq sort en
# 5 sur une erreur de programme). 'set -E' plus haut le fait suivre dans les
# fonctions et les sous-shells.
trap 'err "Erreur inattendue (ligne $LINENO)"; exit 1' ERR

readonly DEF_RETENTION_DAYS="$RETENTION_DAYS"
readonly DEF_MIN_KEEP="$MIN_KEEP"
readonly DEF_MAX_DELETIONS="$MAX_DELETIONS"
readonly DEF_K10_NAMESPACE="$K10_NAMESPACE"
readonly DEF_REPORT_DIR="$REPORT_DIR"

usage() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION - purge des snapshots K10 au-dela d'un seuil d'age

USAGE
  $SCRIPT_NAME [options]

SELECTION
  -d, --retention-days N     Age minimum en jours pour qu'un snapshot soit candidat (defaut: $DEF_RETENTION_DAYS)
      --require-unbound      Ne cibler que les RestorePointContents en state Unbound
                             (application/namespace supprime cote cluster)
      --orphan-policy-only   Ne cibler que les RPC sans label $LBL_POLICY
                             ou dont la policy referencee n'existe plus
      --include-exports      Inclure aussi les restore points exportes (DECONSEILLE)
      --include-namespace NS Restreindre a ce namespace applicatif (repetable)
      --exclude-namespace NS Exclure ce namespace applicatif (repetable)
      --exclude-policy NAME  Exclure les RPC issus de cette policy (repetable)
      --exclude-app NAME     Exclure cette application (repetable)

GARDE-FOUS
      --apply                Executer reellement les suppressions (sinon dry-run)
      --dry-run              Forcer le dry-run. Utile pour neutraliser un
                             --apply place plus tot dans la ligne de commande
      --min-keep N           Toujours conserver les N snapshots les plus recents
                             par application, meme hors retention (defaut: $DEF_MIN_KEEP)
      --max-deletions N      Sous --apply, abandonner si le nombre de candidats
                             depasse N. En dry-run, le depassement est signale
                             mais le code retour reste 0.
                             (defaut: $DEF_MAX_DELETIONS, 0 = illimite)
      --wait-retire SEC      Attendre jusqu'a SEC la completion des RetireActions
      --exempt-label KEY     Cle du label d'exemption (defaut: $LBL_EXEMPT)

ENVIRONNEMENT
  -n, --k10-namespace NS     Namespace d'installation de K10 (defaut: $DEF_K10_NAMESPACE)
      --cli oc|kubectl       Forcer le binaire (defaut: autodetection OpenShift)

SORTIES
  -r, --report-dir DIR       Repertoire des rapports (defaut: $DEF_REPORT_DIR)
      --metrics-file PATH    Ecrire les metriques Prometheus (textfile collector)
  -q, --quiet                Silencieux (erreurs uniquement)
  -h, --help                 Cette aide

EXEMPLES
  # Identification seule, seuil 7 jours
  $SCRIPT_NAME --retention-days 7

  # Purge reelle des snapshots > 14 jours, hors namespaces prod
  $SCRIPT_NAME -d 14 --exclude-namespace prod-db --exclude-namespace prod-app --apply

  # Mode conservateur : uniquement les orphelins reels (app supprimee ou policy disparue)
  $SCRIPT_NAME -d 7 --require-unbound --orphan-policy-only --apply

EXEMPTION PAR OBJET
  Ajouter le label $LBL_EXEMPT=true sur un RestorePointContent
  pour l'exclure definitivement de la purge :
    <cli> label $RPC_CRD <nom> $LBL_EXEMPT=true

AVERTISSEMENT
  Outil communautaire, non supporte par Veeam. Projet independant, sans
  affiliation avec Veeam Software. Fourni sans aucune garantie.
  Cet outil supprime des sauvegardes de maniere definitive : validez-le en
  lab sur votre version avant toute execution avec --apply.
EOF
}

# ------------------------------ Parsing des args -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--retention-days)   RETENTION_DAYS="${2:?}"; shift 2 ;;
    -n|--k10-namespace)    K10_NAMESPACE="${2:?}"; shift 2 ;;
    -r|--report-dir)       REPORT_DIR="${2:?}"; shift 2 ;;
    --cli)                 CLI="${2:?}"; shift 2 ;;
    --metrics-file)        METRICS_FILE="${2:?}"; shift 2 ;;
    --min-keep)            MIN_KEEP="${2:?}"; shift 2 ;;
    --max-deletions)       MAX_DELETIONS="${2:?}"; shift 2 ;;
    --wait-retire)         WAIT_RETIRE="${2:?}"; shift 2 ;;
    --exempt-label)        LBL_EXEMPT="${2:?}"; shift 2 ;;
    --include-namespace)   INCLUDE_NS+=("${2:?}"); shift 2 ;;
    --exclude-namespace)   EXCLUDE_NS+=("${2:?}"); shift 2 ;;
    --exclude-policy)      EXCLUDE_POLICY+=("${2:?}"); shift 2 ;;
    --exclude-app)         EXCLUDE_APP+=("${2:?}"); shift 2 ;;
    --require-unbound)     REQUIRE_UNBOUND=1; shift ;;
    --orphan-policy-only)  ORPHAN_POLICY_ONLY=1; shift ;;
    --include-exports)     INCLUDE_EXPORTS=1; shift ;;
    --apply)               DRY_RUN=0; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -q|--quiet)            QUIET=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) err "Option inconnue : $1"; usage >&2; exit 1 ;;
  esac
done

[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "--retention-days doit etre un entier"
[[ "$MIN_KEEP"       =~ ^[0-9]+$ ]] || die "--min-keep doit etre un entier"
# Invariant : aucune application ne doit pouvoir se retrouver sans aucun point
# de restauration. --min-keep 0 desactiverait la garde de rang.
[[ "$MIN_KEEP" -ge 1 ]] || die "--min-keep doit etre >= 1 (une application ne peut pas rester sans point de restauration)"
[[ "$MAX_DELETIONS"  =~ ^[0-9]+$ ]] || die "--max-deletions doit etre un entier"
[[ "$WAIT_RETIRE"    =~ ^[0-9]+$ ]] || die "--wait-retire doit etre un entier"

# -------------------------- Prerequis / autodetection ------------------------
detect_cli() {
  if [[ -n "$CLI" ]]; then
    command -v "$CLI" >/dev/null 2>&1 || { err "Binaire '$CLI' introuvable"; exit 3; }
    log "CLI force : $CLI"
    return
  fi
  # OpenShift : presence de oc ET de l'API config.openshift.io (clusterversion)
  if command -v oc >/dev/null 2>&1 && \
     oc get clusterversion version >/dev/null 2>&1; then
    CLI="oc"
    log "Cluster OpenShift detecte -> utilisation de 'oc'"
  elif command -v oc >/dev/null 2>&1 && \
       oc api-resources --api-group=config.openshift.io -o name >/dev/null 2>&1 && \
       [[ -n "$(oc api-resources --api-group=config.openshift.io -o name 2>/dev/null)" ]]; then
    CLI="oc"
    log "API config.openshift.io detectee -> utilisation de 'oc'"
  elif command -v kubectl >/dev/null 2>&1; then
    CLI="kubectl"
    log "Cluster Kubernetes vanilla -> utilisation de 'kubectl'"
  elif command -v oc >/dev/null 2>&1; then
    CLI="oc"
    warn "kubectl absent, repli sur 'oc' en mode Kubernetes generique"
  else
    err "Ni 'oc' ni 'kubectl' trouve dans le PATH"; exit 3
  fi
}

check_prereqs() {
  command -v jq >/dev/null 2>&1 || { err "'jq' est requis (>= 1.6)"; exit 3; }
  detect_cli
  "$CLI" version --request-timeout=15s >/dev/null 2>&1 \
    || { err "Impossible de joindre l'API Kubernetes avec '$CLI'"; exit 3; }
  # RestorePointContent est servi par une APIService agregee
  # (v1alpha1.apps.kio.kasten.io -> kasten-io/aggregatedapis-svc), pas par un
  # CRD : 'get crd' echoue donc sur une installation Kasten normale. Verifie
  # sur K10 9.0.3. Le message reste informatif, la vraie verification est la
  # lecture des objets dans fetch_data, qui echoue avec un message explicite.
  if ! "$CLI" get crd "$RPC_CRD" >/dev/null 2>&1; then
    log "$RPC_CRD hors CRD (API agregee Kasten attendue) - poursuite"
  fi
  # Le label porte la version lisible ; l'image est souvent referencee par
  # digest et n'apprend rien. Verifie sur K10 9.0.3 : label = "9.0.3", image =
  # registry.connect.redhat.com/kasten/aggregatedapis@sha256:...
  local v
  v="$("$CLI" -n "$K10_NAMESPACE" get deploy -l app=k10 \
        -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)"
  if [[ -z "$v" ]]; then
    v="$("$CLI" -n "$K10_NAMESPACE" get deploy -l app=k10 \
          -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  fi
  # Un 'if' et non 'cmd && cmd' : en derniere instruction d'une fonction
  # appelee nue sous 'set -e', un test faux fait sortir tout le script.
  if [[ -n "$v" ]]; then log "Version K10 detectee : $v"; fi
}

# ------------------------------- Collecte K10 --------------------------------
WORKDIR="$(mktemp -d -t k10janitor.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

fetch_data() {
  log "Collecte des $RPC_CRD (cluster-scoped)..."
  "$CLI" get "$RPC_CRD" -o json > "$WORKDIR/rpc.json" \
    || die "Echec de la lecture des $RPC_CRD (verifier les droits RBAC 'list')"
  local total
  total="$(jq '.items | length' "$WORKDIR/rpc.json")"
  log "$total RestorePointContents recuperes"

  log "Collecte des policies K10 dans '$K10_NAMESPACE'..."
  if "$CLI" -n "$K10_NAMESPACE" get "$POLICY_CRD" -o json > "$WORKDIR/policies.json" 2>/dev/null; then
    jq '[.items[].metadata.name]' "$WORKDIR/policies.json" > "$WORKDIR/policy_names.json"
    POLICY_COUNT="$(jq 'length' "$WORKDIR/policy_names.json")"
    log "$POLICY_COUNT policies actives"
    # Zero policy rend --orphan-policy-only inoperant : plus aucune policy de
    # reference, donc tout snapshot parait orphelin. Cas atteignable avec un
    # --k10-namespace errone, le CRD des RPC etant cluster-scoped : la requete
    # namespacee reussit alors avec zero resultat.
    if [[ $ORPHAN_POLICY_ONLY -eq 1 && "$POLICY_COUNT" -eq 0 ]]; then
      err "--orphan-policy-only demande, mais aucune policy trouvee dans '$K10_NAMESPACE'."
      err "Sans policy de reference, tout snapshot serait vu comme orphelin. Verifier --k10-namespace."
      exit 3
    fi
  else
    echo 'null' > "$WORKDIR/policy_names.json"
    # Le filtre est restrictif : le retirer elargirait le perimetre de
    # suppression. On abandonne plutot que de degrader en silence.
    if [[ $ORPHAN_POLICY_ONLY -eq 1 ]]; then
      err "--orphan-policy-only demande, mais les policies sont illisibles dans '$K10_NAMESPACE'."
      err "Refus de poursuivre sans le filtre : verifier le droit RBAC 'list' sur $POLICY_CRD."
      exit 3
    fi
    warn "Policies illisibles - le filtre d'orphelinage par policy est indisponible"
  fi
}

json_array() { # transforme les args en tableau JSON
  if [[ $# -eq 0 ]]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -s .; fi
}

# ---------------------------- Moteur de decision -----------------------------
# Produit un JSONL : un objet par RestorePointContent, champ .decision =
#   DELETE | KEEP, et .reason explicite. Aucune mutation ici.
evaluate() {
  local ex_ns in_ns ex_pol ex_app
  ex_ns="$(json_array "${EXCLUDE_NS[@]+"${EXCLUDE_NS[@]}"}")"
  in_ns="$(json_array "${INCLUDE_NS[@]+"${INCLUDE_NS[@]}"}")"
  ex_pol="$(json_array "${EXCLUDE_POLICY[@]+"${EXCLUDE_POLICY[@]}"}")"
  ex_app="$(json_array "${EXCLUDE_APP[@]+"${EXCLUDE_APP[@]}"}")"

  jq -c \
    --argjson policies "$(<"$WORKDIR/policy_names.json")" \
    --argjson excludeNs "$ex_ns" \
    --argjson includeNs "$in_ns" \
    --argjson excludePol "$ex_pol" \
    --argjson excludeApp "$ex_app" \
    --argjson retentionDays "$RETENTION_DAYS" \
    --argjson minKeep "$MIN_KEEP" \
    --argjson requireUnbound "$REQUIRE_UNBOUND" \
    --argjson orphanPolicyOnly "$ORPHAN_POLICY_ONLY" \
    --argjson includeExports "$INCLUDE_EXPORTS" \
    --arg lblExport "$LBL_EXPORT" \
    --arg lblApp "$LBL_APP" \
    --arg lblNs "$LBL_NS" \
    --arg lblAppType "$LBL_APPTYPE" \
    --arg lblPolicy "$LBL_POLICY" \
    --arg lblPolicyNs "$LBL_POLICY_NS" \
    --arg lblRun "$LBL_RUN" \
    --arg lblExempt "$LBL_EXEMPT" \
    --arg runId "$RUN_ID" \
    '
    def norm_ts:
      # type != "string" couvre null, nombre, booleen, tableau, objet : sub()
      # leverait une erreur non rattrapable sur ces types.
      if (type != "string") or . == "" then null
      else (sub("\\.[0-9]+Z$"; "Z") | sub("\\.[0-9]+\\+"; "+")) end;
    def to_epoch:
      norm_ts | if . == null then null
      else (try fromdateiso8601 catch null) end;

    (now) as $NOW
    | [ .items[]
        | (.metadata.labels // {}) as $l
        | {
            runId:        $runId,
            name:         .metadata.name,
            state:        (.status.state // "Unknown"),
            rpName:       (.status.restorePointRef.name // ""),
            rpNamespace:  (.status.restorePointRef.namespace // ""),
            appName:      ($l[$lblApp] // ""),
            appNamespace: ($l[$lblNs] // (.status.restorePointRef.namespace // "")),
            appType:      ($l[$lblAppType] // "namespace"),
            policyName:   ($l[$lblPolicy] // ""),
            policyNs:     ($l[$lblPolicyNs] // ""),
            runAction:    ($l[$lblRun] // ""),
            hasExport:    ($l | has($lblExport)),
            exportProfile:($l[$lblExport] // ""),
            exempt:       (($l[$lblExempt] // "") | ascii_downcase == "true"),
            actionTime:    (.status.actionTime // null),
            scheduledTime: (.status.scheduledTime // null),
            created:       .metadata.creationTimestamp,
            logicalSizeBytes:  (.status.logicalSizeBytes  // 0),
            physicalSizeBytes: (.status.physicalSizeBytes // 0)
          }
        # horodatage de reference : actionTime > scheduledTime > creationTimestamp
        | .refTime = (.actionTime // .scheduledTime // .created)
        | .refEpoch = (.refTime | to_epoch)
        | .ageDays  = (if .refEpoch == null then null
                       else (($NOW - .refEpoch) / 86400 * 100 | floor) / 100 end)
        # Discriminant = PRESENCE du label, pas sa valeur : Kubernetes autorise
        # un label a valeur vide, et en jq seuls null et false sont falsy,
        # donc la chaine vide traversait le // et passait pour un snapshot.
        | .kind     = (if .hasExport then "export" else "snapshot" end)
        | .appKey   = (if .appNamespace == "" then "<unknown>" else .appNamespace end)
                      + "/" + (if .appName == "" then "<unknown>" else .appName end)
        | .onDemand = (.policyName == "")
        | .policyExists = (if .policyName == "" then false
                           elif $policies == null then true
                           else (.policyName as $p | ($policies | index($p)) != null) end)
      ]
    # rang par application, du plus recent au plus ancien, sur le perimetre eligible
    | ( [ .[] | select(.kind == "snapshot" or $includeExports == 1) ]
        | group_by(.appKey)
        | map( sort_by(.refEpoch // 0) | reverse
               | to_entries | map(.value + {rank: .key}) )
        | flatten ) as $ranked
    | ( $ranked | map({key: .name, value: {rank: .rank}}) | from_entries ) as $rankMap
    | [ .[] | . + {rank: (($rankMap[.name] // {rank: -1}).rank)} ]
    | map(
        . + (
          if .kind == "export" and $includeExports == 0 then
            {decision: "KEEP", reason: "export-restorepoint"}
          elif .exempt then
            {decision: "KEEP", reason: "labelled-exempt"}
          elif .refEpoch == null then
            {decision: "KEEP", reason: "timestamp-unparseable"}
          elif ($includeNs | length) > 0 and ((.appNamespace as $n | $includeNs | index($n)) == null) then
            {decision: "KEEP", reason: "namespace-not-included"}
          elif (.appNamespace as $n | $excludeNs | index($n)) != null then
            {decision: "KEEP", reason: "namespace-excluded"}
          elif (.appName as $a | $excludeApp | index($a)) != null then
            {decision: "KEEP", reason: "app-excluded"}
          elif .policyName != "" and ((.policyName as $p | $excludePol | index($p)) != null) then
            {decision: "KEEP", reason: "policy-excluded"}
          elif .ageDays <= $retentionDays then
            {decision: "KEEP", reason: "within-retention"}
          elif .rank >= 0 and .rank < $minKeep then
            {decision: "KEEP", reason: "min-keep-guard"}
          elif $requireUnbound == 1 and .state != "Unbound" then
            {decision: "KEEP", reason: "still-bound-to-application"}
          elif $orphanPolicyOnly == 1 and .policyExists then
            {decision: "KEEP", reason: "policy-still-active"}
          else
            {decision: "DELETE",
             reason: ( if .onDemand then "on-demand-snapshot-past-threshold"
                       elif (.policyExists | not) then "policy-deleted-snapshot-past-threshold"
                       elif .state == "Unbound" then "unbound-snapshot-past-threshold"
                       else "snapshot-past-threshold" end)}
          end
        )
      )
    | sort_by(.decision, (0 - (.ageDays // 0)))
    | .[]
    ' "$WORKDIR/rpc.json" > "$WORKDIR/decisions.jsonl"
}

# -------------------------------- Rapports -----------------------------------
write_reports() {
  mkdir -p "$REPORT_DIR" || die "Repertoire de rapport inaccessible : $REPORT_DIR"
  local base="$REPORT_DIR/k10-janitor-$RUN_ID"
  REPORT_CSV="$base.csv"
  REPORT_JSONL="$base.jsonl"
  REPORT_SUMMARY="$base.summary.txt"

  cp "$WORKDIR/decisions.jsonl" "$REPORT_JSONL"

  {
    printf 'run_id,decision,reason,rpc_name,state,app_namespace,app_name,app_type,policy_name,policy_exists,on_demand,kind,ref_time,age_days,rank,logical_bytes,physical_bytes,restorepoint\n'
    jq -r '[
        .runId, .decision, .reason, .name, .state, .appNamespace, .appName, .appType,
        .policyName, (.policyExists|tostring), (.onDemand|tostring), .kind,
        (.refTime // ""), ((.ageDays // "")|tostring), (.rank|tostring),
        (.logicalSizeBytes|tostring), (.physicalSizeBytes|tostring),
        (if .rpNamespace == "" then "" else .rpNamespace + "/" + .rpName end)
      ] | @csv' "$WORKDIR/decisions.jsonl"
  } > "$REPORT_CSV"

  log "Rapport CSV   : $REPORT_CSV"
  log "Rapport JSONL : $REPORT_JSONL"
}

summarize() {
  TOTAL=$(wc -l < "$WORKDIR/decisions.jsonl" | tr -d ' ')
  CANDIDATES=$(jq -r 'select(.decision=="DELETE") | .name' "$WORKDIR/decisions.jsonl" | wc -l | tr -d ' ')
  if [[ "$MAX_DELETIONS" -gt 0 && "$CANDIDATES" -gt "$MAX_DELETIONS" ]]; then OVER_CAP=1; fi
  SNAPSHOTS=$(jq -r 'select(.kind=="snapshot") | .name' "$WORKDIR/decisions.jsonl" | wc -l | tr -d ' ')
  EXPORTS=$(jq -r 'select(.kind=="export") | .name' "$WORKDIR/decisions.jsonl" | wc -l | tr -d ' ')
  RECLAIM_BYTES=$(jq -s '[.[] | select(.decision=="DELETE") | .physicalSizeBytes] | add // 0' "$WORKDIR/decisions.jsonl")

  {
    echo "=============================================================="
    echo " Veeam Kasten - purge des snapshots au-dela du seuil d'age"
    echo " run_id            : $RUN_ID"
    echo " cli               : $CLI"
    echo " namespace K10     : $K10_NAMESPACE"
    echo " seuil retention   : ${RETENTION_DAYS} jours"
    echo " mode              : $([[ $DRY_RUN -eq 1 ]] && echo 'DRY-RUN (aucune suppression)' || echo 'APPLY (suppression reelle)')"
    echo " min-keep          : $MIN_KEEP snapshot(s) recent(s) par application"
    echo " max-deletions     : $([[ $MAX_DELETIONS -eq 0 ]] && echo 'illimite' || echo "$MAX_DELETIONS")$([[ $OVER_CAP -eq 1 ]] && echo "  (DEPASSE : $CANDIDATES candidats, un --apply serait refuse)" || echo '')"
    echo " require-unbound   : $REQUIRE_UNBOUND"
    echo " orphan-policy-only: $ORPHAN_POLICY_ONLY"
    echo " policies K10 lues : $POLICY_COUNT"
    echo "--------------------------------------------------------------"
    echo " RestorePointContents inventories : $TOTAL"
    echo "   dont snapshots locaux          : $SNAPSHOTS"
    echo "   dont exports (jamais purges)   : $EXPORTS"
    echo " Candidats a la suppression       : $CANDIDATES"
    echo " Taille physique candidate        : $RECLAIM_BYTES octets"
    echo "--------------------------------------------------------------"
    echo " Repartition des decisions KEEP :"
    # Agrege en jq plutot que par 'sort | uniq -c | sort -rn | sed' : cela
    # retire sed, seul binaire du script hors bash, jq, oc/kubectl et coreutils.
    jq -rs '
      def lpad($n): tostring | if ($n - length) > 0
                               then (" " * ($n - length)) + . else . end;
      [ .[] | select(.decision=="KEEP") | .reason ]
      | group_by(.) | map({reason: .[0], n: length}) | sort_by(-.n)
      | .[] | "   \(.n | lpad(4)) \(.reason)"' "$WORKDIR/decisions.jsonl"
    echo "--------------------------------------------------------------"
    if [[ "$CANDIDATES" -gt 0 ]]; then
      echo " Candidats (age_days | namespace/app | policy | rpc) :"
      jq -r 'select(.decision=="DELETE")
             | "   \(.ageDays)j | \(.appNamespace)/\(.appName) | \(if .policyName=="" then "<on-demand>" else .policyName end) | \(.name)"' \
        "$WORKDIR/decisions.jsonl"
    else
      echo " Aucun candidat."
    fi
    echo "=============================================================="
  } | tee "${REPORT_SUMMARY:-/dev/null}" >&2
}

write_metrics() {
  [[ -z "$METRICS_FILE" ]] && return 0
  local tmp="${METRICS_FILE}.$$"
  cat > "$tmp" <<EOF
# HELP k10_janitor_last_run_timestamp_seconds Horodatage de la derniere execution.
# TYPE k10_janitor_last_run_timestamp_seconds gauge
k10_janitor_last_run_timestamp_seconds $(date -u +%s)
# HELP k10_janitor_dry_run 1 si la derniere execution etait en dry-run.
# TYPE k10_janitor_dry_run gauge
k10_janitor_dry_run $DRY_RUN
# HELP k10_janitor_retention_days Seuil d'age applique.
# TYPE k10_janitor_retention_days gauge
k10_janitor_retention_days $RETENTION_DAYS
# HELP k10_janitor_restorepointcontents_total Inventaire total.
# TYPE k10_janitor_restorepointcontents_total gauge
k10_janitor_restorepointcontents_total $TOTAL
# HELP k10_janitor_candidates_total Nombre de candidats identifies.
# TYPE k10_janitor_candidates_total gauge
k10_janitor_candidates_total $CANDIDATES
# HELP k10_janitor_over_cap 1 si les candidats depassent --max-deletions.
# TYPE k10_janitor_over_cap gauge
k10_janitor_over_cap $OVER_CAP
# HELP k10_janitor_deleted_total Nombre de suppressions reussies.
# TYPE k10_janitor_deleted_total gauge
k10_janitor_deleted_total ${DELETED:-0}
# HELP k10_janitor_failed_total Nombre de suppressions en echec.
# TYPE k10_janitor_failed_total gauge
k10_janitor_failed_total ${FAILED:-0}
# HELP k10_janitor_reclaimable_bytes Taille physique cumulee des candidats.
# TYPE k10_janitor_reclaimable_bytes gauge
k10_janitor_reclaimable_bytes $RECLAIM_BYTES
EOF
  mv "$tmp" "$METRICS_FILE"
  log "Metriques Prometheus : $METRICS_FILE"
}

# ------------------------------- Suppression ----------------------------------
purge() {
  DELETED=0
  FAILED=0

  if [[ "$CANDIDATES" -eq 0 ]]; then
    log "Rien a supprimer."
    return 0
  fi

  # Le plafond est un frein a la suppression : il n'a de sens que la ou une
  # suppression peut avoir lieu. En dry-run le rapport sort complet, le
  # depassement est signale, et le code retour reste 0 - sinon le tout premier
  # run planifie sur un cluster reellement encrasse marque le Job en echec.
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN : $CANDIDATES RestorePointContents seraient supprimes. Aucune action effectuee."
    if [[ $OVER_CAP -eq 1 ]]; then
      warn "$CANDIDATES candidats > plafond --max-deletions=$MAX_DELETIONS : un --apply serait refuse en l'etat."
    fi
    log "Relancer avec --apply pour executer la purge."
    return 0
  fi

  if [[ $OVER_CAP -eq 1 ]]; then
    err "$CANDIDATES candidats > plafond --max-deletions=$MAX_DELETIONS : abandon par securite."
    err "Verifier le rapport, puis relancer avec un plafond adapte si le resultat est attendu."
    return 2
  fi

  warn "APPLY : suppression de $CANDIDATES RestorePointContents."
  warn "La suppression est definitive et prime sur la retention des policies."

  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if "$CLI" delete "$RPC_CRD" "$name" --wait=false >/dev/null 2>"$WORKDIR/del.err"; then
      DELETED=$((DELETED + 1))
      printf '%s [%-5s] deleted %s=%s\n' "$(_ts)" "AUDIT" "$RPC_CRD" "$name" >&2
      jq -c --arg n "$name" --arg ts "$(_ts)" \
        'select(.name==$n) | . + {deletedAt: $ts, deleteResult: "ok"}' \
        "$WORKDIR/decisions.jsonl" >> "$REPORT_JSONL.audit"
    else
      FAILED=$((FAILED + 1))
      err "Echec suppression $name : $(tr '\n' ' ' < "$WORKDIR/del.err")"
      jq -c --arg n "$name" --arg ts "$(_ts)" --arg e "$(tr '\n' ' ' < "$WORKDIR/del.err")" \
        'select(.name==$n) | . + {deletedAt: $ts, deleteResult: "failed", error: $e}' \
        "$WORKDIR/decisions.jsonl" >> "$REPORT_JSONL.audit"
    fi
  done < <(jq -r 'select(.decision=="DELETE") | .name' "$WORKDIR/decisions.jsonl")

  log "Suppressions : $DELETED reussies, $FAILED en echec."
  [[ -f "$REPORT_JSONL.audit" ]] && log "Piste d'audit : $REPORT_JSONL.audit"

  if [[ "$WAIT_RETIRE" -gt 0 && "$DELETED" -gt 0 ]]; then
    wait_for_retire
  fi

  [[ "$FAILED" -gt 0 ]] && return 1
  return 0
}

wait_for_retire() {
  log "Attente de la completion des RetireActions (max ${WAIT_RETIRE}s)..."
  local deadline=$(( $(date -u +%s) + WAIT_RETIRE )) pending
  while [[ $(date -u +%s) -lt $deadline ]]; do
    pending="$("$CLI" get "$RETIRE_CRD" -o json 2>/dev/null \
      | jq '[.items[] | select(.status.state != "Complete" and .status.state != "Failed" and .status.state != "Skipped")] | length' 2>/dev/null || echo 0)"
    [[ "${pending:-0}" -eq 0 ]] && { log "Tous les RetireActions sont termines."; return 0; }
    log "RetireActions en cours : $pending"
    sleep 15
  done
  warn "Delai d'attente atteint, des RetireActions sont encore en cours (normal pour de gros exports)."
}

# ---------------------------------- Main --------------------------------------
main() {
  log "$SCRIPT_NAME v$SCRIPT_VERSION - run_id=$RUN_ID"
  log "Outil communautaire non supporte par Veeam - fourni sans garantie"
  check_prereqs
  fetch_data
  evaluate
  write_reports
  summarize
  local rc=0
  purge || rc=$?
  write_metrics
  exit $rc
}

main "$@"
