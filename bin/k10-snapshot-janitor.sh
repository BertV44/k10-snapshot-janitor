#!/usr/bin/env bash
# =============================================================================
# k10-snapshot-janitor.sh
#
# COMMUNITY TOOL - NOT SUPPORTED BY VEEAM
#   Independent project, with no affiliation with Veeam Software and no
#   approval or sponsorship from them. Veeam, Kasten and K10 are trademarks of
#   Veeam Software Group GmbH, used here solely to identify the products this
#   tool interacts with.
#   Provided without any warranty. No vendor support channel covers it: do not
#   open a Veeam support case about it.
#   This tool DELETES BACKUPS permanently. Validate it in a lab against your
#   own versions before any --apply run.
#
# Retires local-snapshot RestorePointContents left beyond an age threshold
# (7 days by default) on Veeam Kasten (K10).
#
# Target product : Veeam Kasten 8.5.x / 9.0.x  (apps.kio.kasten.io/v1alpha1)
# Platforms      : OpenShift 4.x (oc) and vanilla Kubernetes (kubectl)
# Dependencies   : oc or kubectl, jq >= 1.6, bash >= 4, coreutils
#                  (date, mktemp, rm, mkdir, wc, tr, cat, cp, mv, tee, sleep,
#                  basename).
#                  No sed, no awk, no grep: all formatting goes through jq.
#                  No GNU-specific syntax, the script also runs on BSD.
#
# DATA MODEL (documented, docs.kasten.io/latest/api/restorepoints):
#   - RestorePoint         : application namespace, apps.kio.kasten.io/v1alpha1
#   - RestorePointContent  : cluster-scoped, carries the actual artifacts
#   - Deleting a RestorePoint does NOT release the underlying artifacts.
#     Only deleting the RestorePointContent triggers a RetireAction that
#     reclaims the snapshots and exported data.
#   => This script therefore acts exclusively on RestorePointContents.
#
# SNAPSHOT vs EXPORT DISCRIMINATOR:
#   Restore points exported to a location profile carry the label
#   k10.kasten.io/exportProfile. Absence of that label = local snapshot.
#   The script only deletes objects without it (--include-exports exists but
#   is deliberately discouraged).
#
# WARNING (docs.kasten.io):
#   "Deletion of a RestorePointContent is permanent and overrides retention
#    by a Policy."
#   Confirm a restore point is no longer needed before deleting it.
#
# Exit codes : 0 success | 1 error | 2 deletion cap exceeded (--apply)
#              3 missing prerequisite
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
# Exemption label key. Overridable through --exempt-label only, and
# deliberately NOT from the environment: the CronJob mounts its ConfigMap with
# envFrom, so any key added there becomes an environment variable. An
# LBL_EXEMPT placed there would silently void every exemption in the cluster.
LBL_EXEMPT="k10-janitor/exempt"

# -------------------------------- Defaults -----------------------------------
# usage() is called from inside the parsing loop: without a frozen copy,
# "--min-keep 5 -h" would advertise "default: 5". Keep the defaults separate.
RETENTION_DAYS=7
K10_NAMESPACE="${K10_NAMESPACE:-kasten-io}"
CLI=""
DRY_RUN=1                 # dry-run by default: deletion only with --apply
MAX_DELETIONS=50          # 0 = unlimited
MIN_KEEP=1                # most recent snapshots always kept, per application
REQUIRE_UNBOUND=0         # 1 = only target RPC whose application is gone
ORPHAN_POLICY_ONLY=0      # 1 = only target RPC with no policy, or a deleted one
POLICY_COUNT="?"          # K10 policies read, "?" if the read failed
OVER_CAP=0                # 1 = candidates beyond --max-deletions
CANDIDATE_BYTES=0         # physical size reported for the deletion candidates
SIZE_UNKNOWN=0            # candidates with no usable physicalSizeBytes
INCLUDE_EXPORTS=0         # 1 = also include exported restore points (discouraged)
WAIT_RETIRE=0             # seconds to wait for RetireActions to complete
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
log()  { if [[ $QUIET -eq 1 ]]; then return 0; fi
         printf '%s [%-5s] %s\n' "$(_ts)" "INFO" "$*" >&2; }
warn() { printf '%s [%-5s] %s\n' "$(_ts)" "WARN" "$*" >&2; }
err()  { printf '%s [%-5s] %s\n' "$(_ts)" "ERROR" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Invariant: exit codes stay 0, 1, 2 or 3. Without this trap, a failing jq or
# utility propagates its own code through 'set -e' (jq exits 5 on a program
# error). 'set -E' above makes the trap follow into functions and subshells.
#
# ACTUAL SCOPE, worth knowing: bash suspends errexit AND this trap inside any
# function invoked within a '||' or '&&' list, or as an 'if' condition. That is
# the case for purge() in main(), called as 'purge || rc=$?'. No failure
# surfaces on its own there, so purge() checks every one of its own.
trap 'err "Unexpected error (line $LINENO)"; exit 1' ERR

readonly DEF_RETENTION_DAYS="$RETENTION_DAYS"
readonly DEF_MIN_KEEP="$MIN_KEEP"
readonly DEF_MAX_DELETIONS="$MAX_DELETIONS"
readonly DEF_K10_NAMESPACE="$K10_NAMESPACE"
readonly DEF_REPORT_DIR="$REPORT_DIR"

usage() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION - retire K10 snapshots past an age threshold

USAGE
  $SCRIPT_NAME [options]

SELECTION
  -d, --retention-days N     Minimum age in days for a snapshot to be a candidate (default: $DEF_RETENTION_DAYS)
      --require-unbound      Only target RestorePointContents in state Unbound
                             (application or namespace deleted from the cluster)
      --orphan-policy-only   Only target RPC with no $LBL_POLICY label,
                             or whose referenced policy no longer exists
      --include-exports      Also include exported restore points (DISCOURAGED)
      --include-namespace NS Restrict to this application namespace (repeatable)
      --exclude-namespace NS Exclude this application namespace (repeatable)
      --exclude-policy NAME  Exclude RPC created by this policy (repeatable)
      --exclude-app NAME     Exclude this application (repeatable)

GUARDS
      --apply                Actually perform the deletions (dry-run otherwise)
      --dry-run              Force dry-run. Useful to neutralise an --apply
                             placed earlier on the command line
      --min-keep N           Always keep the N most recent snapshots per
                             application, even past retention (default: $DEF_MIN_KEEP)
      --max-deletions N      Under --apply, abort if the number of candidates
                             exceeds N. In dry-run the overflow is reported but
                             the exit code stays 0.
                             (default: $DEF_MAX_DELETIONS, 0 = unlimited)
      --wait-retire SEC      Wait up to SEC for the RetireActions to complete
      --exempt-label KEY     Exemption label key (default: $LBL_EXEMPT)

ENVIRONMENT
  -n, --k10-namespace NS     Namespace where K10 is installed (default: $DEF_K10_NAMESPACE)
      --cli oc|kubectl       Force the binary (default: OpenShift autodetection)

OUTPUT
  -r, --report-dir DIR       Report directory (default: $DEF_REPORT_DIR)
      --metrics-file PATH    Write Prometheus metrics (textfile collector)
  -q, --quiet                Quiet, errors only
  -h, --help                 This help

EXAMPLES
  # Report only, 7-day threshold
  $SCRIPT_NAME --retention-days 7

  # Actually retire snapshots older than 14 days, outside the prod namespaces
  $SCRIPT_NAME -d 14 --exclude-namespace prod-db --exclude-namespace prod-app --apply

  # Conservative mode: genuine orphans only (application or policy gone)
  $SCRIPT_NAME -d 7 --require-unbound --orphan-policy-only --apply

PER-OBJECT EXEMPTION
  Add the label $LBL_EXEMPT=true to a RestorePointContent to exclude it
  from the purge permanently:
    <cli> label $RPC_CRD <name> $LBL_EXEMPT=true

WARNING
  Community tool, not supported by Veeam. Independent project, with no
  affiliation with Veeam Software. Provided without any warranty.
  This tool deletes backups permanently: validate it in a lab against your
  own version before any --apply run.
EOF
}

# ----------------------------- Argument parsing ------------------------------
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
    *) err "Unknown option: $1"; usage >&2; exit 1 ;;
  esac
done

[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "--retention-days must be an integer"
[[ "$MIN_KEEP"       =~ ^[0-9]+$ ]] || die "--min-keep must be an integer"
# Invariant: no application may end up with no restore point at all.
# --min-keep 0 would disable the rank guard entirely.
[[ "$MIN_KEEP" -ge 1 ]] || die "--min-keep must be >= 1 (no application may be left without a restore point)"
[[ "$MAX_DELETIONS"  =~ ^[0-9]+$ ]] || die "--max-deletions must be an integer"
[[ "$WAIT_RETIRE"    =~ ^[0-9]+$ ]] || die "--wait-retire must be an integer"

# -------------------------- Prerequis / autodetection ------------------------
detect_cli() {
  if [[ -n "$CLI" ]]; then
    command -v "$CLI" >/dev/null 2>&1 || { err "Binary '$CLI' not found"; exit 3; }
    log "CLI forced: $CLI"
    return
  fi
  # OpenShift: oc present AND the config.openshift.io API (clusterversion)
  if command -v oc >/dev/null 2>&1 && \
     oc get clusterversion version >/dev/null 2>&1; then
    CLI="oc"
    log "OpenShift cluster detected -> using 'oc'"
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
    warn "kubectl not found, falling back to 'oc' in generic Kubernetes mode"
  else
    err "Neither 'oc' nor 'kubectl' found in PATH"; exit 3
  fi
}

check_prereqs() {
  command -v jq >/dev/null 2>&1 || { err "'jq' is required (>= 1.6)"; exit 3; }
  detect_cli
  "$CLI" version --request-timeout=15s >/dev/null 2>&1 \
    || { err "Cannot reach the Kubernetes API with '$CLI'"; exit 3; }
  # RestorePointContent is served by an aggregated APIService
  # (v1alpha1.apps.kio.kasten.io -> kasten-io/aggregatedapis-svc), not by a
  # CRD, so 'get crd' fails on a normal Kasten install. Verified on K10 9.0.3.
  # This stays informational; the real check is reading the objects in
  # fetch_data, which fails with an explicit message.
  if ! "$CLI" get crd "$RPC_CRD" >/dev/null 2>&1; then
    log "$RPC_CRD is not a CRD (Kasten aggregated API expected) - continuing"
  fi
  # The label carries the readable version; the image is often referenced by
  # digest and teaches nothing. Verified on K10 9.0.3: label = "9.0.3", image =
  # registry.connect.redhat.com/kasten/aggregatedapis@sha256:...
  local v
  v="$("$CLI" -n "$K10_NAMESPACE" get deploy -l app=k10 \
        -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)"
  if [[ -z "$v" ]]; then
    v="$("$CLI" -n "$K10_NAMESPACE" get deploy -l app=k10 \
          -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  fi
  # An 'if', not 'cmd && cmd': as the last statement of a function called
  # bare under 'set -e', a false test makes the whole script exit.
  if [[ -n "$v" ]]; then log "K10 version detected: $v"; fi
}

# ------------------------------- Collecte K10 --------------------------------
WORKDIR="$(mktemp -d -t k10janitor.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

fetch_data() {
  log "Collecting $RPC_CRD (cluster-scoped)..."
  "$CLI" get "$RPC_CRD" -o json > "$WORKDIR/rpc.json" \
    || die "Failed to read $RPC_CRD (check the 'list' RBAC permission)"
  local total
  total="$(jq '.items | length' "$WORKDIR/rpc.json")"
  log "$total RestorePointContents retrieved"

  log "Collecting K10 policies in '$K10_NAMESPACE'..."
  if "$CLI" -n "$K10_NAMESPACE" get "$POLICY_CRD" -o json > "$WORKDIR/policies.json" 2>/dev/null; then
    jq '[.items[].metadata.name]' "$WORKDIR/policies.json" > "$WORKDIR/policy_names.json"
    POLICY_COUNT="$(jq 'length' "$WORKDIR/policy_names.json")"
    log "$POLICY_COUNT active policies"
    # Zero policies makes --orphan-policy-only inoperative: with no reference
    # policy left, every snapshot looks orphaned. Reachable with a wrong
    # --k10-namespace, since the RPC resource is cluster-scoped: the namespaced
    # query then succeeds with zero results.
    if [[ $ORPHAN_POLICY_ONLY -eq 1 && "$POLICY_COUNT" -eq 0 ]]; then
      err "--orphan-policy-only requested, but no policy found in '$K10_NAMESPACE'."
      err "With no reference policy, every snapshot would look orphaned. Check --k10-namespace."
      exit 3
    fi
  else
    echo 'null' > "$WORKDIR/policy_names.json"
    # The filter is restrictive: dropping it would widen the deletion scope.
    # Abort rather than degrade silently.
    if [[ $ORPHAN_POLICY_ONLY -eq 1 ]]; then
      err "--orphan-policy-only requested, but the policies are unreadable in '$K10_NAMESPACE'."
      err "Refusing to continue without the filter: check the 'list' RBAC permission on $POLICY_CRD."
      exit 3
    fi
    warn "Policies unreadable - the policy-orphan filter is unavailable"
  fi
}

json_array() { # turns the arguments into a JSON array
  if [[ $# -eq 0 ]]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -s .; fi
}

# ---------------------------- Moteur de decision -----------------------------
# Produces JSONL: one object per RestorePointContent, with .decision =
#   DELETE | KEEP, and an explicit .reason. No mutation happens here.
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
      # would raise an uncatchable error on those types.
      if (type != "string") or . == "" then null
      # jq fromdateiso8601 accepts the Z suffix only. So we strip fractional
      # seconds before a Z, and nothing else: a timestamp carrying a numeric
      # offset (+02:00, -04:00) stays unparsable and falls to
      # KEEP timestamp-unparseable. Deliberate: converting the offset by hand
      # could age an object, and therefore delete it. Verified on K10 9.0.3,
      # every timestamp is Z-suffixed.
      # NOTE: no apostrophe in this block, it lives in a single-quoted string.
      else sub("\\.[0-9]+Z$"; "Z") end;
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
            # Absent, null, non-numeric and negative all count as "unknown",
            # never as a real zero. Keeping a string out of the sum also
            # matters because jq add concatenates strings instead of failing.
            hasLogicalSize:
              ((.status.logicalSizeBytes | type) == "number"
               and .status.logicalSizeBytes >= 0),
            hasPhysicalSize:
              ((.status.physicalSizeBytes | type) == "number"
               and .status.physicalSizeBytes >= 0),
            logicalSizeBytes:
              (if (.status.logicalSizeBytes | type) == "number"
                  and .status.logicalSizeBytes >= 0
               then .status.logicalSizeBytes else 0 end),
            physicalSizeBytes:
              (if (.status.physicalSizeBytes | type) == "number"
                  and .status.physicalSizeBytes >= 0
               then .status.physicalSizeBytes else 0 end)
          }
        # reference timestamp: actionTime > scheduledTime > creationTimestamp
        | .refTime = (.actionTime // .scheduledTime // .created)
        | .refEpoch = (.refTime | to_epoch)
        | .ageDays  = (if .refEpoch == null then null
                       else (($NOW - .refEpoch) / 86400 * 100 | floor) / 100 end)
        # Discriminator = label PRESENCE, not its value. Kubernetes allows an
        # empty label value, and in jq only null and false are falsy, so the
        # empty string flowed through the // and passed for a snapshot.
        | .kind     = (if .hasExport then "export" else "snapshot" end)
        | .appKey   = (if .appNamespace == "" then "<unknown>" else .appNamespace end)
                      + "/" + (if .appName == "" then "<unknown>" else .appName end)
        | .onDemand = (.policyName == "")
        | .policyExists = (if .policyName == "" then false
                           elif $policies == null then true
                           else (.policyName as $p | ($policies | index($p)) != null) end)
      ]
    # rank per application, newest to oldest, over the eligible scope only
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

# --------------------------------- Reports -----------------------------------
write_reports() {
  mkdir -p "$REPORT_DIR" || die "Report directory not writable: $REPORT_DIR"
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
        (if .hasLogicalSize  then (.logicalSizeBytes|tostring)  else "" end),
        (if .hasPhysicalSize then (.physicalSizeBytes|tostring) else "" end),
        (if .rpNamespace == "" then "" else .rpNamespace + "/" + .rpName end)
      ] | @csv' "$WORKDIR/decisions.jsonl"
  } > "$REPORT_CSV"

  log "CSV report   : $REPORT_CSV"
  log "JSONL report : $REPORT_JSONL"
}

summarize() {
  TOTAL=$(wc -l < "$WORKDIR/decisions.jsonl" | tr -d ' ')
  CANDIDATES=$(jq -r 'select(.decision=="DELETE") | .name' "$WORKDIR/decisions.jsonl" | wc -l | tr -d ' ')
  if [[ "$MAX_DELETIONS" -gt 0 && "$CANDIDATES" -gt "$MAX_DELETIONS" ]]; then OVER_CAP=1; fi
  SNAPSHOTS=$(jq -r 'select(.kind=="snapshot") | .name' "$WORKDIR/decisions.jsonl" | wc -l | tr -d ' ')
  EXPORTS=$(jq -r 'select(.kind=="export") | .name' "$WORKDIR/decisions.jsonl" | wc -l | tr -d ' ')
  CANDIDATE_BYTES=$(jq -s '[.[] | select(.decision=="DELETE" and .hasPhysicalSize)
                            | .physicalSizeBytes] | add // 0' "$WORKDIR/decisions.jsonl")
  SIZE_UNKNOWN=$(jq -s '[.[] | select(.decision=="DELETE" and (.hasPhysicalSize | not))]
                        | length' "$WORKDIR/decisions.jsonl")

  {
    echo "=============================================================="
    echo " Veeam Kasten - retiring snapshots past the age threshold"
    echo " run_id            : $RUN_ID"
    echo " cli               : $CLI"
    echo " K10 namespace     : $K10_NAMESPACE"
    echo " retention days    : ${RETENTION_DAYS}"
    echo " mode              : $([[ $DRY_RUN -eq 1 ]] && echo 'DRY-RUN (nothing deleted)' || echo 'APPLY (real deletion)')"
    echo " min-keep          : $MIN_KEEP recent snapshot(s) per application"
    echo " max-deletions     : $([[ $MAX_DELETIONS -eq 0 ]] && echo 'unlimited' || echo "$MAX_DELETIONS")$([[ $OVER_CAP -eq 1 ]] && echo "  (OVER CAP: $CANDIDATES candidates, an --apply would be refused)" || echo '')"
    echo " require-unbound   : $REQUIRE_UNBOUND"
    echo " orphan-policy-only: $ORPHAN_POLICY_ONLY"
    echo " K10 policies read : $POLICY_COUNT"
    echo "--------------------------------------------------------------"
    echo " RestorePointContents inventoried : $TOTAL"
    echo "   of which local snapshots       : $SNAPSHOTS"
    echo "   of which exports (never purged): $EXPORTS"
    echo " Deletion candidates              : $CANDIDATES"
    echo " Candidate physical size          : $CANDIDATE_BYTES bytes$([[ $SIZE_UNKNOWN -gt 0 ]] && echo " ($SIZE_UNKNOWN candidate(s) with unknown size)" || echo '')"
    echo "--------------------------------------------------------------"
    echo " KEEP decisions by reason :"
    # Aggregated in jq rather than 'sort | uniq -c | sort -rn | sed': that
    # removes sed, the only binary outside bash, jq, oc/kubectl and coreutils.
    jq -rs '
      def lpad($n): tostring | if ($n - length) > 0
                               then (" " * ($n - length)) + . else . end;
      [ .[] | select(.decision=="KEEP") | .reason ]
      | group_by(.) | map({reason: .[0], n: length}) | sort_by(-.n)
      | .[] | "   \(.n | lpad(4)) \(.reason)"' "$WORKDIR/decisions.jsonl"
    echo "--------------------------------------------------------------"
    if [[ "$CANDIDATES" -gt 0 ]]; then
      echo " Candidates (age_days | namespace/app | policy | rpc) :"
      jq -r 'select(.decision=="DELETE")
             | "   \(.ageDays)d | \(.appNamespace)/\(.appName) | \(if .policyName=="" then "<on-demand>" else .policyName end) | \(.name)"' \
        "$WORKDIR/decisions.jsonl"
    else
      echo " No candidate."
    fi
    echo "=============================================================="
  } | tee "${REPORT_SUMMARY:-/dev/null}" >&2
}

write_metrics() {
  if [[ -z "$METRICS_FILE" ]]; then return 0; fi
  local tmp="${METRICS_FILE}.$$"
  if ! cat > "$tmp" <<EOF
# HELP k10_janitor_last_run_timestamp_seconds Timestamp of the last run.
# TYPE k10_janitor_last_run_timestamp_seconds gauge
k10_janitor_last_run_timestamp_seconds $(date -u +%s)
# HELP k10_janitor_dry_run 1 if the last run was a dry-run.
# TYPE k10_janitor_dry_run gauge
k10_janitor_dry_run $DRY_RUN
# HELP k10_janitor_retention_days Age threshold applied.
# TYPE k10_janitor_retention_days gauge
k10_janitor_retention_days $RETENTION_DAYS
# HELP k10_janitor_restorepointcontents_total Total inventory.
# TYPE k10_janitor_restorepointcontents_total gauge
k10_janitor_restorepointcontents_total $TOTAL
# HELP k10_janitor_candidates_total Number of candidates identified.
# TYPE k10_janitor_candidates_total gauge
k10_janitor_candidates_total $CANDIDATES
# HELP k10_janitor_over_cap 1 if candidates exceed --max-deletions.
# TYPE k10_janitor_over_cap gauge
k10_janitor_over_cap $OVER_CAP
# HELP k10_janitor_deleted_total Number of successful deletions.
# TYPE k10_janitor_deleted_total gauge
k10_janitor_deleted_total ${DELETED:-0}
# HELP k10_janitor_failed_total Number of failed deletions.
# TYPE k10_janitor_failed_total gauge
k10_janitor_failed_total ${FAILED:-0}
# HELP k10_janitor_candidate_physical_bytes Physical size reported for the deletion candidates. Not a promise of reclaimable space.
# TYPE k10_janitor_candidate_physical_bytes gauge
k10_janitor_candidate_physical_bytes $CANDIDATE_BYTES
# HELP k10_janitor_candidate_size_unknown_total Deletion candidates whose physicalSizeBytes is absent or not numeric.
# TYPE k10_janitor_candidate_size_unknown_total gauge
k10_janitor_candidate_size_unknown_total $SIZE_UNKNOWN
EOF
  then
    warn "Cannot write metrics: $tmp"
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$METRICS_FILE"; then
    warn "Cannot move metrics into place: $METRICS_FILE"
    rm -f "$tmp"
    return 1
  fi
  log "Prometheus metrics: $METRICS_FILE"
}

# -------------------------------- Deletion ------------------------------------
purge() {
  DELETED=0
  FAILED=0

  if [[ "$CANDIDATES" -eq 0 ]]; then
    log "Nothing to delete."
    return 0
  fi

  # The invariant 6 guard must not depend on any call order. summarize()
  # computes the same OVER_CAP for the report and the metrics; purge() does not
  # trust it and recomputes for itself.
  local over_cap=0
  if [[ "$MAX_DELETIONS" -gt 0 && "$CANDIDATES" -gt "$MAX_DELETIONS" ]]; then
    over_cap=1
  fi

  # The cap is a brake on deletion, so it only makes sense where a deletion can
  # happen. In dry-run the report comes out complete, the overflow is reported,
  # and the exit code stays 0 - otherwise the very first scheduled run against
  # a cluster with real backlog marks the Job as Failed.
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: $CANDIDATES RestorePointContents would be deleted. Nothing was done."
    if [[ $over_cap -eq 1 ]]; then
      warn "$CANDIDATES candidats > plafond --max-deletions=$MAX_DELETIONS : un --apply serait refuse en l'etat."
    fi
    log "Re-run with --apply to perform the purge."
    return 0
  fi

  if [[ $over_cap -eq 1 ]]; then
    err "$CANDIDATES candidates > --max-deletions=$MAX_DELETIONS cap: aborting for safety."
    err "Review the report, then re-run with a suitable cap if the result is expected."
    return 2
  fi

  warn "APPLY: deleting $CANDIDATES RestorePointContents."
  warn "Deletion is permanent and overrides policy retention."

  # purge() is called as 'purge || rc=$?': bash suspends errexit AND the ERR
  # trap for the whole duration of the function. No failure surfaces on its
  # own here, so each one is checked explicitly. This is the only function that
  # deletes: a swallowed failure would be a lost record.
  local name audit_errors=0
  while IFS= read -r name; do
    if [[ -z "$name" ]]; then continue; fi
    if "$CLI" delete "$RPC_CRD" "$name" --wait=false >/dev/null 2>"$WORKDIR/del.err"; then
      DELETED=$((DELETED + 1))
      printf '%s [%-5s] deleted %s=%s\n' "$(_ts)" "AUDIT" "$RPC_CRD" "$name" >&2
      if ! jq -c --arg n "$name" --arg ts "$(_ts)" \
          'select(.name==$n) | . + {deletedAt: $ts, deleteResult: "ok"}' \
          "$WORKDIR/decisions.jsonl" >> "$REPORT_JSONL.audit"; then
        audit_errors=$((audit_errors + 1))
      fi
    else
      FAILED=$((FAILED + 1))
      err "Failed to delete $name: $(tr '\n' ' ' < "$WORKDIR/del.err")"
      if ! jq -c --arg n "$name" --arg ts "$(_ts)" --arg e "$(tr '\n' ' ' < "$WORKDIR/del.err")" \
          'select(.name==$n) | . + {deletedAt: $ts, deleteResult: "failed", error: $e}' \
          "$WORKDIR/decisions.jsonl" >> "$REPORT_JSONL.audit"; then
        audit_errors=$((audit_errors + 1))
      fi
    fi
  done < <(jq -r 'select(.decision=="DELETE") | .name' "$WORKDIR/decisions.jsonl")

  log "Deletions: $DELETED succeeded, $FAILED failed."
  if [[ -f "$REPORT_JSONL.audit" ]]; then log "Audit trail: $REPORT_JSONL.audit"; fi

  if [[ "$WAIT_RETIRE" -gt 0 && "$DELETED" -gt 0 ]]; then
    wait_for_retire
  fi

  if [[ "$audit_errors" -gt 0 ]]; then
    err "$audit_errors audit-trail line(s) could not be written to $REPORT_JSONL.audit"
    err "Deletions happened without a complete file record. The AUDIT lines on"
    err "standard error remain the reference trail."
    return 1
  fi
  if [[ "$FAILED" -gt 0 ]]; then return 1; fi
  return 0
}

wait_for_retire() {
  log "Waiting for the RetireActions to complete (max ${WAIT_RETIRE}s)..."
  local deadline=$(( $(date -u +%s) + WAIT_RETIRE )) pending
  while [[ $(date -u +%s) -lt $deadline ]]; do
    pending="$("$CLI" get "$RETIRE_CRD" -o json 2>/dev/null \
      | jq '[.items[] | select(.status.state != "Complete" and .status.state != "Failed" and .status.state != "Skipped")] | length' 2>/dev/null || echo 0)"
    if [[ "${pending:-0}" -eq 0 ]]; then
      log "All RetireActions have completed."
      return 0
    fi
    log "RetireActions en cours : $pending"
    sleep 15
  done
  warn "Timeout reached, some RetireActions are still running (normal for large exports)."
}

# ---------------------------------- Main --------------------------------------
main() {
  log "$SCRIPT_NAME v$SCRIPT_VERSION - run_id=$RUN_ID"
  log "Community tool, not supported by Veeam - provided without warranty"
  check_prereqs
  fetch_data
  evaluate
  write_reports
  summarize
  local rc=0
  purge || rc=$?
  # Metrics are observability: their failure must not overwrite the purge exit
  # code, the only piece of information that involves data.
  # write_metrics warns on its own already.
  write_metrics || true
  exit $rc
}

main "$@"
