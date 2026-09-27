# Proton Drive Sync (TUI)

A two-way file synchronization tool for [Proton Drive](https://proton.me/drive), built as a Bash script with a terminal user interface (`dialog`, or `whiptail` as a fallback). It syncs a local folder with a Proton Drive folder, detecting changes, deletions, moves, and conflicts, and can run unattended from cron.

![Bash](https://img.shields.io/badge/language-Bash-4EAA25?logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

> ⚠️ **Disclaimer:** This is an unofficial tool and is not affiliated with or endorsed by Proton AG. Use at your own risk. Always keep backups of important data. Test with non-critical files first.

---

## Features

- 🔄 **True two-way sync** — changes propagate in both directions
- 🧠 **Three-way change detection** — uses a snapshot of the last sync to distinguish local vs. remote changes
- 🗂️ **Recursive directory support** — handles arbitrarily nested folders, creating them on either side as needed
- 🚚 **Move/rename detection** — reorganized files are moved/renamed remotely instead of re-uploaded
- 👀 **Preview** — see exactly which files would be uploaded, downloaded, moved or deleted, then run that sync with one keypress
- ⚔️ **Conflict resolution** — keep local, keep Proton, keep both, or skip, with a line-by-line diff for text files
- 🛑 **Large-deletion safety** — asks before deleting more than 50 files or 25% of your files (both adjustable); automatic syncs stop instead
- 🗑️ **Recoverable deletions** — local deletions go to a trash you can restore from in the menu; remote deletions use Proton's trash
- ⚙️ **Saved settings** — folders, conflict handling, exclusions and more are saved and used by automatic syncs too
- 📁 **Separate history per folder pair** — switching folders never mixes up sync histories
- ⏰ **Automatic sync** — set up an hourly, 6-hourly or daily cron job from the menu
- ⚡ **Parallel transfers** — uploads, downloads and remote folder listings run several at a time (4 by default)
- 🔁 **Automatic retries** — failed transfers retry with exponential backoff
- 🚫 **Exclude patterns** — skip temp files, VCS directories, OS junk, etc.
- 📊 **Progress & history** — progress bar, per-sync summary, and a browsable history of past syncs
- 🔒 **Lock file** — prevents concurrent sync runs from corrupting state
- 🛡️ **Safety guards** — stops without changing anything if a remote folder can't be listed, or if the remote listing is empty while sync history exists

---

## Requirements

| Dependency | Purpose | Install |
|---|---|---|
| `bash` 4.4+ | Associative arrays, process substitution | Usually preinstalled |
| [`proton-drive`](https://proton.me/drive) CLI | Talks to Proton Drive | See Proton's docs |
| `jq` | Parses JSON output | `apt install jq` / `dnf install jq` |
| `dialog` or `whiptail` | Menu interface (not needed for `--headless`) | `apt install dialog` / `dnf install dialog` (`whiptail` is preinstalled on Debian/Ubuntu) |
| `cron` (optional) | Automatic sync | `apt install cron` |
| Core utils | `find`, `stat`, `date`, `sha256sum`, `diff`, etc. | Preinstalled |

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

Open **Settings** from the main menu. Changes are saved immediately to `~/.config/proton-sync/config` (or `$XDG_CONFIG_HOME/proton-sync/config`) and are used by both the menu and automatic syncs:

| Setting | Default |
|---|---|
| Local folder | `~/Proton Drive/root` |
| Proton folder | `/my-files` |
| Conflicts | Ask me (automatic syncs skip conflicting files) |
| Parallel transfers | 4 |
| Confirm deletions | more than 50 files or more than 25% of files |
| Excluded names | `*.tmp *.swp *.partial .DS_Store Thumbs.db .git .proton-sync` |
| Keep local trash | 30 days (0 = until you delete it) |
| Keep logs | 90 days (0 = forever) |
| Debug logging | off |

The settings file is plain Bash (`KEY=value` lines), so you can also edit it by hand. The defaults live at the top of the script.

Exclude patterns are matched against every part of a path, so `.git` skips `.git` folders at any depth.

---

## Usage

```bash
./proton-sync-tui.sh
```

On launch, the script checks your Proton Drive login. If you're not logged in, it walks you through `proton-drive auth login`.

### Main Menu

The top of the menu shows your folders, when the last sync ran and how it went, whether you're logged in, and how conflicts are handled.

| Option | Description |
|---|---|
| **Sync now** | Perform a full two-way sync, then show a summary (with any failed files) and offer to open the log |
| **Preview sync** | List every file that would be uploaded, downloaded, moved or deleted, without changing anything, then offer to run that sync |
| **Restore deleted files** | Browse files that syncs deleted locally, and restore all or selected files to their original place |
| **Sync history and logs** | Past syncs with their results; view each log in full or just its changes and problems |
| **Settings** | Folders, conflict handling, deletion safety limit, exclusions, retention, debug logging |
| **Automatic sync** | Turn a cron job on (hourly, every 6 hours, daily) or off |
| **Log in / Log out** | Manage your Proton Drive login |

Exit with the **Quit** button (or `Esc`).

### Changing folders

Each local/Proton folder pair keeps its own sync history, logs and trash. When you switch to a pair you haven't synced before, the first sync copies files that exist on only one side to the other side and doesn't delete anything. Use **Preview sync** first to check what it will do. Switching back to an earlier pair picks up its history where you left off.

### Large deletions

If a sync would delete more files than your limit (Settings → Confirm deletions), nothing is changed until you confirm. From the menu you see the list of files and choose whether to go ahead. Headless and automatic syncs stop with an error and record it under **Last sync**; run a sync from the menu, or use `--allow-deletes`, to proceed.

### Headless Mode (cron / systemd)

Run a single sync without the menu, then exit. This mode doesn't need `dialog` and never prompts:

```bash
./proton-sync-tui.sh --headless                  # real sync
./proton-sync-tui.sh --headless --dry-run        # preview: prints the planned changes
./proton-sync-tui.sh --headless --allow-deletes  # skip the large-deletion stop
```

The script also switches to headless mode automatically when there is no terminal (cron, systemd, pipes). It uses your saved settings, prints a summary, and exits `1` if the sync hit errors, stopped for safety, wasn't logged in, or another sync held the lock. Conflicts are skipped when the conflict setting is "Ask me", because nobody is there to ask. Log in once interactively (`proton-drive auth login`) before scheduling it.

### Automatic sync

The easiest way is **Automatic sync** in the main menu. It adds one line to your crontab (marked `# proton-drive-sync`) that runs `--headless` with the right `PATH`, and it leaves your other cron jobs alone. Results show up under **Last sync** and in **Sync history**, and each run's output is appended to `~/.local/share/proton-sync/cron.log`.

To set it up by hand instead:

1. Log in once and run a first sync to check that everything works:

   ```bash
   proton-drive auth login
   ./proton-sync-tui.sh --headless
   ```

2. Find where `proton-drive` is installed. cron only searches `/usr/bin:/bin`, so you'll add this folder to its `PATH`:

   ```bash
   which proton-drive
   ```

3. Open your crontab with `crontab -e` and add an entry. This one syncs every hour at 17 minutes past:

   ```cron
   PATH=/usr/local/bin:/usr/bin:/bin:/home/YOU/.local/bin

   17 * * * * /bin/bash /home/YOU/proton-drive-sync/proton-sync-tui.sh --headless >> /home/YOU/.local/share/proton-sync/cron.log 2>&1
   ```

   Replace `YOU` with your username, and put the folder from step 2 in `PATH`. Use full paths throughout, since cron doesn't expand `~`.

Notes:

- **Conflicts:** with the default "Ask me" setting, automatic syncs skip files that changed on both sides until you sync from the menu. To resolve them automatically, pick another option in Settings → Conflicts. "Keep both" is the safest: the local version wins under the original name on both sides, and the Proton version is kept beside it as a `.remote` copy.
- **`XDG_CONFIG_HOME` / `XDG_DATA_HOME`:** if your shell sets these, the menu's Automatic sync option passes them to cron. When editing the crontab by hand, set them there too.
- **"Not logged in" only under cron:** if a manual run works but cron reports `Cannot access ... are you logged in?`, `proton-drive` probably can't reach its stored login outside your desktop session.
- **Stale lock:** if a sync is killed outright (for example, by a power loss), the lock stays behind and every later run exits with "Another sync is already running". Delete `~/.local/share/proton-sync/sync.lock` to clear it.

### Environment Variables

Override saved settings for one run (these work in both interactive and headless mode, and are never written to the settings file):

```bash
# Preview mode (forces every sync, including "Sync now", to make no changes)
PROTON_SYNC_DRY_RUN=true ./proton-sync-tui.sh

# Conflict handling (ask | local | remote | both | skip)
PROTON_SYNC_CONFLICT=local ./proton-sync-tui.sh

# Folders
PROTON_SYNC_LOCAL_DIR=~/Work PROTON_SYNC_REMOTE_DIR=/work ./proton-sync-tui.sh

# Number of transfers / folder listings to run at once
# Lower it if you hit Proton rate limits; raise it on a fast connection.
PROTON_SYNC_JOBS=8 ./proton-sync-tui.sh

# Verbose logging
PROTON_SYNC_DEBUG=true ./proton-sync-tui.sh

# Don't stop for large deletions (same as --allow-deletes)
PROTON_SYNC_ALLOW_DELETES=true ./proton-sync-tui.sh --headless

# Use a different settings file, or force dialog/whiptail
PROTON_SYNC_CONFIG=~/.config/proton-sync/work.conf ./proton-sync-tui.sh
PROTON_SYNC_UI=whiptail ./proton-sync-tui.sh
```

---

## How It Works

The script maintains a **snapshot** of the last known state of every file (size + modification time, for both local and remote copies). On each run it:

1. **Builds manifests** of the current local and remote file trees.
2. **Compares** each file's current fingerprint against the snapshot to determine what changed and where.
3. **Detects moves** by matching fingerprints of deleted and newly-appeared files.
4. **Checks deletions** against your safety limit before changing anything.
5. **Applies changes** — moves, then uploads, downloads and deletions (several at a time).
6. **Resolves conflicts** interactively (or via your conflict setting).
7. **Updates the snapshot** for the next run.

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

Settings live in `~/.config/proton-sync/config`. Everything else lives under `$XDG_DATA_HOME/proton-sync` (default `~/.local/share/proton-sync`), with a separate folder for each local/Proton folder pair:

```
~/.local/share/proton-sync/
├── sync.lock              # Present only while a sync is running
├── cron.log               # Output of automatic syncs
└── pairs/<id>/            # One per folder pair
    ├── folders            # Which local and Proton folders this is
    ├── snapshot           # Last-sync state (source of truth)
    ├── last_status        # Result shown as "Last sync" in the menu
    ├── logs/              # One log per sync
    └── trash/             # Recoverable local deletions (by sync time)
```

Settings → **Where settings, logs and trash are stored** shows the exact paths for your current folders. When upgrading from an older version, the existing snapshot, logs and trash are moved into the folder for your configured folders on the first run.

---

## Conflict Resolution

When a file changes on **both** sides since the last sync, you'll be asked:

| Choice | Result |
|---|---|
| **Show differences** | For text files, show a line-by-line diff of the local and Proton versions |
| **Keep LOCAL** | Upload local version, overwrite remote |
| **Keep PROTON** | Download remote version, overwrite local |
| **Keep BOTH** | Save the remote version locally as `filename.remote.ext` (or `.remote-2`, … if that exists), then upload the local version. The `.remote` copy is uploaded on the next sync |
| **Skip** | Leave unresolved; asked again next sync |
| **Keep LOCAL/PROTON for ALL** | Apply that choice to every remaining conflict |

Choose a default in Settings → Conflicts, or with `PROTON_SYNC_CONFLICT`.

---

## Limitations & Notes

- **Proton Docs** (`application/vnd.proton.doc`) are skipped — they're a proprietary format that can't be downloaded as regular files.
- **Change detection uses size + modification time**, not content hashes. This is fast and reliable for typical use, but two different edits producing the same size and mtime won't be distinguished.
- **Move detection matches on fingerprint** (size + mtime). A move is only recognized when its fingerprint is unique; files with identical fingerprints fall back to upload/download plus delete. This is safe, just less efficient.
- **Filenames containing a line break** are skipped and noted in the log. All other characters, including `|` and leading or trailing spaces, are supported.
- **First sync** establishes the baseline snapshot. Files existing on both sides are recorded without transfer; files on only one side are copied to the other; nothing is deleted.
- **Empty remote listing guard**: if the remote comes back empty (e.g., auth expired mid-run) but a snapshot exists, the sync aborts to avoid wiping local files.
- **Remote listing failures**: each remote folder listing is retried 3 times. If one still fails, the sync stops before making any changes, since that folder's files would otherwise look deleted.

---

## Troubleshooting

**"Another sync is already running"**
A previous run may have crashed. Remove the stale lock:
```bash
rmdir ~/.local/share/proton-sync/sync.lock
```

**Everything shows as re-downloading**
Your snapshot may be out of date or missing. Check the log in **Sync history**, or reset the baseline for the current folders (⚠️ treats current state as truth). Settings → *Where settings, logs and trash are stored* shows the folder that holds the `snapshot` file.

**Files keep re-uploading**
Something is changing the local modification time between runs (e.g., an editor, backup tool, or filesystem quirk). Enable debug logging in Settings to inspect fingerprints.

**Automatic sync stopped with "deletions need confirmation"**
A sync would have deleted more files than your safety limit. Open the menu and choose **Sync now** to review the list and confirm, or raise the limit in Settings → Confirm deletions.

**Recovering a deleted file**
Use **Restore deleted files** in the main menu. Files deleted on Proton Drive are in Proton's own trash.

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
