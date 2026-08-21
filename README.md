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
- **Local snapshots only.** Restore points carrying the
  `k10.kasten.io/exportProfile` label are treated as exports and are never
  touched.
- Does not handle `ClusterRestorePoint` objects, nor orphaned CSI
  `VolumeSnapshot` objects at the storage layer.

## Requirements

| | |
|---|---|
| Veeam Kasten | 8.5.x, 9.0.x |
| Kubernetes | 1.27+ |
| OpenShift | 4.14+ |
| CLI | `oc` (auto-detected) or `kubectl` |
| Tools | `bash` 4+, `jq` 1.6+ |

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

Run `--help` for the full option list.

## Safety model

| Guard | Behaviour |
|---|---|
| Dry-run default | Nothing is deleted without `--apply` |
| `--min-keep N` | Always keeps the N most recent snapshots per application |
| `--max-deletions N` | Aborts with exit code 2 if candidates exceed N, deleting nothing |
| Exemption label | `k10-janitor/exempt=true` on a `RestorePointContent` excludes it permanently |
| Exports excluded | Exported restore points are never candidates in normal operation |
| Unparsable timestamp | Always resolves to `KEEP` |

Every run writes a CSV, a JSONL and a summary per `run_id`, plus a separate
audit trail when `--apply` is used. Each decision carries an explicit reason.

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

Runs entirely offline: fixtures and a stub CLI are generated on the fly, no
cluster is contacted.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or dry-run completed |
| 1 | At least one deletion failed, or runtime error |
| 2 | `--max-deletions` ceiling exceeded, nothing deleted |
| 3 | Missing prerequisite |

## Documentation

- [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — operational guide, rollout procedure,
  known limitations (French)
- [`CLAUDE.md`](CLAUDE.md) — project conventions and invariants for AI-assisted
  development (French)

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

Veeam, Kasten and K10 are trademarks of Veeam Software. This project is not
affiliated with, endorsed by, or supported by Veeam Software.
