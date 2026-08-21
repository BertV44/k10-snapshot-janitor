# Automated housekeeping of K10 snapshots past an age threshold

Target versions: **Veeam Kasten 8.5.x and 9.0.x** (`apps.kio.kasten.io/v1alpha1`), OpenShift 4.x and Kubernetes 1.27+.
CLI: `oc` first (OpenShift autodetection), falling back to `kubectl`.

## Contents

| File | Role |
|---|---|
| `bin/k10-snapshot-janitor.sh` | The housekeeping script, dry-run by default |
| `deploy/cronjob.yaml` | ServiceAccount, least-privilege RBAC, settings ConfigMap, reports PVC, daily CronJob |
| `deploy/Containerfile` | UBI9-minimal image + `oc` + `jq` for the CronJob |
| `test/run-tests.sh` | Offline test suite for the decision engine |

---

## 1. What the script targets, and why

### The object it acts on: `RestorePointContent`, not `RestorePoint`

[available] The documentation is explicit: deleting a `RestorePoint` **does not release** the underlying artifacts. Only deleting the `RestorePointContent` (cluster-scoped) triggers a `RetireAction` that reclaims the snapshots and the data. The script therefore acts exclusively on `RestorePointContents`.

### Local snapshot vs export

The requested scope is **snapshots only, never exports**. The discriminator is the `k10.kasten.io/exportProfile` label:

- label absent  -> local snapshot, eligible
- label present -> restore point exported to a location profile, **always kept**

The discriminator is the *presence* of the label, not its value. Kubernetes allows an empty label value, and an export with an empty value is still an export.

[validate in a lab against your target version] The "Restore Points" page of the 9.0.3 documentation only lists `appName`, `appNamespace` and `appType` in its section on automatic labels. The `exportProfile` label is documented elsewhere as the way to distinguish exported restore points. Before the first `--apply` run, check on your own cluster:

```bash
# How many exported RPC versus local ones?
oc get restorepointcontents.apps.kio.kasten.io \
  -l 'k10.kasten.io/exportProfile' -o name | wc -l
oc get restorepointcontents.apps.kio.kasten.io \
  -l '!k10.kasten.io/exportProfile' -o name | wc -l
```

Cross-check those counts against the K10 dashboard. If the numbers do not line up, do not move to `--apply`.

### Reference timestamp

The script takes, in this order: `status.actionTime`, then `status.scheduledTime`, then `metadata.creationTimestamp`. [available] `scheduledTime` can be `null` for on-demand actions, hence the ordering. An unparsable timestamp yields a `KEEP` decision with the reason `timestamp-unparseable`, never a deletion.

A timestamp carrying a numeric UTC offset (`+02:00`, `-04:00`) is treated as unparsable and also resolves to `KEEP`. This is deliberate: converting the offset by hand could age an object, and an object that looks older than it is gets deleted. On 9.0.3 every timestamp is Z-suffixed.

### The underlying warning

> [available, docs.kasten.io] "Deletion of a RestorePointContent is permanent and overrides retention by a Policy."

A snapshot older than X days is **not** necessarily an orphan. A legitimate GFS policy keeps monthly and yearly points. Running the script with a 7-day threshold and no restriction will delete those points despite the policy. That is why the script offers the two restriction modes described below, and why the conservative mode is the one to prefer on a production cluster.

### The native mechanism, for reference

[available] The K10 Garbage Collector already cleans up the `RestorePointContents` of manual backups whose `spec.expiresAt` has passed (settable through the API or the manual snapshot page in the UI). This script covers what the GC does not: snapshots with no `expiresAt`, those from deleted policies, and those of applications removed from the cluster.

---

## 2. Selection modes

| Mode | Options | What gets deleted |
|---|---|---|
| Age only (default) | `-d 7` | every local snapshot older than 7 days, including those covered by an active policy |
| Policy orphans | `--orphan-policy-only` | on-demand snapshots (no `policyName` label) and snapshots whose referenced policy no longer exists |
| Vanished applications | `--require-unbound` | snapshots whose `RestorePointContent` is in state `Unbound`, meaning the application or namespace has been deleted |
| Conservative (recommended) | `--require-unbound --orphan-policy-only` | the intersection of both: genuine orphans only |

The conservative mode corresponds to `CONSERVATIVE_MODE: "true"` in the ConfigMap.

## 3. Guards

| Guard | Behaviour |
|---|---|
| Dry-run by default | No deletion without `--apply`. The report is produced either way. |
| `--dry-run` | Forces report-only mode, and overrides an `--apply` placed earlier on the command line. |
| `--min-keep N` | Always keeps the N most recent snapshots per application (`appNamespace/appName`), even past the threshold. Default 1, and **0 is rejected outright**: no application may be left without a restore point. |
| `--wait-retire N` | After an `--apply`, wait up to N seconds for the triggered `RetireActions` to reach `Complete`. 0 = no wait, the CronJob default. A timeout is a warning, not an error: reclamation takes a long time on large exports. |
| `--max-deletions N` | Under `--apply`, aborts immediately with exit code 2 if the number of candidates exceeds N. Default 50. Protects against a filter mistake or a missing label. In dry-run the overflow is reported in the summary and through the `k10_janitor_over_cap` metric, but the exit code stays 0: an identification report is not a failure. |
| Missing policy data | If `--orphan-policy-only` is requested and the policy list is unreadable or empty, the run aborts with exit code 3 rather than dropping the restrictive filter. Without a reference policy, every snapshot would look orphaned. |
| `--exclude-namespace`, `--exclude-policy`, `--exclude-app` | Repeatable exclusions. |
| `--include-namespace` | Scope restriction, for a progressive rollout. |
| Exemption label | `k10-janitor/exempt=true` on a `RestorePointContent` removes it from the scope permanently. The key is settable through `--exempt-label` only, never from the environment, so a ConfigMap key cannot silently void every exemption. |
| Exports untouched | `--include-exports` exists but is discouraged and never used by the CronJob. |

Exempting a specific object:

```bash
oc label restorepointcontents.apps.kio.kasten.io <name> k10-janitor/exempt=true
```

## 4. Reports and audit

Every run writes four timestamped files per `run_id` into `--report-dir`, the last one only under `--apply`:

- `k10-janitor-<run_id>.csv`: one line per inventoried `RestorePointContent`, with `decision`, `reason`, age, application, policy, sizes and rank
- `k10-janitor-<run_id>.jsonl`: the same content as JSON Lines, consumable by `jq` or a SIEM ingest
- `k10-janitor-<run_id>.summary.txt`: readable synthesis, including the breakdown of KEEP reasons
- `k10-janitor-<run_id>.jsonl.audit`: produced only under `--apply`, one line per deletion with `deletedAt` and `deleteResult`

Every deletion is also traced on stderr with the `AUDIT` prefix, which makes it recoverable from the pod logs and by the cluster log collection chain. If an audit line cannot be written to the file, the run exits 1 and says how many lines are missing: the stderr `AUDIT` lines remain the reference trail.

Prometheus metrics through `--metrics-file` (textfile collector format):

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

[unverified] The textfile collector is not directly usable from a CronJob pod without node-exporter mounted on the same volume. For a Grafana dashboard, the simplest options are a Pushgateway or a sidecar scraping the PVC. To be decided against the customer monitoring stack.

## 5. Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or dry-run completed |
| 1 | At least one deletion failed, the audit trail could not be written, or a runtime error |
| 2 | `--max-deletions` cap exceeded under `--apply`, nothing deleted |
| 3 | Missing prerequisite: `jq`, `oc`/`kubectl` or an unreachable API, **or** `--orphan-policy-only` requested while the policies are unreadable or none was found in the K10 namespace |

On an argument-validation exit 1 and on every exit 3, no report is written: the
run aborts before `write_reports`. The metrics are not refreshed either, so the
`.prom` file keeps the previous run values. Watch
`k10_janitor_last_run_timestamp_seconds` to detect those aborts.

## 6. Rollout

### Manual run from a bastion

```bash
chmod +x bin/k10-snapshot-janitor.sh

# Report only
./bin/k10-snapshot-janitor.sh -d 7 -r ./reports

# Real scope, conservative mode, actual deletion
./bin/k10-snapshot-janitor.sh -d 7 \
  --require-unbound --orphan-policy-only \
  --exclude-namespace prod-db \
  --min-keep 2 --max-deletions 25 \
  -r ./reports --apply
```

### In-cluster CronJob

```bash
# 1. Image
podman build -t k10-snapshot-janitor:1.0.0 -f deploy/Containerfile .
# then push it to the internal registry, and replace
# REGISTRY/k10-snapshot-janitor:1.0.0 in deploy/cronjob.yaml

# 2. Script in a ConfigMap
oc -n kasten-io create configmap k10-snapshot-janitor-script \
  --from-file=k10-snapshot-janitor.sh=./bin/k10-snapshot-janitor.sh

# 3. RBAC, PVC, CronJob (ships in dry-run)
oc apply -f deploy/cronjob.yaml

# 4. Immediate test, without waiting for 03:00
oc -n kasten-io create job k10-janitor-manual-01 \
  --from=cronjob/k10-snapshot-janitor
oc -n kasten-io logs -f job/k10-janitor-manual-01
```

Switching to real deletion, once the reports have been reviewed:

```bash
oc -n kasten-io patch configmap k10-snapshot-janitor-config \
  --type merge -p '{"data":{"PURGE_APPLY":"true"}}'
```

Reading the persisted reports:

```bash
oc -n kasten-io debug job/k10-janitor-manual-01 -- ls -l /reports
```

Updating the script after a change:

```bash
oc -n kasten-io create configmap k10-snapshot-janitor-script \
  --from-file=k10-snapshot-janitor.sh=./bin/k10-snapshot-janitor.sh \
  --dry-run=client -o yaml | oc apply -f -
```

## 7. Recommended production sequence

1. Manual dry-run across the whole cluster, realistic threshold, no exclusions. Read `summary.txt` and check the breakdown of KEEP reasons.
2. Cross-check the `of which exports (never purged)` line against the expected number of exports. A discrepancy means the `exportProfile` discriminator does not behave as expected on this version: stop there.
3. Move to `--apply` on a single non-critical namespace with `--include-namespace`, then verify in the K10 UI that the expected points are gone and that the `RetireActions` are `Complete`.
4. Widen the scope in conservative mode, with a low `--max-deletions` to start with.
5. Set `PURGE_APPLY` to `true` in the ConfigMap and let the CronJob run.

## 8. Known limitations

- Space reclamation is neither immediate nor proportional. [available] Deduplication, data shared between restore points, version retention for immutable backups and safety windows can all delay or cancel the gain. The `reclaimable_bytes` field of the report is an indicative upper bound based on `status.physicalSizeBytes`. **[unverified]** that field was absent from the entire inventory of the validation cluster, where the script therefore reports 0: see section 9.
- The script does not touch `ClusterRestorePoints` (cluster-scoped resources produced by `BackupClusterAction`). To be handled separately if the need arises.
- The script does not look for orphaned CSI `VolumeSnapshots` at the storage layer, meaning those no longer referenced by any `RestorePointContent`. That is a distinct kind of leak and needs dedicated logic.
- `k10.kasten.io/appType` can be absent on restore points created by older Kasten versions. **[available]** present across the entire 9.0.3 inventory, with the value `namespace`. The script treats absence as `namespace` and does not rely on this label to decide.

## 9. Lab validation

Findings from an OpenShift 4.20 cluster (Kubernetes 1.33) running
**Kasten K10 9.0.3**, on an inventory of 8 `RestorePointContents`.
No `--apply` run was performed: everything below comes from reads and dry-runs.

### Confirmed on 9.0.3

| Assumption | Status |
|---|---|
| The `k10.kasten.io/exportProfile` label is emitted on exported restore points | **[available]** present on 6 of the 8 objects, with real profile values |
| Its absence identifies a local snapshot | **[available]** the 2 objects without it are the local snapshots, and the script classified them as such |
| The label is never emitted with an empty value | **[unverified]** no empty value in this sample, but 6 objects prove little. The engine now tests the presence of the label rather than its value, so the assumption no longer needs to hold |
| `RestorePointContent` is cluster-scoped | **[available]** confirmed through `oc api-resources` |
| `status.state`, `status.actionTime`, `status.scheduledTime` and `status.restorePointRef` are present | **[available]** present on all 8 objects |
| `k10.kasten.io/appName` and `appNamespace` are always populated | **[unverified]** present on all 8, but all of them are `Bound`. The risky case remains an `Unbound` object with no `appName` |

Control dry-run: 8 objects inventoried, 2 local snapshots, 6 exports,
0 candidates. The 6 exports came out as `KEEP export-restorepoint`, the 2 local
snapshots as `KEEP min-keep-guard` since each is the only one of its
application. The classification matches label presence exactly.

### What the lab corrected

- **`RestorePointContent` is not a CRD.** Kasten serves it through an
  aggregated APIService, `v1alpha1.apps.kio.kasten.io` to `aggregatedapis-svc`.
  The `oc get crd` probe in `check_prereqs` therefore fails on every normal
  install. It used to emit a warning blaming RBAC, which was simply wrong; it
  is now an informational line.
- **The K10 version lives in a label**, `app.kubernetes.io/version` on the
  `app=k10` deployment. The image is referenced by digest and teaches nothing.
  The script now reads the label first.

### Still to validate

- **8.5.x.** None of the above has been checked on that version.
- **`status.physicalSizeBytes` and `logicalSizeBytes`** are absent from all 8
  objects, which are all of type `appConfigOnly` with no volume data. The
  script defaults them to 0, so `reclaimable_bytes` and the "Candidate physical
  size" line both report 0. Revalidate on a cluster holding real volume
  snapshots before trusting those figures.
- **The behaviour of an export whose source snapshot has been retired.** Not
  tested: it requires a real deletion.
- **An `Unbound` object with no `appName`**, the case that would collapse the
  per-application grouping. Absent from this inventory.
- An additional label, `k10.kasten.io/exportType` (observed value
  `appConfigOnly`), co-occurs exactly with `exportProfile`. The script does not
  use it. A possible fallback discriminator.

## 10. Testing

The decision engine is validated offline against generated fixtures covering:
recent and very old exports, an export whose `exportProfile` label carries an
empty value, a snapshot within the threshold, a snapshot past the threshold
with an active policy, a snapshot whose policy has been deleted, an on-demand
snapshot, a snapshot in state `Unbound`, a snapshot carrying the exemption
label, an application with a single snapshot, an unparsable timestamp, a
non-string timestamp, timestamps with numeric offsets, an object with none of
the three timestamp sources, an excluded namespace, and an empty inventory.

Exit paths covered: dry-run with no side effect, `--apply` with a complete
audit trail, an unwritable audit trail during `--apply`, `--max-deletions`
exceeded under `--apply` with exit 2 and zero deletions, the same overflow in
dry-run with exit 0, a metrics write failure not overwriting the exit code, a
failed deletion with exit 1, `--min-keep 2`, `--min-keep 0` rejected,
`--include-namespace`, `--include-exports`, `--exclude-policy`,
`--exclude-app`, `--dry-run` overriding an earlier `--apply`, and
`--require-unbound --orphan-policy-only` with unreadable and with empty policy
lists.

Four guards are verified by mutation rather than by merely passing: retargeting
the delete call at another resource, changing the age comparison from `<=` to
`<`, removing `set -f` from the CronJob argument builder, and keying the export
discriminator on the label value instead of its presence. Each makes a specific
assertion fail.

The suite generates its own fixtures and a fake `kubectl` binary. It contacts
no cluster, and must stay that way. A skipped case is fatal: a suite that
quietly runs at 97% would be worse than one that fails.

---

## Sources

- [API and Command Line](https://docs.kasten.io/latest/api/cli)
- [Restore Points](https://docs.kasten.io/latest/api/restorepoints)
- [Actions (RetireAction)](https://docs.kasten.io/latest/api/actions)
- [Garbage Collector](https://docs.kasten.io/latest/operating/garbagecollector)
