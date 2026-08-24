#!/usr/bin/env bash
# =============================================================================
# Offline test suite for the decision engine.
#
# No access to a real cluster: a fake "kubectl" binary serves the JSON fixtures
# and logs the requested deletions. The suite validates the KEEP/DELETE
# decisions, the guards and the exit codes.
#
# Usage : ./test/run-tests.sh
# Dependencies : bash >= 4, jq >= 1.6, python3 + pyyaml
#
# python3 + pyyaml are required: without them the manifest validation is
# skipped, and a truncated suite exiting 0 would suggest everything had been
# checked. A skipped case therefore fails the suite.
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

assert_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else ko "$3 (expected '$1', got '$2')"; fi
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

  # Kubernetes allows an empty label value. Invariant 2 makes the ABSENCE of
  # the exportProfile label the discriminator, not its value.
  {
    rpc rpc-ev-snapshot    Bound   prod       mysql      daily-prod  ""        1   0
    rpc rpc-ev-export      Bound   prod       mysql      daily-prod  "<empty>" 60  0
  } | jq -s '{apiVersion:"v1",kind:"List",items:.}' > "$WORK/fixtures/rpc_export_vide.json"

  # Two old exports, one of them exempt: checks that the exemption still wins
  # when --include-exports widens the perimeter.
  {
    rpc rpc-ie-snapshot    Bound   prod       mysql      daily-prod  ""      1   0
    rpc rpc-ie-export      Bound   prod       mysql      daily-prod  s3-prod 300 0
    rpc rpc-ie-export-ex   Bound   prod       mysql      daily-prod  s3-prod 310 1
  } | jq -s '{apiVersion:"v1",kind:"List",items:.}' > "$WORK/fixtures/rpc_include_exports.json"

  # Age boundary: the engine compares with <=, so an object sitting exactly on
  # the threshold must be kept. Each application has a recent object so the one
  # under test is not rank 0 and does not fall to min-keep-guard.
  {
    rpc rpc-bord-recent-a  Bound   prod       borda      daily-prod  ""      0   0
    rpc rpc-bord-pile      Bound   prod       borda      daily-prod  ""      7   0
    rpc rpc-bord-recent-b  Bound   prod       bordb      daily-prod  ""      0   0
    rpc rpc-bord-au-dela   Bound   prod       bordb      daily-prod  ""      8   0
  } | jq -s '{apiVersion:"v1",kind:"List",items:.}' > "$WORK/fixtures/rpc_bordure.json"

  # None of the three timestamp sources: actionTime, scheduledTime and
  # creationTimestamp all absent or null.
  jq -n '{apiVersion:"v1",kind:"List",items:[
    { apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePointContent",
      metadata:{ name:"rpc-no-timestamp", creationTimestamp:null,
        labels:{ "k10.kasten.io/appName":"mysql",
                 "k10.kasten.io/appNamespace":"prod" } },
      status:{ state:"Bound", restorePointRef:null } }]}' \
    > "$WORK/fixtures/rpc_sans_ts.json"

  # Timestamps with a numeric offset: jq fromdateiso8601 accepts the Z suffix
  # only. These objects must fall to KEEP, never to DELETE.
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

  # Two applications, two old snapshots each so one candidate per application.
  # App "sized" reports physicalSizeBytes, app "unsized" does not: the metrics
  # must distinguish a real 0 from an unknown size.
  jq -n --arg a "$(ago 30)" --arg b "$(ago 40)" '
    def rp($n; $app; $ts; $size):
      { apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePointContent",
        metadata:{ name:$n, creationTimestamp:$ts,
          labels:{ "k10.kasten.io/appName":$app,
                   "k10.kasten.io/appNamespace":"prod",
                   "k10.kasten.io/policyName":"daily-prod" } },
        status:( { state:"Bound", actionTime:$ts,
                   restorePointRef:{name:("rp-"+$n),namespace:"prod"} }
                 + (if $size == null then {} else {physicalSizeBytes:$size} end) ) };
    {apiVersion:"v1",kind:"List",items:[
      rp("rpc-sized-recent";   "sized";   $a; 1000),
      rp("rpc-sized-old";      "sized";   $b; 1000),
      rp("rpc-unsized-recent"; "unsized"; $a; null),
      rp("rpc-unsized-old";    "unsized"; $b; null)]}' \
    > "$WORK/fixtures/rpc_sizes.json"

  # Non-string timestamp: must yield KEEP, not a jq crash whose exit code
  # would fall outside the documented ones (invariants 4 and 8).
  jq -n --arg ts "$(ago 60)" '{apiVersion:"v1",kind:"List",items:[
    { apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePointContent",
      metadata:{ name:"rpc-ts-numerique", creationTimestamp:$ts,
        labels:{ "k10.kasten.io/appName":"mysql",
                 "k10.kasten.io/appNamespace":"prod" } },
      status:{ state:"Bound", actionTime:1234567890,
        logicalSizeBytes:0, physicalSizeBytes:0, restorePointRef:null } }]}' \
    > "$WORK/fixtures/rpc_ts_numerique.json"

  # "gone-policy" is deliberately absent from this list
  jq -n '{apiVersion:"v1",kind:"List",items:[
    {metadata:{name:"daily-prod",namespace:"kasten-io"}},
    {metadata:{name:"weekly-dev",namespace:"kasten-io"}}]}' > "$WORK/fixtures/policies.json"

  # Empty list: reachable with a wrong --k10-namespace. RestorePointContent is
  # cluster-scoped, so the namespaced policy query succeeds with zero results.
  jq -n '{apiVersion:"v1",kind:"List",items:[]}' > "$WORK/fixtures/policies_empty.json"
}

build_mocks() {
  mkdir -p "$WORK/bin"
  # nominal mock
  cat > "$WORK/bin/kubectl" <<MOCK
#!/usr/bin/env bash
F="$WORK/fixtures"
# Full command line: the only record that lets us verify nothing other than a
# RestorePointContent is ever mutated (invariant 7).
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
  # mock refusing deletions (simulates incomplete RBAC)
  sed 's#^  \*delete\*).*#  *delete*) echo "Error from server (Forbidden)" >\&2; exit 1 ;;#' \
    "$WORK/bin/kubectl" > "$WORK/bin/kubectl-ro"
  # mock where the K10 deployment cannot be found: different label depending on
  # the version, K10 in another namespace, or 'deployments/list' RBAC denied
  sed 's#^  \*"get deploy"\*).*#  *"get deploy"*) exit 0 ;;#' \
    "$WORK/bin/kubectl" > "$WORK/bin/kubectl-nok10"
  # mock where reading the policies fails: missing 'list' RBAC permission
  sed 's#^  \*"get policies.*#  *"get policies"*) exit 1 ;;#' \
    "$WORK/bin/kubectl" > "$WORK/bin/kubectl-nopolicies"
  # mock making the audit trail unwritable: on the first delete it creates a
  # directory where the audit file goes, which makes the '>>' fail.
  # Simulates a report PVC filling up during an --apply.
  sed 's#^  \*delete\*).*#  *delete*) for f in "'"$WORK"'/reports"/*.jsonl; do [ -e "$f" ] \&\& mkdir -p "$f.audit"; done; echo "DELETE ${*: -2:1}" >> "'"$WORK"'/deleted.log"; exit 0 ;;#' \
    "$WORK/bin/kubectl" > "$WORK/bin/kubectl-noaudit"
  chmod +x "$WORK/bin/kubectl" "$WORK/bin/kubectl-ro" \
           "$WORK/bin/kubectl-nok10" "$WORK/bin/kubectl-nopolicies" \
           "$WORK/bin/kubectl-noaudit"
}

# ------------------------------- Helpers -------------------------------------
run() { # returns the exit code, leaves the reports in $WORK/reports
  local cli="${CLI_BIN:-kubectl}"
  PATH="$WORK/bin:$PATH" "$SCRIPT" --cli "$cli" -q -r "$WORK/reports" "$@" >/dev/null 2>&1
}

latest_report() { # path of the most recent JSONL report, audit trail excluded
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

mutating_calls() { # CLI calls carrying a mutating verb
  grep -aE '(^| )(create|delete|apply|patch|replace|edit|label|annotate) ' \
    "$WORK/calls.log" 2>/dev/null || true
}

# --------------------------------- Tests -------------------------------------
build_fixtures
build_mocks

head_ "Prerequisites"
command -v jq >/dev/null && ok "jq available ($(jq --version))" || ko "jq missing"
bash -n "$SCRIPT" && ok "bash -n on the script" || ko "bash -n failed"

head_ "Case 1: dry-run, 7-day threshold, 'protected' namespace excluded"
reset_reports
run -d 7 --exclude-namespace protected && rc=0 || rc=$?
assert_eq "0" "$rc" "exit code 0 in dry-run"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "no deletion in dry-run"
assert_eq "KEEP export-restorepoint"    "$(decision_of rpc-export-old2)" "300-day export kept"
assert_eq "KEEP export-restorepoint"    "$(decision_of rpc-export-old)"  "30-day export kept"
assert_eq "KEEP within-retention"       "$(decision_of rpc-mysql-recent)" "2-day snapshot kept"
assert_eq "KEEP labelled-exempt"        "$(decision_of rpc-ex-2)"        "exemption label honoured"
assert_eq "KEEP timestamp-unparseable"  "$(decision_of rpc-badts-2)"     "unparsable timestamp not deleted"
assert_eq "KEEP namespace-excluded"     "$(decision_of rpc-excl-2)"      "excluded namespace honoured"
assert_eq "KEEP min-keep-guard"         "$(decision_of rpc-nginx-solo)"  "single-snapshot application protected"
assert_eq "KEEP min-keep-guard"         "$(decision_of rpc-redis-a)"     "most recent snapshot protected"
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-mysql-old)" "snapshot past threshold, policy active"
assert_eq "DELETE policy-deleted-snapshot-past-threshold" "$(decision_of rpc-mysql-older)" "deleted policy detected"
assert_eq "DELETE on-demand-snapshot-past-threshold"      "$(decision_of rpc-redis-b)"     "on-demand snapshot detected"
assert_eq "rpc-ex-3 rpc-mysql-old rpc-mysql-older rpc-redis-b rpc-wp-2" "$(candidates)" "exact candidate list"

head_ "Case 2: conservative mode (--require-unbound --orphan-policy-only)"
reset_reports
run -d 7 --require-unbound --orphan-policy-only || true
assert_eq "rpc-wp-2" "$(candidates)" "only the strict orphan is selected"
assert_eq "KEEP still-bound-to-application" "$(decision_of rpc-mysql-older)" "RPC still bound to an application is kept"
# rpc-wp-1 is Unbound but protected by min-keep: --orphan-policy-only does not
# catch it, the min-keep guard is evaluated earlier in the cascade.
assert_eq "KEEP min-keep-guard"             "$(decision_of rpc-wp-1)"        "min-keep guard wins over the orphan filters"
# rpc-ex-3 is Bound: --require-unbound decides before --orphan-policy-only.
assert_eq "KEEP still-bound-to-application" "$(decision_of rpc-ex-3)"        "require-unbound evaluated before orphan-policy-only"

head_ "Case 3: --min-keep 2"
reset_reports
run -d 7 --exclude-namespace protected --min-keep 2 || true
assert_eq "rpc-ex-3 rpc-mysql-older" "$(candidates)" "two recent snapshots kept per application"

head_ "Case 4: --include-namespace dev, 30-day threshold"
reset_reports
run -d 30 --include-namespace dev || true
assert_eq "rpc-redis-b" "$(candidates)" "scope restriction applied"
assert_eq "KEEP namespace-not-included" "$(decision_of rpc-mysql-older)" "out of scope, kept"

head_ "Case 5: --max-deletions cap exceeded"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 3 --apply && rc=0 || rc=$?
assert_eq "2" "$rc" "exit code 2"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "no deletion despite --apply"

head_ "Case 6: nominal --apply"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 100 --apply && rc=0 || rc=$?
assert_eq "0" "$rc" "exit code 0"
assert_eq "5" "$(wc -l < "$WORK/deleted.log" | tr -d ' ')" "5 deletions sent to the API"
assert_eq "5" "$(cat "$WORK"/reports/*.audit | jq -r 'select(.deleteResult=="ok") | .name' | wc -l | tr -d ' ')" "complete audit trail"

head_ "Case 7: deletion refused by the API"
reset_reports
CLI_BIN=kubectl-ro run -d 7 --exclude-namespace protected --max-deletions 100 --apply && rc=0 || rc=$?
assert_eq "1" "$rc" "exit code 1 when a deletion fails"
assert_eq "5" "$(cat "$WORK"/reports/*.audit | jq -r 'select(.deleteResult=="failed") | .name' | wc -l | tr -d ' ')" "failures recorded in the audit trail"

head_ "Case 8: empty inventory"
reset_reports
RPC_FIXTURE=rpc_empty.json run -d 7 --apply && rc=0 || rc=$?
assert_eq "0" "$rc" "exit code 0 on an empty inventory"
assert_eq "" "$(candidates)" "no candidate"

head_ "Case 9: missing binary"
reset_reports
PATH="$WORK/bin:$PATH" "$SCRIPT" --cli inexistant -q >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "3" "$rc" "exit code 3 on a missing prerequisite"

head_ "Case 10: exemption label key is overridable"
reset_reports
run -d 7 --exclude-namespace protected --exempt-label autre/cle || true
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-ex-2)" "the old label no longer protects"

head_ "Case 11: manifests"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  n="$(python3 -c "
import yaml
d=[x for x in yaml.safe_load_all(open('$ROOT/deploy/cronjob.yaml')) if x]
print(len(d))")"
  assert_eq "8" "$n" "deploy/cronjob.yaml holds 8 valid documents"
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
  assert_eq "1" "$allok" "CronJob argument building across the 4 combinations"

  # Word splitting is intended, globbing is not. A glob only expands when it
  # matches, so we create files that match.
  # The 'echo "Command: ..."' line is stripped too, it would print the same
  # arguments a second time.
  printf '%s\n' "$args" \
    | sed -e 's#^ *echo "Command:.*##' \
          -e 's#^ *exec /opt/janitor/.*#printf "%s\\n" "${ARGS[@]}"#' > "$WORK/args-echo.sh"
  mkdir -p "$WORK/globtest"; : > "$WORK/globtest/prod-a"; : > "$WORK/globtest/prod-b"
  built="$(cd "$WORK/globtest" && env RETENTION_DAYS=7 K10_NAMESPACE=kasten-io \
      MIN_KEEP=1 MAX_DELETIONS=50 WAIT_RETIRE=0 PURGE_APPLY=false \
      CONSERVATIVE_MODE=false EXCLUDE_NAMESPACES='prod-*' EXCLUDE_APPS='payments' \
      INCLUDE_NAMESPACES='dev' EXCLUDE_POLICIES='daily-prod' \
      bash "$WORK/args-echo.sh" 2>/dev/null | tr '\n' ' ')"
  assert_eq "1" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "prod-*")) | length')" \
    "the excluded namespace stays literal, no glob expansion"
  assert_eq "0" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "prod-a" or . == "prod-b")) | length')" \
    "no filename from the working directory leaked into the arguments"
  assert_eq "1" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "--exclude-app")) | length')" \
    "EXCLUDE_APPS wired to --exclude-app"
  assert_eq "1" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "--include-namespace")) | length')" \
    "INCLUDE_NAMESPACES wired to --include-namespace"
  assert_eq "1" "$(printf '%s' "$built" | jq -Rr '[splits(" ")] | map(select(. == "--exclude-policy")) | length')" \
    "EXCLUDE_POLICIES wired to --exclude-policy"
else
  skip "python3/pyyaml missing, manifest validation skipped"
fi

head_ "Case 12: K10 deployment not found"
reset_reports
CLI_BIN=kubectl-nok10 run -d 7 --exclude-namespace protected && rc=0 || rc=$?
assert_eq "0" "$rc" "K10 version detection is informational, not blocking"
assert_eq "5" "$(candidates | wc -w | tr -d ' ')" "the report is produced despite no K10 deployment"

head_ "Case 13: exportProfile label present but empty-valued (invariant 2)"
reset_reports
RPC_FIXTURE=rpc_export_vide.json run -d 7 || true
assert_eq "KEEP export-restorepoint" "$(decision_of rpc-ev-export)" "an export with an empty label value stays an export"
assert_eq "" "$(candidates)" "no deletion candidate"

head_ "Case 14: --min-keep 0 rejected (invariant 3)"
reset_reports
run -d 7 --min-keep 0 && rc=0 || rc=$?
assert_eq "1" "$rc" "--min-keep 0 exits 1"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "no deletion"

head_ "Case 15: non-string timestamp (invariants 4 and 8)"
reset_reports
RPC_FIXTURE=rpc_ts_numerique.json run -d 7 && rc=0 || rc=$?
assert_eq "0" "$rc" "exit code within the documented set"
assert_eq "KEEP timestamp-unparseable" "$(decision_of rpc-ts-numerique)" "non-string timestamp kept"

head_ "Case 16: nothing but a RestorePointContent is mutated (invariant 7)"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 100 --apply || true
assert_eq "5" "$(mutating_calls | wc -l | tr -d ' ')" "5 mutations sent to the API"
assert_eq "0" "$(mutating_calls | grep -cv 'restorepointcontents\.apps\.kio\.kasten\.io' || true)" \
  "every mutation targets a RestorePointContent"
assert_eq "0" "$(mutating_calls | grep -cE ' (restorepoints|policies|retireactions|policies\.config)' || true)" \
  "no RestorePoint, policy or RetireAction mutated"

head_ "Case 17: --orphan-policy-only with unreadable policies (issue #3)"
reset_reports
CLI_BIN=kubectl-nopolicies run -d 7 --orphan-policy-only && rc=0 || rc=$?
assert_eq "3" "$rc" "exit 3, the restrictive filter must not be dropped"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "no deletion"
reset_reports
CLI_BIN=kubectl-nopolicies run -d 7 --exclude-namespace protected && rc=0 || rc=$?
assert_eq "0" "$rc" "without the filter, unreadable policies stay tolerable"

head_ "Case 18: --orphan-policy-only with zero policies (issue #3)"
reset_reports
POLICY_FIXTURE=policies_empty.json run -d 7 --orphan-policy-only && rc=0 || rc=$?
assert_eq "3" "$rc" "exit 3, with no reference policy everything looks orphaned"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "no deletion"
reset_reports
POLICY_FIXTURE=policies_empty.json run -d 7 --exclude-namespace protected && rc=0 || rc=$?
assert_eq "0" "$rc" "without the filter, zero policies stays tolerable"

head_ "Case 19: --max-deletions cap in dry-run (issue #4)"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 3 && rc=0 || rc=$?
assert_eq "0" "$rc" "a dry-run must not fail on the cap"
assert_eq "5" "$(candidates | wc -w | tr -d ' ')" "the report lists every candidate"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "no deletion"
assert_eq "1" "$(grep -c 'OVER CAP' "$WORK"/reports/*.summary.txt || true)" "the overflow is flagged in the summary"
# non-regression: the cap still protects under --apply
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 3 --apply && rc=0 || rc=$?
assert_eq "2" "$rc" "the cap still protects under --apply"

head_ "Case 20: --include-exports, the only option that widens the scope (issue #7)"
reset_reports
run -d 7 --exclude-namespace protected --include-exports || true
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-export-old2)" "300-day export becomes a candidate"
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-export-old)"  "30-day export becomes a candidate"
assert_eq "rpc-ex-3 rpc-export-old rpc-export-old2 rpc-mysql-old rpc-mysql-older rpc-redis-b rpc-wp-2" \
  "$(candidates)" "exact list: the 5 base candidates plus the 2 exports"
# the exemption still wins, even when exports enter the perimeter
reset_reports
RPC_FIXTURE=rpc_include_exports.json run -d 7 --include-exports || true
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-ie-export)"    "old export deleted under --include-exports"
assert_eq "KEEP labelled-exempt"           "$(decision_of rpc-ie-export-ex)" "the exemption label wins over --include-exports"
assert_eq "rpc-ie-export" "$(candidates)" "only the non-exempt export is a candidate"

head_ "Case 21: age boundary, the threshold is inclusive (issue #7)"
reset_reports
RPC_FIXTURE=rpc_bordure.json run -d 7 || true
assert_eq "KEEP within-retention"          "$(decision_of rpc-bord-pile)"    "an object exactly on the threshold is kept"
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-bord-au-dela)" "an object past the threshold is a candidate"

head_ "Case 22: --exclude-policy and --exclude-app (issue #7)"
reset_reports
run -d 7 --exclude-namespace protected --exclude-policy daily-prod || true
assert_eq "KEEP policy-excluded" "$(decision_of rpc-mysql-old)" "excluded policy honoured"
reset_reports
run -d 7 --exclude-app payments || true
assert_eq "KEEP app-excluded" "$(decision_of rpc-excl-2)" "excluded application honoured"

head_ "Case 23: --metrics-file (issue #7)"
reset_reports
rm -f "$WORK/metrics.prom"
run -d 7 --exclude-namespace protected --metrics-file "$WORK/metrics.prom" || true
assert_eq "10" "$(grep -c '^k10_janitor_' "$WORK/metrics.prom" 2>/dev/null || echo 0)" "10 metrics written"
assert_eq "5" "$(awk '/^k10_janitor_candidates_total /{print $2}' "$WORK/metrics.prom" 2>/dev/null)" "candidates_total consistent with the report"
assert_eq "1" "$(awk '/^k10_janitor_dry_run /{print $2}' "$WORK/metrics.prom" 2>/dev/null)" "dry_run flagged"

head_ "Case 24: none of the three timestamp sources (invariant 4)"
reset_reports
RPC_FIXTURE=rpc_sans_ts.json run -d 7 && rc=0 || rc=$?
assert_eq "0" "$rc" "exit code 0"
assert_eq "KEEP timestamp-unparseable" "$(decision_of rpc-no-timestamp)" "object with no timestamp kept"

head_ "Case 25: the exemption label is not settable from the environment (issue #9)"
reset_reports
LBL_EXEMPT=autre/cle run -d 7 --exclude-namespace protected || true
assert_eq "KEEP labelled-exempt" "$(decision_of rpc-ex-2)" "an environment variable does not disable the exemptions"
reset_reports
run -d 7 --exclude-namespace protected --exempt-label autre/cle || true
assert_eq "DELETE snapshot-past-threshold" "$(decision_of rpc-ex-2)" "--exempt-label stays the only override"

head_ "Case 26: timestamp with a numeric offset (invariant 4)"
reset_reports
RPC_FIXTURE=rpc_offset.json run -d 7 && rc=0 || rc=$?
assert_eq "0" "$rc" "exit code 0"
assert_eq "KEEP timestamp-unparseable" "$(decision_of rpc-offset-plus)"  "positive offset kept"
assert_eq "KEEP timestamp-unparseable" "$(decision_of rpc-offset-moins)" "negative offset kept"
assert_eq "" "$(candidates)" "no candidate"

head_ "Case 27: audit trail unwritable during an --apply"
reset_reports
CLI_BIN=kubectl-noaudit run -d 7 --exclude-namespace protected --max-deletions 100 --apply && rc=0 || rc=$?
assert_eq "5" "$(wc -l < "$WORK/deleted.log" | tr -d ' ')" "the deletions did happen"
assert_eq "1" "$rc" "an incomplete audit after deletion cannot exit 0"

head_ "Case 28: a metrics write failure does not overwrite the exit code"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 3 --apply \
    --metrics-file "$WORK/inexistant/m.prom" && rc=0 || rc=$?
assert_eq "2" "$rc" "the exceeded cap stays exit 2 despite the metrics failure"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "no deletion"

head_ "Case 29: --dry-run neutralises an earlier --apply"
reset_reports
run -d 7 --exclude-namespace protected --max-deletions 100 --apply --dry-run && rc=0 || rc=$?
assert_eq "0" "$rc" "exit code 0"
assert_eq "" "$(cat "$WORK/deleted.log" 2>/dev/null || true)" "no deletion despite the earlier --apply"
assert_eq "5" "$(candidates | wc -w | tr -d ' ')" "the report stays complete"

head_ "Case 30: candidate size, unknown is not zero (issue #16)"
reset_reports
rm -f "$WORK/sizes.prom"
RPC_FIXTURE=rpc_sizes.json run -d 7 --metrics-file "$WORK/sizes.prom" || true
assert_eq "rpc-sized-old rpc-unsized-old" "$(candidates)" "one candidate per application"
assert_eq "1000" "$(awk '/^k10_janitor_candidate_physical_bytes /{print $2}' "$WORK/sizes.prom" 2>/dev/null)" \
  "only the sizes actually reported are summed"
assert_eq "1" "$(awk '/^k10_janitor_candidate_size_unknown_total /{print $2}' "$WORK/sizes.prom" 2>/dev/null)" \
  "the candidate with no size is counted as unknown"
assert_eq "0" "$(grep -c 'k10_janitor_reclaimable_bytes' "$WORK/sizes.prom" 2>/dev/null || true)" \
  "the old metric name is gone"
assert_eq "1" "$(grep -c 'unknown size' "$WORK"/reports/*.summary.txt || true)" \
  "the summary flags the unknown sizes"

# no unknown size at all: the summary stays clean
reset_reports
run -d 7 --exclude-namespace protected || true
assert_eq "0" "$(grep -c 'unknown size' "$WORK"/reports/*.summary.txt || true)" \
  "no mention when every candidate reports a size"

# --------------------------------- Summary -----------------------------------
printf '\n\033[1mSummary: %d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [[ $SKIP -gt 0 ]]; then
  printf '\033[31mIncomplete suite: %d case(s) skipped. Install python3 and pyyaml.\033[0m\n' "$SKIP"
fi
[[ $FAIL -eq 0 && $SKIP -eq 0 ]] || exit 1
