# k10-snapshot-janitor

Housekeeping for stale **Veeam Kasten** snapshots: finds `RestorePointContent`
objects that hold local snapshots older than a given threshold, reports on them,
and optionally retires them. Dry-run by default.

> **Not a Veeam product.** This is a community tool, developed independently and
> **not supported by Veeam Software**. It deletes backup data. Read
> [`docs/RUNBOOK.md`](docs/RUNBOOK.md) in full before running it with `--apply`,
> and validate it in a lab against your own Kasten version first.

## Why

Kasten retires restore points through policy retention. Restore points that no
policy retains are never cleaned up automatically:

- on-demand snapshots taken without an `expiresAt` value
- snapshots whose originating policy has since been deleted
- snapshots of applications or namespaces that no longer exist in the cluster

Over time these accumulate and keep consuming storage. This tool finds them,
reports them, and can retire them on a schedule.

## Scope

- Acts on `RestorePointContent` only. Deleting a `RestorePoint` does not release
  the underlying artifacts; deleting a `RestorePointContent` triggers a
  `RetireAction` that does.
- **Local snapshots only.** Restore points *carrying* the
  `k10.kasten.io/exportProfile` label are treated as exports and are never
  candidates in normal operation. The discriminator is the presence of the
  label, not its value: Kubernetes allows an empty label value, and an export
  is still an export. `--include-exports` lifts that protection; it exists, it
  is discouraged, and the shipped CronJob never uses it.
- Does not handle `ClusterRestorePoint` objects, nor orphaned CSI
  `VolumeSnapshot` objects at the storage layer.

## Requirements

| | |
|---|---|
| Veeam Kasten | 8.5.x, 9.0.x |
| Kubernetes | 1.27+ |
| OpenShift | 4.14+ |
| CLI | `oc` (auto-detected) or `kubectl` |
| Tools | `bash` 4+, `jq` 1.6+, coreutils (`date`, `mktemp`, `rm`, `mkdir`, `wc`, `tr`, `cat`, `cp`, `mv`, `tee`, `sleep`, `basename`). No `sed`, `awk` or `grep` |

## Quick start

```bash
# Report only, 7-day threshold, nothing is deleted
./bin/k10-snapshot-janitor.sh --retention-days 7 --report-dir ./reports

# Conservative mode: only genuine orphans, actually retire them
./bin/k10-snapshot-janitor.sh --retention-days 7 \
  --require-unbound --orphan-policy-only \
  --min-keep 2 --max-deletions 25 \
  --report-dir ./reports --apply
```

`--dry-run` forces report-only mode and overrides an `--apply` placed earlier on
the command line. `--wait-retire N` waits up to N seconds for the triggered
`RetireActions` to complete. Run `--help` for the full option list.

## Safety model

| Guard | Behaviour |
|---|---|
| Dry-run default | Nothing is deleted without `--apply` |
| `--min-keep N` | Always keeps the N most recent snapshots per application |
| `--max-deletions N` | Under `--apply`, aborts with exit code 2 if candidates exceed N, deleting nothing. A dry-run reports the overflow and still exits 0 |
| Exemption label | `k10-janitor/exempt=true` on a `RestorePointContent` excludes it permanently |
| Exports excluded | Exported restore points are never candidates in normal operation |
| Unparsable timestamp | Always resolves to `KEEP`, including a numeric offset such as `+02:00`, or a value that is not a string at all |
| `--min-keep 0` | Rejected outright with exit 1: no application may be left without a restore point |
| Missing policy data | If `--orphan-policy-only` is requested and the policy list is unreadable or empty, the run aborts with exit 3 rather than dropping the filter |
| Exemption key | Settable only through `--exempt-label`, never from the environment, so a ConfigMap key cannot silently void every exemption |
| Nothing else is mutated | The only write the script performs is deleting a `RestorePointContent`. Asserted by the test suite on the full CLI command line |

Every run writes a CSV, a JSONL and a summary per `run_id`, plus a separate
audit trail when `--apply` is used. Each decision carries an explicit reason.
If an audit line cannot be written after a successful deletion, the run exits 1
rather than reporting success: the `AUDIT` lines on stderr remain the reference
trail.

Deleting a `RestorePointContent` is permanent and overrides policy retention.
A snapshot older than the threshold is not necessarily an orphan: a legitimate
GFS policy keeps monthly and yearly points. Prefer
`--require-unbound --orphan-policy-only` on production clusters.

## Scheduled operation

`deploy/cronjob.yaml` provides a daily CronJob with a dedicated ServiceAccount,
least-privilege RBAC, a parameter ConfigMap and a PVC for reports. It ships in
dry-run mode. See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for the rollout
procedure.

## Tests

```bash
./test/run-tests.sh
```

91 assertions, entirely offline: fixtures and a stub CLI are generated on the
fly, no cluster is contacted. A skipped case is fatal — a suite that quietly
runs at 97% is worse than one that fails, so `python3` and `pyyaml` are
required for the manifest checks.

Guards that matter are verified by mutation, not just by passing: breaking the
export discriminator, the age comparison, the resource targeted by the delete
call, or the globbing protection in the CronJob each make a specific assertion
fail.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or dry-run completed |
| 1 | A deletion failed, the audit trail could not be written, or a runtime error |
| 2 | `--max-deletions` ceiling exceeded under `--apply`, nothing deleted |
| 3 | Missing prerequisite, or `--orphan-policy-only` requested with no readable policy |

On exit 3, and on an argument-validation exit 1, no report is written and the
metrics file is not refreshed.

## Validation status

| | |
|---|---|
| Kasten 9.0.3 | **Verified in a lab.** The `exportProfile` discriminator behaves as assumed, and a control dry-run classified a real inventory exactly as the labels dictate |
| Kasten 8.5.x | **Not verified.** Nothing from the 9.0.3 run transfers |
| Reclaimable bytes | **Not verified.** `status.physicalSizeBytes` was absent from every object of the validation cluster, which held no volume-backed restore points, so the figure reported 0 |

Section 9 of the runbook records what was checked, and what still is not. Until
8.5.x is covered, treat `--apply` on that version as unvalidated.

## Documentation

- [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — operational guide, rollout procedure,
  lab validation findings, known limitations

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

Veeam, Kasten and K10 are trademarks of Veeam Software. This project is not
affiliated with, endorsed by, or supported by Veeam Software.
