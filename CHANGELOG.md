# Changelog

All notable changes to `pcloud_to_synology_sync_svdt.sh` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to **Semantic Versioning**.

---

## [1.9] — 2026-02-21

### Fixed
- `--log-file-append` flag removed from rclone copy arguments — this flag was introduced in rclone v1.74 and caused an `unknown flag` error on older (but still current) versions. Appending to an existing log file is rclone's default behaviour, making the flag redundant on all versions.
- `resource_snapshot()` function body disabled (no-op `:`). `top -b`, `vmstat 1 2`, and `iostat` all hang indefinitely on Synology DSM due to incompatible busybox flag behaviour. The function remains in the script with commented instructions for re-enabling on platforms where these tools work correctly.

### Changed
- Minimum supported rclone version documented as **v1.56** (2021) — the version that introduced `--missing-on-dst` on `rclone check`, which is the newest flag dependency.
- README updated: requirements table now shows minimum rclone version, flag compatibility table added, and resource snapshot behaviour clarified.

---

## [1.8] — 2026-02-21

### Added
- `--help` flag: prints full usage documentation and exits.
- `--version` flag: prints script name and version number and exits.
- Argument parsing loop: unknown flags exit non-zero with a usage hint.
- Inline documentation for every major script section (config variables, rclone flags, log format, retry logic, diff semantics, health score table, prune logic).

### Changed
- Version history removed from script header — now tracked exclusively in this file.
- Redundant inline comments removed; meaningful explanatory comments retained and expanded.
- Script header reformatted to match project conventions (`SCRIPT_NAME`, `SCRIPT_AUTHOR`, `SCRIPT_YEAR`).
- `README.md` rewritten with full installation instructions, OAuth token setup, DSM scheduling guide, health score table, statistics table explanation, and troubleshooting section.

---

## [1.7] — 2026-02-21

### Fixed
- **Shebang changed from `#!/bin/sh` to `#!/bin/bash`**: `set -o pipefail` is a bashism and is not supported by POSIX `sh` (dash/busybox). The script was silently ignoring pipeline failures on Synology DSM.
- **Stale lock detection**: `find "$LOCKFILE" -mmin +720` always returned exit code 0 (success) regardless of whether it found anything. Fixed to check for a non-empty result using `[ -n "$(find ...)" ]`. The stale threshold is now logged for observability but no longer gates removal — a dead-process PID is always safe to remove.
- **Unquoted `$PROGRESS` and `$STATS` variables**: passing empty string variables unquoted inserts blank positional arguments. Replaced with a bash array (`RCLONE_ARGS`) with conditional `+=` appends.
- **Connectivity probe changed from `rclone ls` to `rclone lsd --max-depth=1`**: `rclone ls` recursively lists all files (expensive on large remotes); `lsd` only lists top-level directories.
- **Index delay anchor**: `INDEX_DELAY` was measured from the end of the connectivity check instead of the end of `rclone copy`. A `COPY_END_TS` variable is now captured immediately after the copy loop exits.
- **`--missing-on-src` removed from `rclone check`**: this flag is contradicted by `--one-way` semantics. Files only on the NAS are intentional under the no-delete policy.

### Changed
- `NOHUP` environment variable renamed to `PCLOUD_NOHUP` to avoid collision with the `nohup` Unix utility. Setting `NOHUP=1` (e.g. via `nohup ./script.sh`) no longer accidentally triggers non-interactive mode.
- Log retention changed from age-based (`find -mtime +30`) to run-count-based (keep newest 30 files per log type). Retention is now consistent with the 30-run statistics history.

---

## [1.6] — 2026-02-21

### Added
- Self-test mode (`SELF_TEST=1`) for safe dry-run validation without data transfer.
- Incident-ready structured logging (`level=... run_id=... script_version=... msg="..."`).
- NAS resource snapshots (CPU, memory, IO) using `top`, `vmstat`, `iostat` when available.
- Atomic lockfile creation using `noclobber` to prevent race conditions.
- Health score clamping (0–100).
- Run ID (`RUN_ID`) for log correlation across meta and rclone log files.

### Changed
- rclone logs now use `--log-file-append` to preserve all retry attempts in a single file.
- Disk space detection uses `NR==2` for locale-safe `df` parsing.
- Variable names, comments, and documentation in English throughout.
- Log retention extended to include diff and missing-on-dst files.
- Statistics table output cleaned up and aligned.

---

## [1.5] — 2026-02-10

### Changed
- Statistics block moved to the bottom of the run output for improved readability.

---

## [1.4] — 2026-02-09

### Added
- 30-run rolling statistics.
- Formatted table view with aligned columns.
- Legend explaining all metrics.

---

## [1.3] — 2026-02-09

### Added
- API-lag detection (distinguishes eventual-consistency delays from copy failures).
- API latency measurement (wall-clock time for connectivity probe).
- Index delay calculation (time between copy end and API exposing new files).
- Health scoring system (0–100 per run).

---

## [1.2] — 2026-02-09

### Fixed
- Improved diff handling: separate artefact files for missing-on-src and missing-on-dst.

---

## [1.1] — 2026-02-08

### Added
- First production-ready version.
- One-way pCloud → NAS backup using `rclone copy`.
- PID-aware lockfile with stale lock repair.
- Pre-flight checks: rclone availability, disk space, connectivity.
- Retry logic with configurable backoff.
- Structured logging and diff artefact generation.

---
