# Proton Drive Sync (TUI)

A two-way file synchronization tool for [Proton Drive](https://proton.me/drive), built as a Bash script with a `dialog`-based terminal user interface (TUI). It syncs a local directory with a remote Proton Drive folder, detecting changes, deletions, moves, and conflicts.

![Bash](https://img.shields.io/badge/language-Bash-4EAA25?logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

> ⚠️ **Disclaimer:** This is an unofficial tool and is not affiliated with or endorsed by Proton AG. Use at your own risk. Always keep backups of important data. Test with non-critical files first.

---

## Features

- 🔄 **True two-way sync** — changes propagate in both directions
- 🧠 **Three-way change detection** — uses a snapshot of the last sync to distinguish local vs. remote changes
- 🗂️ **Recursive directory support** — handles arbitrarily nested folders, creating them on either side as needed
- 🚚 **Move/rename detection** — reorganized files are moved/renamed remotely instead of re-uploaded
- ⚔️ **Interactive conflict resolution** — choose keep-local, keep-remote, keep-both, or skip when a file changes on both sides
- 🗑️ **Recoverable deletions** — local deletions go to a timestamped trash folder (auto-purged after 30 days); remote deletions use Proton's trash
- 🔒 **Lock file** — prevents concurrent sync runs from corrupting state
- 🔁 **Automatic retries** — failed transfers retry with exponential backoff
- 🚫 **Exclude patterns** — skip temp files, VCS directories, OS junk, etc.
- 🧪 **Dry-run mode** — preview all actions without making changes
- 📊 **Progress gauge & summary** — live progress bar and a per-run summary report
- 📝 **Logging** — detailed, timestamped logs for every run
- 🔑 **Auth handling** — verifies authentication at startup and guides you through login
- 🛡️ **Safety guards** — refuses to run if the remote listing is empty while sync history exists (prevents mass deletion)

---

## Requirements

| Dependency | Purpose | Install |
|---|---|---|
| `bash` 4+ | Associative arrays | Usually preinstalled |
| [`proton-drive`](https://proton.me/drive) CLI | Talks to Proton Drive | See Proton's docs |
| `jq` | Parses JSON output | `apt install jq` / `dnf install jq` |
| `dialog` | Terminal UI | `apt install dialog` / `dnf install dialog` |
| Core utils | `stat`, `find`, `date`, `sed`, etc. | Preinstalled |

---

## Installation

```bash
# Clone the repo
git clone https://github.com/yourusername/proton-drive-sync.git
cd proton-drive-sync

# Make the script executable
chmod +x proton-sync-tui.sh
```

Install missing dependencies (Debian/Ubuntu example):

```bash
sudo apt install dialog jq
```

---

## Configuration

Edit the variables at the top of the script:

```bash
LOCAL_DIR="$HOME/Proton Drive/root"   # Local directory to sync
REMOTE_DIR="/my-files"                # Remote Proton Drive path
TRASH_RETENTION_DAYS=30               # Days to keep local trash
```

Exclude patterns (matched against every path component):

```bash
EXCLUDE_PATTERNS=(
    "*.tmp"
    "*.swp"
    "*.partial"
    ".DS_Store"
    "Thumbs.db"
    ".git"
    ".proton-sync"
)
```

---

## Usage

```bash
./proton-sync-tui.sh
```

On launch, the script verifies your Proton Drive authentication. If you're not logged in, it walks you through `proton-drive auth login` automatically.

### Main Menu

| Option | Description |
|---|---|
| **Run sync now** | Perform a full two-way sync |
| **Preview sync (dry run)** | Show what would happen — no changes made |
| **Set conflict strategy** | Choose how conflicts are handled (ask/local/remote/both/skip) |
| **View latest sync log** | Read the most recent log |
| **Browse all sync logs** | Pick from historical logs |
| **Recover deleted files** | Inspect the local trash |
| **Change directories** | Set local/remote paths for the session |
| **View current settings** | Show config and auth status |
| **Toggle debug logging** | Enable verbose logging |
| **Proton Drive login/logout** | Manage authentication |

Exit via the **Quit** button (or `Esc`).

### Environment Variables

Run headless or override defaults:

```bash
# Preview mode
PROTON_SYNC_DRY_RUN=true ./proton-sync-tui.sh

# Non-interactive conflict handling (local | remote | both | skip)
PROTON_SYNC_CONFLICT=local ./proton-sync-tui.sh

# Verbose logging
PROTON_SYNC_DEBUG=true ./proton-sync-tui.sh
```

---

## How It Works

The script maintains a **snapshot** of the last known state of every file (size + modification time, for both local and remote copies). On each run it:

1. **Builds manifests** of the current local and remote file trees.
2. **Compares** each file's current fingerprint against the snapshot to determine what changed and where.
3. **Detects moves** by matching fingerprints of deleted and newly-appeared files.
4. **Applies changes** — uploads, downloads, moves, and deletions.
5. **Resolves conflicts** interactively (or via a preset strategy).
6. **Updates the snapshot** for the next run.

### Change Detection Matrix

| Previous | Local Now | Remote Now | Action |
|---|---|---|---|
| A | A | A | ✅ No change |
| A | **B** | A | ⬆️ Upload (local changed) |
| A | A | **B** | ⬇️ Download (remote changed) |
| A | **B** | **C** | ⚔️ Conflict (resolve) |
| — | **B** | — | ⬆️ Upload (new local) |
| — | — | **B** | ⬇️ Download (new remote) |
| A | — | A | 🗑️ Trash remote (deleted locally) |
| A | A | — | 🗑️ Delete local (deleted remotely) |

---

## State & Data Locations

Everything lives under `$XDG_DATA_HOME/proton-sync` (default `~/.local/share/proton-sync`):

```
~/.local/share/proton-sync/
├── snapshot          # Last-sync state (source of truth)
├── logs/             # Timestamped run logs
├── trash/            # Recoverable local deletions (by timestamp)
└── sync.lock         # Present only while a sync is running
```

---

## Conflict Resolution

When a file changes on **both** sides since the last sync, you'll be prompted:

| Choice | Result |
|---|---|
| **Keep LOCAL** | Upload local version, overwrite remote |
| **Keep REMOTE** | Download remote version, overwrite local |
| **Keep BOTH** | Download remote as `filename.remote.ext`, keep local |
| **Skip** | Leave unresolved; re-prompted next sync |
| **Keep LOCAL/REMOTE for ALL** | Apply that choice to every remaining conflict |

Set a non-interactive default via the menu or `PROTON_SYNC_CONFLICT`.

---

## Limitations & Notes

- **Proton Docs** (`application/vnd.proton.doc`) are skipped — they're a proprietary format that can't be downloaded as regular files.
- **Change detection uses size + modification time**, not content hashes. This is fast and reliable for typical use, but two different edits producing the same size and mtime won't be distinguished.
- **Move detection matches on fingerprint** (size + mtime). Files with identical fingerprints may occasionally fall back to upload/download rather than a move — this is safe, just less efficient.
- **First sync** establishes the baseline snapshot. Files existing on both sides are recorded without transfer; genuine differences are treated conservatively.
- **Interactive conflicts require a terminal** — the gauge and conflict dialogs can't run fully unattended unless you set a `PROTON_SYNC_CONFLICT` strategy.
- **Empty remote listing guard**: if the remote comes back empty (e.g., auth expired mid-run) but a snapshot exists, the sync aborts to avoid wiping local files.

---

## Troubleshooting

**"Another sync is already running"**
A previous run may have crashed. Remove the stale lock:
```bash
rmdir ~/.local/share/proton-sync/sync.lock
```

**Everything shows as re-downloading**
Your snapshot may be out of date or missing. Check the log, or reset the baseline (⚠️ treats current state as truth):
```bash
rm ~/.local/share/proton-sync/snapshot
```

**Files keep re-uploading**
Something is changing the local modification time between runs (e.g., an editor, backup tool, or filesystem quirk). Enable debug logging to inspect fingerprints.

**Recovering a deleted file**
Look in the trash directory:
```bash
ls ~/.local/share/proton-sync/trash/
```

---

## Contributing

Issues and pull requests are welcome. Please:

1. Test changes with **dry-run mode** and non-critical data.
2. Keep the script POSIX-friendly where practical (Bash 4+ is assumed).
3. Describe the scenario your change addresses.

---

## License

[MIT](LICENSE)

---

## Acknowledgements

Built around the `proton-drive` CLI. Not affiliated with Proton AG.
