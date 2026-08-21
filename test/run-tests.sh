#!/usr/bin/env bash
# =============================================================================
# Suite de tests du moteur de decision, hors cluster.
#
# Aucun acces a un vrai cluster : un faux binaire "kubectl" sert les fixtures
# JSON et journalise les suppressions demandees. La suite valide les decisions
# KEEP/DELETE, les garde-fous et les codes retour.
#
# Usage : ./test/run-tests.sh
# Dependances : bash >= 4, jq >= 1.6, python3 + pyyaml
#
# python3 + pyyaml sont requis : sans eux la validation des manifests est
# ignoree, et une suite amputee qui sort en 0 laisserait croire que tout a
# ete verifie. Un cas ignore fait donc echouer la suite.
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/k10-snapshot-janitor.sh"
WORK="$(mktemp -d -t k10janitor-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
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

  # Deux exports anciens, dont un exempte : sert a verifier que l'exemption
  # reste prioritaire quand --include-exports elargit le perimetre.
  {
    rpc rpc-ie-snapshot    Bound   prod       mysql      daily-prod  ""      1   0
    rpc rpc-ie-export      Bound   prod       mysql      daily-prod  s3-prod 300 0
    rpc rpc-ie-export-ex   Bound   prod       mysql      daily-prod  s3-prod 310 1
  } | jq -s '{apiVersion:"v1",kind:"List",items:.}' > "$WORK/fixtures/rpc_include_exports.json"

  # Frontiere d'age : le moteur compare avec <=, un objet pile au seuil doit
  # etre conserve. Chaque application a un objet recent pour que celui teste
  # ne soit pas rang 0 et ne parte pas en min-keep-guard.
  {
    rpc rpc-bord-recent-a  Bound   prod       borda      daily-prod  ""      0   0
    rpc rpc-bord-pile      Bound   prod       borda      daily-prod  ""      7   0
    rpc rpc-bord-recent-b  Bound   prod       bordb      daily-prod  ""      0   0
    rpc rpc-bord-au-dela   Bound   prod       bordb      daily-prod  ""      8   0
  } | jq -s '{apiVersion:"v1",kind:"List",items:.}' > "$WORK/fixtures/rpc_bordure.json"

  # Aucune des trois sources d'horodatage : actionTime, scheduledTime et
  # creationTimestamp tous absents ou nuls.
  jq -n '{apiVersion:"v1",kind:"List",items:[
    { apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePointContent",
      metadata:{ name:"rpc-sans-horodatage", creationTimestamp:null,
        labels:{ "k10.kasten.io/appName":"mysql",
                 "k10.kasten.io/appNamespace":"prod" } },
      status:{ state:"Bound", restorePointRef:null } }]}' \
    > "$WORK/fixtures/rpc_sans_ts.json"

  # Horodatages a decalage numerique : fromdateiso8601 de jq n'accepte que le
  # suffixe Z. Ces objets doivent tomber en KEEP, jamais en DELETE.
  jq -n '{apiVersion:"v1",kind:"List",items:[
    { apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePointContent",
      metadata:{ name:"rpc-offset-plus", creationTimestamp:"2020-01-01T10:00:00+02:00",
        labels:{ "k10.kasten.io/appName":"a1", "k10.kasten.io/appNamespace":"prod" } },
      status:{ state:"Bound", actionTime:"2020-01-01T10:00:00+02:00", restorePointRef:null } },
    { apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePointContent",
      metadata:{ name:"rpc-offset-moins", creationTimestamp:"2020-01-01T08:00:00-04:00",
        labels:{ "k10.kasten.io/appName":"a2", "k10.kasten.io/appNamespace":"prod" } },
      status:{ state:"Bound", actionTime:"2020-01-01T08:00:00.123-04:00", restorePointRef:null } }]}' \
    > "$WORK/fixtures/rpc_offset.json"

  # Horodatage de type non-string : doit donner KEEP, pas un plantage jq dont
  # le code retour sortirait des codes documentes (invariants 4 et 8).
  jq -n --arg ts "$(ago 60)" '{apiVersion:"v1",kind:"List",items:[
    { apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePointContent",
      metadata:{ name:"rpc-ts-numerique", creationTimestamp:$ts,
        labels:{ "k10.kasten.io/appName":"mysql",
                 "k10.kasten.io/appNamespace":"prod" } },
      status:{ state:"Bound", actionTime:1234567890,
        logicalSizeBytes:0, physicalSizeBytes:0, restorePointRef:null } }]}' \
    > "$WORK/fixtures/rpc_ts_numerique.json"

  # "gone-policy" est volontairement absente de cette liste
  jq -n '{apiVersion:"v1",kind:"List",items:[
    {metadata:{name:"daily-prod",namespace:"kasten-io"}},
    {metadata:{name:"weekly-dev",namespace:"kasten-io"}}]}' > "$WORK/fixtures/policies.json"

  # Liste vide : atteignable avec un --k10-namespace errone, le CRD des
  # RestorePointContent etant cluster-scoped, la requete namespacee reussit
  # alors avec zero resultat.
  jq -n '{apiVersion:"v1",kind:"List",items:[]}' > "$WORK/fixtures/policies_empty.json"
}

build_mocks() {
  mkdir -p "$WORK/bin"
  # mock nominal
  cat > "$WORK/bin/kubectl" <<MOCK
#!/usr/bin/env bash
F="$WORK/fixtures"
# Ligne de commande complete : seule trace permettant de verifier que rien
# d'autre qu'un RestorePointContent n'est jamais mute (invariant 7).
echo "\$*" >> "$WORK/calls.log"
case "\$*" in
  version*)                              echo "Client Version: v1.30.2"; exit 0 ;;
  *"get crd restorepointcontents"*)      exit 0 ;;
  *"get restorepointcontents"*)          cat "\$F/\${RPC_FIXTURE:-rpc.json}"; exit 0 ;;
  *"get policies.config.kio.kasten.io"*) cat "\$F/\${POLICY_FIXTURE:-policies.json}"; exit 0 ;;
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
  # mock dont la lecture des policies echoue : droit RBAC 'list' manquant
  sed 's#^  \*"get policies.*#  *"get policies"*) exit 1 ;;#' \
    "$WORK/bin/kubectl" > "$WORK/bin/kubectl-nopolicies"
  # mock rendant la piste d'audit inecrivable : au premier delete il cree un
  # repertoire a l'emplacement du fichier d'audit, ce qui fait echouer le '>>'.
  # Simule un PVC de rapports sature pendant un --apply.
  sed 's#^  \*delete\*).*#  *delete*) for f in "'"$WORK"'/reports"/*.jsonl; do [ -e "$f" ] \&\& mkdir -p "$f.audit"; done; echo "DELETE ${*: -2:1}" >> "'"$WORK"'/deleted.log"; exit 0 ;;#' \
    "$WORK/bin/kubectl" > "$WORK/bin/kubectl-noaudit"
  chmod +x "$WORK/bin/kubectl" "$WORK/bin/kubectl-ro" \
           "$WORK/bin/kubectl-nok10" "$WORK/bin/kubectl-nopolicies" \
           "$WORK/bin/kubectl-noaudit"
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

reset_reports() { rm -rf "$WORK/reports" "$WORK/deleted.log" "$WORK/calls.log"; }

mutating_calls() { # appels au CLI portant un verbe mutant
  grep -aE '(^| )(create|delete|apply|patch|replace|edit|label|annotate) ' \
    "$WORK/calls.log" 2>/dev/null || true
}

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

  # Le decoupage en mots est voulu, le globbing non. Un glob ne se developpe
  # que s'il matche : on cree donc des fichiers qui matchent.
  # On retire aussi la ligne 'echo "Commande : ..."', qui imprimerait les
  # memes arguments une seconde fois.
  printf '%s\n' "$args" \
    | sed -e 's#^ *echo "Commande.*##' \
          -e 's#^ *exec /opt/janitor/.*#printf "%s\\n" "${ARGS[@]}"#' > "$WORK/args-echo.sh"
  mkdir -p "$WORK/globtest"; : > "$WORK/globtest/prod-a"; : > "$WORK/globtest/prod-b"
  built="$(cd "$WORK/globtest" && env RETENTION_DAYS=7 K10_NAMESPACE=kasten-io \
      MIN_KEEP=1 MAX_DELETIONS=50 WAIT_RETIRE=0 PURGE_APPLY=false \
      CONSERVATIVE_MODE=false EXCLUDE_NAMESPACES='prod-*' EXCLUDE_APPS='payments' \
      INCLUDE_NAMESPACES='dev' EXCLUDE_POLICIES='daily-prod' \
      bash "$WORK/args-echo.sh" 2>/dev/null | tr '\n' ' ')"
  assert_eq "1" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "prod-*")) | length')" \
    "le namespace exclu reste litteral, sans expansion glob"
  assert_eq "0" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "prod-a" or . == "prod-b")) | length')" \
    "aucun nom de fichier du repertoire courant ne s'est glisse dans les arguments"
  assert_eq "1" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "--exclude-app")) | length')" \
    "EXCLUDE_APPS cable sur --exclude-app"
  assert_eq "1" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "--include-namespace")) | length')" \
    "INCLUDE_NAMESPACES cable sur --include-namespace"
  assert_eq "1" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "--exclude-policy")) | length')" \
    "EXCLUDE_POLICIES cable sur --exclude-policy"
else
  skip "python3/pyyaml absent, validation des manifests ignoree"
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

head_ "Cas 15 : horodatage de type non-string (invariants 4 et 8)"
reset_reports
RPC_FIXTURE=rpc_ts_numerique.json run -d 7 && rc=0 || rc=$?
assert_eq "0" "$rc" "code retour dans les codes documentes"
assert_eq "KEEP timestamp-unparseable" "$(decision_of rpc-ts-numerique)" "horodatage non-string conserve"

head_ "Cas 16 : aucune mutation hors RestorePointContent (invariant 7)"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 100 --apply || true
assert_eq "5" "$(mutating_calls | wc -l | tr -d ' ')" "5 mutations transmises a l'API"
assert_eq "0" "$(mutating_calls | grep -cv 'restorepointcontents\.apps\.kio\.kasten\.io' || true)" \
  "toute mutation cible un RestorePointContent"
assert_eq "0" "$(mutating_calls | grep -cE ' (restorepoints|policies|retireactions|policies\.config)' || true)" \
  "ni RestorePoint, ni policy, ni RetireAction mutes"

head_ "Cas 17 : --orphan-policy-only avec des policies illisibles (issue #3)"
reset_reports
CLI_BIN=kubectl-nopolicies run -d 7 --orphan-policy-only && rc=0 || rc=$?
assert_eq "3" "$rc" "abandon en code 3, le filtre restrictif ne doit pas etre retire"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "aucune suppression"
reset_reports
CLI_BIN=kubectl-nopolicies run -d 7 --exclude-namespace protected && rc=0 || rc=$?
assert_eq "0" "$rc" "sans le filtre, des policies illisibles restent tolerables"

head_ "Cas 18 : --orphan-policy-only avec zero policy (issue #3)"
reset_reports
POLICY_FIXTURE=policies_empty.json run -d 7 --orphan-policy-only && rc=0 || rc=$?
assert_eq "3" "$rc" "abandon en code 3, sans policy de reference tout parait orphelin"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "aucune suppression"
reset_reports
POLICY_FIXTURE=policies_empty.json run -d 7 --exclude-namespace protected && rc=0 || rc=$?
assert_eq "0" "$rc" "sans le filtre, zero policy reste tolerable"

head_ "Cas 19 : plafond --max-deletions en dry-run (issue #4)"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 3 && rc=0 || rc=$?
assert_eq "0" "$rc" "un dry-run ne doit pas echouer sur le plafond"
assert_eq "5" "$(candidates | wc -w | tr -d ' ')" "le rapport liste tous les candidats"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "aucune suppression"
assert_eq "1" "$(grep -c 'DEPASSE' "$WORK"/reports/*.summary.txt || true)" "le depassement est signale dans le resume"
# non-regression : le plafond protege toujours en --apply
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 3 --apply && rc=0 || rc=$?
assert_eq "2" "$rc" "le plafond protege toujours en --apply"

head_ "Cas 20 : --include-exports, seule option qui elargit le perimetre (issue #7)"
reset_reports
run -d 7 --exclude-namespace protected --include-exports || true
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-export-old2)" "export de 300 jours devient candidat"
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-export-old)"  "export de 30 jours devient candidat"
assert_eq "rpc-ex-3 rpc-export-old rpc-export-old2 rpc-mysql-old rpc-mysql-older rpc-redis-b rpc-wp-2" \
  "$(candidates)" "liste exacte : les 5 candidats de base plus les 2 exports"
# l'exemption reste prioritaire, meme quand les exports entrent dans le perimetre
reset_reports
RPC_FIXTURE=rpc_include_exports.json run -d 7 --include-exports || true
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-ie-export)"    "export ancien supprime sous --include-exports"
assert_eq "KEEP labelled-exempt"           "$(decision_of rpc-ie-export-ex)" "le label d'exemption prime sur --include-exports"
assert_eq "rpc-ie-export" "$(candidates)" "seul l'export non exempte est candidat"

head_ "Cas 21 : frontiere d'age, le seuil est inclusif (issue #7)"
reset_reports
RPC_FIXTURE=rpc_bordure.json run -d 7 || true
assert_eq "KEEP within-retention"          "$(decision_of rpc-bord-pile)"    "un objet pile au seuil est conserve"
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-bord-au-dela)" "un objet au-dela du seuil est candidat"

head_ "Cas 22 : --exclude-policy et --exclude-app (issue #7)"
reset_reports
run -d 7 --exclude-namespace protected --exclude-policy daily-prod || true
assert_eq "KEEP policy-excluded" "$(decision_of rpc-mysql-old)" "policy exclue respectee"
reset_reports
run -d 7 --exclude-app payments || true
assert_eq "KEEP app-excluded" "$(decision_of rpc-excl-2)" "application exclue respectee"

head_ "Cas 23 : --metrics-file (issue #7)"
reset_reports
rm -f "$WORK/metrics.prom"
run -d 7 --exclude-namespace protected --metrics-file "$WORK/metrics.prom" || true
assert_eq "9" "$(grep -c '^k10_janitor_' "$WORK/metrics.prom" 2>/dev/null || echo 0)" "9 metriques ecrites"
assert_eq "5" "$(awk '/^k10_janitor_candidates_total /{print $2}' "$WORK/metrics.prom" 2>/dev/null)" "candidates_total coherent avec le rapport"
assert_eq "1" "$(awk '/^k10_janitor_dry_run /{print $2}' "$WORK/metrics.prom" 2>/dev/null)" "dry_run signale"

head_ "Cas 24 : aucune des trois sources d'horodatage (invariant 4)"
reset_reports
RPC_FIXTURE=rpc_sans_ts.json run -d 7 && rc=0 || rc=$?
assert_eq "0" "$rc" "code retour 0"
assert_eq "KEEP timestamp-unparseable" "$(decision_of rpc-sans-horodatage)" "objet sans horodatage conserve"

head_ "Cas 25 : le label d'exemption n'est pas pilotable par l'environnement (issue #9)"
reset_reports
LBL_EXEMPT=autre/cle run -d 7 --exclude-namespace protected || true
assert_eq "KEEP labelled-exempt" "$(decision_of rpc-ex-2)" "une variable d'environnement ne desactive pas les exemptions"
reset_reports
run -d 7 --exclude-namespace protected --exempt-label autre/cle || true
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-ex-2)" "--exempt-label reste la seule surcharge"

head_ "Cas 26 : horodatage a decalage numerique (invariant 4)"
reset_reports
RPC_FIXTURE=rpc_offset.json run -d 7 && rc=0 || rc=$?
assert_eq "0" "$rc" "code retour 0"
assert_eq "KEEP timestamp-unparseable" "$(decision_of rpc-offset-plus)"  "decalage positif conserve"
assert_eq "KEEP timestamp-unparseable" "$(decision_of rpc-offset-moins)" "decalage negatif conserve"
assert_eq "" "$(candidates)" "aucun candidat"

head_ "Cas 27 : piste d'audit inecrivable pendant un --apply"
reset_reports
CLI_BIN=kubectl-noaudit run -d 7 --exclude-namespace protected --max-deletions 100 --apply && rc=0 || rc=$?
assert_eq "5" "$(wc -l < "$WORK/deleted.log" | tr -d ' ')" "les suppressions ont bien eu lieu"
assert_eq "1" "$rc" "un audit incomplet apres suppression ne peut pas sortir en 0"

head_ "Cas 28 : un echec d'ecriture des metriques n'ecrase pas le code retour"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 3 --apply \
    --metrics-file "$WORK/inexistant/m.prom" && rc=0 || rc=$?
assert_eq "2" "$rc" "le plafond depasse reste en code 2 malgre l'echec des metriques"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "aucune suppression"

head_ "Cas 29 : --dry-run neutralise un --apply place plus tot"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 100 --apply --dry-run && rc=0 || rc=$?
assert_eq "0" "$rc" "code retour 0"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "aucune suppression malgre le --apply anterieur"
assert_eq "5" "$(candidates | wc -w | tr -d ' ')" "le rapport reste complet"

# --------------------------------- Bilan -------------------------------------
printf '\n\033[1mBilan : %d reussis, %d echecs, %d ignores\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [[ $SKIP -gt 0 ]]; then
  printf '\033[31mSuite incomplete : %d cas ignore(s). Installer python3 et pyyaml.\033[0m\n' "$SKIP"
fi
[[ $FAIL -eq 0 && $SKIP -eq 0 ]] || exit 1
