<div align="center">

# ☁️ pcloud_to_synology_sync_svdt.sh

### A production-grade, one-way backup script for pCloud → Synology NAS

[![Platform](https://img.shields.io/badge/platform-Synology%20DSM-lightgrey?logo=synology)](https://www.synology.com/)
[![Shell](https://img.shields.io/badge/shell-bash-blue?logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Requires](https://img.shields.io/badge/requires-rclone-orange)](https://rclone.org/)

Synchronises data from **pCloud** to a **Synology NAS** — one direction, no deletes, production-hardened.

</div>

---

## 📖 Overview

`pcloud_to_synology_sync_svdt.sh` is a fully automated Bash script that performs a **one-way sync** from pCloud to a local Synology NAS using `rclone`. It is designed to run unattended via DSM Task Scheduler and provides structured logging, health scoring, retry logic, API-lag detection, and 30-run rolling statistics.

Files are **never deleted** on the NAS. The NAS is a write-only mirror of pCloud.

---

## ⚡ Quick Start

```bash
# 1. Install rclone on your Synology NAS
# 2. Configure pCloud remote (see OAuth section below)
# 3. Make the script executable
chmod +x pcloud_to_synology_sync_svdt.sh

# 4. Validate your environment first (no data transferred)
SELF_TEST=1 ./pcloud_to_synology_sync_svdt.sh

# 5. Run for real
./pcloud_to_synology_sync_svdt.sh

# 6. Show help
./pcloud_to_synology_sync_svdt.sh --help

# 7. Show version
./pcloud_to_synology_sync_svdt.sh --version
```

---

## ✨ Features

| Feature | Details |
|---|---|
| One-way sync | pCloud → NAS only. Files are never deleted on the NAS. |
| Atomic lockfile | PID-based noclobber lock prevents concurrent runs. Stale locks auto-repaired. |
| Pre-flight checks | Verifies rclone availability, free disk space, and pCloud connectivity before starting. |
| Retry logic | Up to 3 attempts with 5-minute backoff. Disk space re-checked after each failure. |
| API-lag detection | Distinguishes pCloud eventual-consistency delays from real copy failures. |
| Persistent API-lag | Cross-run comparison flags files consistently missing across multiple runs. |
| Health score | Per-run 0–100 score summarising API latency, check results, and diff state. |
| 30-run statistics | Rolling history with a formatted table printed at the end of every run. |
| Structured logging | All log lines use `key=value` format for easy grep and log aggregation. |
| NAS resource snapshots | CPU/memory/IO captured pre- and post-backup using `top`, `vmstat`, `iostat`. |
| Self-test / dry-run | `SELF_TEST=1` runs all checks but passes `--dry-run` to rclone — no data moved. |
| Log retention | Keeps log files for the last N runs (by count, not by age in days). |
| ionice support | Optionally lowers I/O priority so the backup does not impact NAS responsiveness. |

---

## 🔁 What Happens in One Run

```
Start
  │
  ├─ Create dirs (log dir, state dir, local backup dir)
  ├─ Repair or remove stale lockfile
  ├─ Acquire atomic PID lockfile
  ├─ Check rclone in PATH
  ├─ Check NAS free space >= MIN_FREE_MB
  ├─ Capture pre-backup NAS resource snapshot
  ├─ Probe pCloud API + measure latency
  │
  ├─ rclone copy (up to MAX_RETRIES attempts)
  │     └─ Re-check disk space after each failure before retrying
  │
  ├─ rclone check (one-way: pCloud → NAS)
  │     ├─ Write pcloud-diff-TIMESTAMP.txt          (size differences)
  │     └─ Write pcloud-missing-on-dst-TIMESTAMP.txt (files on pCloud not yet on NAS)
  │
  ├─ API-lag detection (current run)
  ├─ Persistent API-lag detection (compare to previous run)
  ├─ Index delay measurement (time between copy end and check)
  ├─ Health score calculation
  ├─ Append stats entry to 30-run history
  ├─ Update last-success timestamp
  ├─ Prune old log files (keep last LOG_RETENTION_RUNS)
  ├─ Capture post-backup NAS resource snapshot
  └─ Print 30-run statistics table
```

---

## ⚙️ Configuration

Edit the `CONFIG` section at the top of the script:

| Variable | Default | Description |
|---|---|---|
| `REMOTE` | `pcloud:` | rclone remote name. Must match your `rclone.conf`. |
| `LOCAL` | `/volume1/pcloud_filebackup` | NAS destination path. |
| `LOG_DIR` | `/volume1/pcloud_filebackup_logs` | Directory for all log and diff files. |
| `STATE_DIR` | `/var/lib/pcloud-backup` | Lockfile, last-success stamp, stats history. |
| `MIN_FREE_MB` | `1000000` (~1 TB) | Minimum NAS free space required to start. |
| `MAX_RETRIES` | `3` | Maximum rclone copy attempts per run. |
| `RETRY_DELAY` | `300` (5 min) | Seconds between retry attempts. |
| `LOG_RETENTION_RUNS` | `30` | Number of recent runs to retain log files for. |

---

## 🔑 Creating a pCloud OAuth Token

> **The OAuth token must be generated on a normal PC or Mac — not on the Synology NAS.**

### Step 1 — Install rclone on your PC

Download from [https://rclone.org/downloads/](https://rclone.org/downloads/) and install for your platform.

### Step 2 — Run the rclone configuration wizard

```bash
rclone config
```

Choose `n` (New remote), set the name to `pcloud`, and select `pCloud` as the storage type.

### Step 3 — Authenticate with pCloud

When prompted `Use auto config?`, choose `y`. Your browser will open and you will log in to your pCloud account to approve access. rclone stores the resulting OAuth token locally.

### Step 4 — Locate your rclone config file

| Platform | Path |
|---|---|
| macOS / Linux | `~/.config/rclone/rclone.conf` |
| Windows | `%USERPROFILE%\.config\rclone\rclone.conf` |

### Step 5 — Copy the config to your Synology NAS

```bash
scp ~/.config/rclone/rclone.conf admin@YOUR_NAS_IP:/var/services/homes/administrator/.rclone.conf
```

### Step 6 — Set correct permissions on the NAS

```bash
chmod 600 /var/services/homes/administrator/.rclone.conf
```

### Step 7 — Test the connection from the NAS

```bash
rclone lsd pcloud: --max-depth=1
```

If you see a directory listing, the token is working correctly.

### ⚠️ Note for root / DSM Task Scheduler users

DSM Task Scheduler runs scripts as `root`. The script uses `$HOME` to locate the rclone config, which resolves to `/root` when running as root — **not** to your regular user's home directory.

Verify where `$HOME` points when running as root:
```bash
sudo bash -c 'echo $HOME'
```

If your rclone config is stored under a regular user (e.g. `administrator`), copy it to root's home:
```bash
cp /var/services/homes/administrator/.rclone.conf /root/.rclone.conf
chmod 600 /root/.rclone.conf
```

Alternatively, hardcode the path explicitly in the `CONFIG` section of the script:
```bash
export RCLONE_CONFIG="/var/services/homes/administrator/.rclone.conf"
```

You can verify the config is found correctly by running the self-test:
```bash
SELF_TEST=1 bash /usr/local/sbin/pcloud_to_synology_sync_svdt.sh
```
A `No connection to pCloud` error at this stage almost always means the config path is wrong or the token has expired.

---

## 🖥️ Scheduling (Synology DSM Task Scheduler)

1. Open DSM → **Control Panel** → **Task Scheduler**.
2. Click **Create** → **Scheduled Task** → **User-defined script**.
3. **General tab**: set User to `root`.
4. **Schedule tab**: set your preferred interval (e.g. daily at 02:00).
5. **Task Settings tab**, Run command:
   ```
   PCLOUD_NOHUP=1 /path/to/pcloud_to_synology_sync_svdt.sh
   ```
6. Optionally enable **Send run details by email** with notification on abnormal termination.

> `PCLOUD_NOHUP=1` is required for scheduled runs — it disables rclone's interactive progress output, which is not useful (and potentially harmful) when running unattended.

---

## 🧪 Self-Test / Dry-Run Mode

```bash
SELF_TEST=1 ./pcloud_to_synology_sync_svdt.sh
```

When `SELF_TEST=1` is set:

- All pre-flight checks run normally (connectivity, disk space, lockfile).
- `rclone copy` runs with `--dry-run` — no files are transferred or modified.
- Diff artefacts and health score are still generated.
- Statistics are recorded in the 30-run history.
- The final log message is labelled `self-test`.

Use this before scheduling a real backup to verify that your rclone config, paths, credentials, and disk space check all pass correctly.

---

## 📊 Health Score

Each run produces a health score from **0 to 100**:

| Condition | Deduction |
|---|---|
| pCloud API response time > 30s | −40 |
| pCloud API response time > 10s | −20 |
| rclone check exit = 1 (API lag) | −10 |
| rclone check exit > 1 (error) | −50 |
| Files missing on NAS | −10 |
| Size differences found | −50 |

Deductions are cumulative. The score is clamped to [0, 100].

A score of **100** means the run completed with no issues. A score below **50** warrants investigation.

---

## 📋 Log Files and Artefacts

All files are written to `LOG_DIR` (default: `/volume1/pcloud_filebackup_logs/`):

| File | Purpose |
|---|---|
| `pcloud-meta-TIMESTAMP.log` | Structured `key=value` run log — all events, health score, stats table. |
| `pcloud-rclone-TIMESTAMP.log` | Raw rclone output from both the copy and check phases. |
| `pcloud-diff-TIMESTAMP.txt` | Files present on both sides but with size differences. |
| `pcloud-missing-on-dst-TIMESTAMP.txt` | Files on pCloud not yet on the NAS (API lag or copy gap). |

State files are written to `STATE_DIR` (default: `/var/lib/pcloud-backup/`):

| File | Purpose |
|---|---|
| `backup.lock` | PID lockfile. Removed on clean exit; auto-repaired on next run. |
| `last_success` | Timestamp of the last successful run. |
| `prev_missing_on_dst.txt` | Used to detect persistent API-lag across consecutive runs. |
| `stats_history.txt` | Rolling 30-run statistics (one structured line per run). |

---

## 📈 30-Run Statistics Table

At the end of every run a formatted table is printed to stdout and appended to the meta log:

```
Date/Time                | API(s)  | IndexDelay(s)  | Missing | Diff | Copy | Check | Health
-------------------------+---------+----------------+---------+------+------+-------+--------
2026-02-21T02:00:01      | 3       | 0              | 0       | 0    | 0    | 0     | 100
2026-02-22T02:00:03      | 12      | 45             | 2       | 0    | 0    | 1     | 70
```

| Column | Meaning |
|---|---|
| Date/Time | Timestamp of the run. |
| API(s) | pCloud API response time in seconds (connectivity probe). |
| IndexDelay(s) | Seconds between copy completion and pCloud API exposing new files. |
| Missing | Files on pCloud not yet visible on the NAS. |
| Diff | Files with size differences between pCloud and NAS. |
| Copy | rclone copy exit code (0 = OK, 1 = non-fatal). |
| Check | rclone check exit code (0 = OK, 1 = API lag, >1 = error). |
| Health | Health score for the run (0–100). |

---

## 🔍 API-Lag Explained

pCloud uses **eventual consistency** for its directory index. After a file is fully downloaded to the NAS, it may still briefly appear as "missing" when queried via the API. This is normal behaviour, not a backup failure.

The script detects API lag by checking for this signature:
- `rclone check` exits with code 1 (non-zero).
- `missing-on-dst` is non-empty.
- `diff` file is empty (no actual size differences — the files exist on the NAS).

When this signature is detected, the run is logged as API-lag and no corrective action is taken. The next run will resolve it automatically.

If the same files appear as missing across **two consecutive runs**, persistent API-lag is logged. This is still handled automatically.

---

## 📋 Requirements

| Tool | Required | Notes |
|---|---|---|
| `rclone` | ✅ Required | **Minimum v1.56** (released 2021). Must be in PATH and configured for pCloud. |
| `bash` | ✅ Required | v4+ (available on DSM via Entware or system bash). |
| `ionice` | Optional | Lowers rclone I/O priority on a busy NAS. |

> **Note on NAS resource snapshots:** `top`, `vmstat`, and `iostat` are intentionally disabled in the script. These tools hang on Synology DSM due to incompatible busybox flag behaviour. The function exists in the code as a no-op with instructions for re-enabling on platforms where they work correctly.

### Minimum rclone version

The script requires **rclone v1.56 or newer**. The table below shows when each flag used by this script was introduced:

| Flag | Introduced | Notes |
|---|---|---|
| `--fast-list` | v1.27 (2016) | ✅ Available on all modern versions |
| `--tpslimit` / `--tpslimit-burst` | v1.37 (2017) | ✅ Available on all modern versions |
| `--stats-one-line` | v1.40 (2018) | ✅ Available on all modern versions |
| `--check-first` | v1.54 (2021) | ✅ Available on v1.56+ |
| `--missing-on-dst` (on `rclone check`) | v1.56 (2021) | ✅ Minimum required version |
| `--log-file-append` | v1.74+ | ❌ Not used — rclone appends by default |

Check your version with:
```bash
rclone version
```

---

## 🚨 Troubleshooting

**Lockfile already active**
The script auto-removes stale locks from dead processes. If you need to force-remove manually:
```bash
rm /var/lib/pcloud-backup/backup.lock
```

**rclone not found in PATH**
Install rclone on Synology via Entware or as a manual binary. Verify with:
```bash
rclone version
```

**Insufficient free space**
Either free space on the NAS volume or lower `MIN_FREE_MB` in the config section of the script.

**No connection to pCloud**
Check your network connection, pCloud API status, rclone remote name, and whether your OAuth token has expired. Test manually:
```bash
rclone lsd pcloud: --max-depth=1
```
If it fails, regenerate the OAuth token (see the OAuth section above).

**API-lag detected**
This is expected behaviour — no action needed. See the API-Lag section above.

**rclone check reports differences**
Inspect the diff artefacts:
```bash
cat /volume1/pcloud_filebackup_logs/pcloud-diff-*.txt
cat /volume1/pcloud_filebackup_logs/pcloud-missing-on-dst-*.txt
```

**Statistics file corrupted**
Delete to reset — the script will recreate it on the next run:
```bash
rm /var/lib/pcloud-backup/stats_history.txt
```

---

## 🚪 Exit Codes

| Code | Meaning |
|---|---|
| `0` | Success (or successful self-test dry-run). |
| `1` | rclone copy returned a non-fatal partial-transfer error. |
| `>1` | Fatal failure — rclone failed all retries, or a pre-flight check failed. |

---

## 🤝 Contributing

Pull requests and improvements are welcome. Please maintain:

- The existing one-way, no-delete safety guarantee.
- Structured `key=value` log format.
- Compatibility with Synology DSM's bundled bash.
- All changes reflected in `CHANGELOG.md`.

---

## 📜 License

This project is licensed under the **MIT License** — you may freely use, modify, distribute, and integrate it into other projects.

---

<div align="center">
<sub>© 2026 SVDT</sub>
</div>
