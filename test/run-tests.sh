#!/usr/bin/env bash
# =============================================================================
# Suite de tests du moteur de decision, hors cluster.
#
# Aucun acces a un vrai cluster : un faux binaire "kubectl" sert les fixtures
# JSON et journalise les suppressions demandees. La suite valide les decisions
# KEEP/DELETE, les garde-fous et les codes retour.
#
# Usage : ./test/run-tests.sh
# Dependances : bash >= 4, jq >= 1.6, python3 (validation YAML, optionnel)
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/k10-snapshot-janitor.sh"
WORK="$(mktemp -d -t k10janitor-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq() { # attendu obtenu libelle
  if [[ "$1" == "$2" ]]; then ok "$3"; else ko "$3 (attendu '$1', obtenu '$2')"; fi
}

# ------------------------------- Fixtures ------------------------------------
ago() { date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ; }

rpc() { # name state ns app policy exportProfile ageDays exempt [badTimestamp]
  local name=$1 state=$2 ns=$3 app=$4 pol=$5 exp=$6 age=$7 exempt=$8 badts=${9:-0}
  local ts; ts="$(ago "$age")"; [[ $badts -eq 1 ]] && ts="not-a-timestamp"
  jq -n --arg n "$name" --arg st "$state" --arg ns "$ns" --arg app "$app" \
        --arg pol "$pol" --arg exp "$exp" --arg ts "$ts" --arg ex "$exempt" '
    { apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePointContent",
      metadata:{ name:$n, creationTimestamp:$ts,
        labels: ( {"k10.kasten.io/appName":$app,
                   "k10.kasten.io/appNamespace":$ns,
                   "k10.kasten.io/appType":"namespace",
                   "k10.kasten.io/runActionName":("run-"+$n)}
          + (if $pol=="" then {} else {"k10.kasten.io/policyName":$pol,
                                       "k10.kasten.io/policyNamespace":"kasten-io"} end)
          + (if $exp=="" then {}
             elif $exp=="<empty>" then {"k10.kasten.io/exportProfile":""}
             else {"k10.kasten.io/exportProfile":$exp} end)
          + (if $ex=="1" then {"k10-janitor/exempt":"true"} else {} end) ) },
      status:{ state:$st, actionTime:$ts, scheduledTime:$ts,
        logicalSizeBytes:17179869184, physicalSizeBytes:4852012,
        restorePointRef: (if $st=="Bound" then {name:("rp-"+$n), namespace:$ns} else null end) } }'
}

build_fixtures() {
  mkdir -p "$WORK/fixtures"
  {
    # namespace/app        state   ns         app        policy      export  age exempt
    rpc rpc-mysql-recent   Bound   prod       mysql      daily-prod  ""      2   0
    rpc rpc-mysql-old      Bound   prod       mysql      daily-prod  ""      30  0
    rpc rpc-mysql-older    Bound   prod       mysql      gone-policy ""      40  0
    rpc rpc-nginx-solo     Bound   dev        nginx      ""          ""      100 0
    rpc rpc-redis-a        Bound   dev        redis      ""          ""      50  0
    rpc rpc-redis-b        Bound   dev        redis      ""          ""      60  0
    rpc rpc-wp-1           Unbound gone-ns    wordpress  gone-policy ""      90  0
    rpc rpc-wp-2           Unbound gone-ns    wordpress  gone-policy ""      95  0
    rpc rpc-ex-1           Bound   prod       exempt-app daily-prod  ""      10  0
    rpc rpc-ex-2           Bound   prod       exempt-app daily-prod  ""      100 1
    rpc rpc-ex-3           Bound   prod       exempt-app daily-prod  ""      110 0
    rpc rpc-badts-1        Bound   prod       badts      daily-prod  ""      5   0
    rpc rpc-badts-2        Bound   prod       badts      daily-prod  ""      50  0 1
    rpc rpc-excl-1         Bound   protected  payments   daily-prod  ""      70  0
    rpc rpc-excl-2         Bound   protected  payments   daily-prod  ""      80  0
    rpc rpc-export-old     Bound   prod       mysql      daily-prod  s3-prod 30  0
    rpc rpc-export-old2    Bound   prod       mysql      daily-prod  s3-prod 300 0
  } | jq -s '{apiVersion:"v1",kind:"List",items:.}' > "$WORK/fixtures/rpc.json"

  jq -n '{apiVersion:"v1",kind:"List",items:[]}' > "$WORK/fixtures/rpc_empty.json"

  # Kubernetes autorise un label a valeur vide. L'invariant 2 fait de l'ABSENCE
  # du label exportProfile le discriminant, pas de sa valeur.
  {
    rpc rpc-ev-snapshot    Bound   prod       mysql      daily-prod  ""        1   0
    rpc rpc-ev-export      Bound   prod       mysql      daily-prod  "<empty>" 60  0
  } | jq -s '{apiVersion:"v1",kind:"List",items:.}' > "$WORK/fixtures/rpc_export_vide.json"

  # "gone-policy" est volontairement absente de cette liste
  jq -n '{apiVersion:"v1",kind:"List",items:[
    {metadata:{name:"daily-prod",namespace:"kasten-io"}},
    {metadata:{name:"weekly-dev",namespace:"kasten-io"}}]}' > "$WORK/fixtures/policies.json"
}

build_mocks() {
  mkdir -p "$WORK/bin"
  # mock nominal
  cat > "$WORK/bin/kubectl" <<MOCK
#!/usr/bin/env bash
F="$WORK/fixtures"
case "\$*" in
  version*)                              echo "Client Version: v1.30.2"; exit 0 ;;
  *"get crd restorepointcontents"*)      exit 0 ;;
  *"get restorepointcontents"*)          cat "\$F/\${RPC_FIXTURE:-rpc.json}"; exit 0 ;;
  *"get policies.config.kio.kasten.io"*) cat "\$F/policies.json"; exit 0 ;;
  *"get retireactions"*)                 jq -n '{items:[]}'; exit 0 ;;
  *"get deploy"*)                        echo "gcr.io/kasten-images/k10:8.5.9"; exit 0 ;;
  *delete*)                              echo "\$(date -u +%FT%TZ) DELETE \${*: -2:1}" >> "$WORK/deleted.log"; exit 0 ;;
  *) exit 1 ;;
esac
MOCK
  # mock refusant les suppressions (simulation d'un RBAC incomplet)
  sed 's#^  \*delete\*).*#  *delete*) echo "Error from server (Forbidden)" >\&2; exit 1 ;;#' \
    "$WORK/bin/kubectl" > "$WORK/bin/kubectl-ro"
  # mock ou le deploiement K10 est introuvable : label different selon la
  # version, K10 dans un autre namespace, ou RBAC 'deployments/list' refuse
  sed 's#^  \*"get deploy"\*).*#  *"get deploy"*) exit 0 ;;#' \
    "$WORK/bin/kubectl" > "$WORK/bin/kubectl-nok10"
  chmod +x "$WORK/bin/kubectl" "$WORK/bin/kubectl-ro" "$WORK/bin/kubectl-nok10"
}

# ------------------------------- Helpers -------------------------------------
run() { # renvoie le code retour, laisse les rapports dans $WORK/reports
  local cli="${CLI_BIN:-kubectl}"
  PATH="$WORK/bin:$PATH" "$SCRIPT" --cli "$cli" -q -r "$WORK/reports" "$@" >/dev/null 2>&1
}

latest_report() { # chemin du rapport JSONL le plus recent, piste d'audit exclue
  local f latest=""
  for f in "$WORK/reports"/*.jsonl; do
    if [[ -f "$f" && "${f##*/}" != *audit* ]]; then
      if [[ -z "$latest" || "$f" -nt "$latest" ]]; then latest="$f"; fi
    fi
  done
  printf '%s\n' "$latest"
}

decision_of() { # rpc-name -> "DECISION reason"
  local latest
  latest="$(latest_report)"
  jq -r --arg n "$1" 'select(.name==$n) | "\(.decision) \(.reason)"' "$latest"
}

candidates() {
  local latest
  latest="$(latest_report)"
  jq -r 'select(.decision=="DELETE") | .name' "$latest" | sort | tr '\n' ' ' | sed 's/ $//'
}

reset_reports() { rm -rf "$WORK/reports" "$WORK/deleted.log"; }

# --------------------------------- Tests -------------------------------------
build_fixtures
build_mocks

head_ "Prerequis"
command -v jq >/dev/null && ok "jq disponible ($(jq --version))" || ko "jq manquant"
bash -n "$SCRIPT" && ok "bash -n sur le script" || ko "bash -n echoue"

head_ "Cas 1 : dry-run, seuil 7 jours, exclusion du namespace 'protected'"
reset_reports
run -d 7 --exclude-namespace protected && rc=0 || rc=$?
assert_eq "0" "$rc" "code retour 0 en dry-run"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "aucune suppression en dry-run"
assert_eq "KEEP export-restorepoint"    "$(decision_of rpc-export-old2)" "export de 300 jours conserve"
assert_eq "KEEP export-restorepoint"    "$(decision_of rpc-export-old)"  "export de 30 jours conserve"
assert_eq "KEEP within-retention"       "$(decision_of rpc-mysql-recent)" "snapshot de 2 jours conserve"
assert_eq "KEEP labelled-exempt"        "$(decision_of rpc-ex-2)"        "label d'exemption respecte"
assert_eq "KEEP timestamp-unparseable"  "$(decision_of rpc-badts-2)"     "horodatage illisible non supprime"
assert_eq "KEEP namespace-excluded"     "$(decision_of rpc-excl-2)"      "namespace exclu respecte"
assert_eq "KEEP min-keep-guard"         "$(decision_of rpc-nginx-solo)"  "application a snapshot unique protegee"
assert_eq "KEEP min-keep-guard"         "$(decision_of rpc-redis-a)"     "snapshot le plus recent protege"
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-mysql-old)" "snapshot hors seuil, policy active"
assert_eq "DELETE policy-deleted-snapshot-past-threshold" "$(decision_of rpc-mysql-older)" "policy supprimee detectee"
assert_eq "DELETE on-demand-snapshot-past-threshold"      "$(decision_of rpc-redis-b)"     "snapshot on-demand detecte"
assert_eq "rpc-ex-3 rpc-mysql-old rpc-mysql-older rpc-redis-b rpc-wp-2" "$(candidates)" "liste exacte des candidats"

head_ "Cas 2 : mode conservateur (--require-unbound --orphan-policy-only)"
reset_reports
run -d 7 --require-unbound --orphan-policy-only || true
assert_eq "rpc-wp-2" "$(candidates)" "seul l'orphelin strict est retenu"
assert_eq "KEEP still-bound-to-application" "$(decision_of rpc-mysql-older)" "RPC encore lie a une application conserve"
# rpc-wp-1 est Unbound mais protege par min-keep : --orphan-policy-only ne le
# rattrape pas, la garde min-keep est evaluee en amont.
assert_eq "KEEP min-keep-guard"             "$(decision_of rpc-wp-1)"        "garde min-keep prioritaire sur les filtres d'orphelinage"
# rpc-ex-3 est Bound : --require-unbound tranche avant --orphan-policy-only.
assert_eq "KEEP still-bound-to-application" "$(decision_of rpc-ex-3)"        "require-unbound evalue avant orphan-policy-only"

head_ "Cas 3 : --min-keep 2"
reset_reports
run -d 7 --exclude-namespace protected --min-keep 2 || true
assert_eq "rpc-ex-3 rpc-mysql-older" "$(candidates)" "deux snapshots recents conserves par application"

head_ "Cas 4 : --include-namespace dev, seuil 30 jours"
reset_reports
run -d 30 --include-namespace dev || true
assert_eq "rpc-redis-b" "$(candidates)" "restriction de perimetre appliquee"
assert_eq "KEEP namespace-not-included" "$(decision_of rpc-mysql-older)" "hors perimetre conserve"

head_ "Cas 5 : plafond --max-deletions depasse"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 3 --apply && rc=0 || rc=$?
assert_eq "2" "$rc" "code retour 2"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "aucune suppression malgre --apply"

head_ "Cas 6 : --apply nominal"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 100 --apply && rc=0 || rc=$?
assert_eq "0" "$rc" "code retour 0"
assert_eq "5" "$(wc -l < "$WORK/deleted.log" | tr -d ' ')" "5 suppressions transmises a l'API"
assert_eq "5" "$(cat "$WORK"/reports/*.audit | jq -r 'select(.deleteResult=="ok") | .name' | wc -l | tr -d ' ')" "piste d'audit complete"

head_ "Cas 7 : suppression refusee par l'API"
reset_reports
CLI_BIN=kubectl-ro run -d 7 --exclude-namespace protected --max-deletions 100 --apply && rc=0 || rc=$?
assert_eq "1" "$rc" "code retour 1 en cas d'echec de suppression"
assert_eq "5" "$(cat "$WORK"/reports/*.audit | jq -r 'select(.deleteResult=="failed") | .name' | wc -l | tr -d ' ')" "echecs traces dans l'audit"

head_ "Cas 8 : inventaire vide"
reset_reports
RPC_FIXTURE=rpc_empty.json run -d 7 --apply && rc=0 || rc=$?
assert_eq "0" "$rc" "code retour 0 sur inventaire vide"
assert_eq "" "$(candidates)" "aucun candidat"

head_ "Cas 9 : binaire absent"
reset_reports
PATH="$WORK/bin:$PATH" "$SCRIPT" --cli inexistant -q >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "3" "$rc" "code retour 3 sur prerequis manquant"

head_ "Cas 10 : cle du label d'exemption surchargeable"
reset_reports
run -d 7 --exclude-namespace protected --exempt-label autre/cle || true
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-ex-2)" "l'ancien label ne protege plus"

head_ "Cas 11 : manifests"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  n="$(python3 -c "
import yaml
d=[x for x in yaml.safe_load_all(open('$ROOT/deploy/cronjob.yaml')) if x]
print(len(d))")"
  assert_eq "8" "$n" "deploy/cronjob.yaml contient 8 documents valides"
  args="$(python3 -c "
import yaml
d=[x for x in yaml.safe_load_all(open('$ROOT/deploy/cronjob.yaml')) if x]
cj=[x for x in d if x['kind']=='CronJob'][0]
print(cj['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['args'][0])")"
  printf '%s\n' "$args" | sed 's#^ *exec /opt/janitor/.*#exit 0#' > "$WORK/args.sh"
  allok=1
  for a in true false; do for c in true false; do
    env RETENTION_DAYS=7 K10_NAMESPACE=kasten-io MIN_KEEP=1 MAX_DELETIONS=50 \
        WAIT_RETIRE=0 PURGE_APPLY=$a CONSERVATIVE_MODE=$c \
        EXCLUDE_NAMESPACES="" EXCLUDE_POLICIES="" \
        bash "$WORK/args.sh" >/dev/null 2>&1 || allok=0
  done; done
  assert_eq "1" "$allok" "construction des arguments du CronJob sur les 4 combinaisons"
else
  printf '  \033[33mSKIP\033[0m python3/pyyaml absent, validation des manifests ignoree\n'
fi

head_ "Cas 12 : deploiement K10 introuvable"
reset_reports
CLI_BIN=kubectl-nok10 run -d 7 --exclude-namespace protected && rc=0 || rc=$?
assert_eq "0" "$rc" "la detection de l'image K10 est informative, pas bloquante"
assert_eq "5" "$(candidates | wc -w | tr -d ' ')" "le rapport est produit malgre l'absence de deploiement K10"

head_ "Cas 13 : label exportProfile present mais a valeur vide (invariant 2)"
reset_reports
RPC_FIXTURE=rpc_export_vide.json run -d 7 || true
assert_eq "KEEP export-restorepoint" "$(decision_of rpc-ev-export)" "un export a label vide reste un export"
assert_eq "" "$(candidates)" "aucun candidat a la suppression"

head_ "Cas 14 : --min-keep 0 refuse (invariant 3)"
reset_reports
run -d 7 --min-keep 0 && rc=0 || rc=$?
assert_eq "1" "$rc" "--min-keep 0 sort en code 1"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "aucune suppression"

# --------------------------------- Bilan -------------------------------------
printf '\n\033[1mBilan : %d reussis, %d echecs\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
