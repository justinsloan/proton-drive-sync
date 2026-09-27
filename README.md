# Proton Drive Sync (TUI)

A file synchronization tool for [Proton Drive](https://proton.me/drive) on Linux, built as a Bash script with a terminal user interface (`dialog`, or `whiptail` as a fallback). It keeps one or more local folders in sync with Proton Drive folders (two-way, backup-only or download-only), detecting changes, deletions, moves and conflicts. It can run on a schedule or continuously in the background.

![Bash](https://img.shields.io/badge/language-Bash-4EAA25?logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

> ⚠️ **Disclaimer:** This is an unofficial tool and is not affiliated with or endorsed by Proton AG. Use at your own risk. Always keep backups of important data. Test with non-critical files first.

---

## Features

- 🔄 **True two-way sync** — changes propagate in both directions
- 🧠 **Three-way change detection** — uses a snapshot of the last sync to distinguish local vs. remote changes
- 🗂️ **Recursive directory support** — handles arbitrarily nested folders, creating them on either side as needed
- 🚚 **Move/rename detection** — files moved or renamed on one side are moved on the other instead of being transferred again
- 👀 **Preview** — see exactly which files would be uploaded, downloaded, moved or deleted, then run that sync with one keypress
- ⚔️ **Conflict resolution** — keep local, keep Proton, keep both, or skip, with a line-by-line diff for text files
- 🛑 **Large-deletion safety** — asks before deleting more than 50 files or 25% of your files (both adjustable); automatic syncs stop instead
- 🗑️ **Recoverable deletions** — local deletions go to a trash you can restore from in the menu; remote deletions use Proton's trash
- 📁 **Several folder pairs** — sync any number of local/Proton folder pairs, each with its own history, logs and trash
- ↔️ **Sync modes** — two-way, backup to Proton (upload only), or download from Proton only, per folder pair
- 🙈 **Selective sync** — skip chosen subfolders per folder pair, and optionally files over a size limit
- ⚙️ **Saved settings** — folders, conflict handling, exclusions and more are saved and used by automatic syncs too
- ⏰ **Automatic sync** — hourly, 6-hourly or daily (systemd timer or cron), or continuous: local changes are synced within seconds
- 🔔 **Notifications** — optional desktop notifications when a background sync needs attention
- ⚡ **Parallel transfers** — uploads, downloads and remote folder listings run several at a time (4 by default)
- 🔁 **Automatic retries** — failed transfers retry with exponential backoff
- 🚫 **Exclude patterns** — skip temp files, VCS directories, OS junk, etc.
- 📊 **Progress & history** — progress bar, per-sync summary, and a browsable history of past syncs
- 🔒 **Lock file** — prevents concurrent sync runs from corrupting state, and clears itself if a sync crashed
- 🛡️ **Safety guards** — stops without changing anything if a remote folder can't be listed, or if either side is unexpectedly empty (an unplugged drive, a new computer) while sync history exists

---

## Requirements

| Dependency | Purpose | Install |
|---|---|---|
| `bash` 4.4+ | Associative arrays, process substitution | Usually preinstalled |
| [`proton-drive`](https://proton.me/drive) CLI | Talks to Proton Drive | See Proton's docs |
| `jq` | Parses JSON output | `apt install jq` / `dnf install jq` |
| `dialog` or `whiptail` | Menu interface (not needed for `--headless`) | `apt install dialog` / `dnf install dialog` (`whiptail` is preinstalled on Debian/Ubuntu) |
| systemd or `cron` (optional) | Automatic sync | Usually preinstalled; `apt install cron` |
| `inotify-tools` (optional) | Continuous sync | `apt install inotify-tools` / `dnf install inotify-tools` |
| `notify-send` (optional) | Desktop notifications | `apt install libnotify-bin` / `dnf install libnotify` |
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

Optionally install it for your user, which copies it to `~/.local/bin/proton-drive-sync` and adds a "Proton Drive Sync" launcher to your desktop's app menu:

```bash
./proton-sync-tui.sh --install      # run again after updating the repo
proton-drive-sync --uninstall       # removes the copy and launcher; keeps settings and history
```

If automatic sync is on, `--install` points it at the installed copy.

---

## Quick Start

1. Log in to Proton Drive: `proton-drive auth login`
2. Start the menu: `./proton-sync-tui.sh`
3. Check the folders at the top of the menu. To change them, or add more, open **Folder pairs**.
4. Choose **Preview sync** to see what the first sync will do, then **Run sync now**.
5. Optionally turn on **Automatic sync** (for example, every hour or continuously).

---

## Configuration

Folders are set up under **Folder pairs** in the main menu, and everything else under **Settings**. Changes are saved immediately to `~/.config/proton-sync/config` (or `$XDG_CONFIG_HOME/proton-sync/config`) and are used by both the menu and automatic syncs.

Each **folder pair** has:

| Option | Default |
|---|---|
| Local folder | `~/Proton Drive/root` (for the first pair) |
| Proton folder | `/my-files` (for the first pair) |
| Sync mode | Two-way |
| Skipped folders | none |

**Settings** apply to all pairs:

| Setting | Default |
|---|---|
| Conflicts | Ask me (background syncs skip conflicting files) |
| Parallel transfers | 4 |
| Confirm deletions | more than 50 files or more than 25% of files |
| Skip files larger than | no limit |
| Excluded names | `*.tmp *.swp *.partial .DS_Store Thumbs.db .git .proton-sync` |
| Notifications | off |
| Continuous sync checks Proton every | 15 minutes |
| Keep local trash | 30 days (0 = until you delete it) |
| Keep logs | 90 days (0 = forever) |
| Debug logging | off |

The settings file is plain Bash (`KEY=value` lines), so you can also edit it by hand; `WATCH_DELAY_SECONDS` (default 5) sets how long continuous sync waits after your last change. The defaults live at the top of the script. A settings file from an earlier version (with `LOCAL_DIR` / `REMOTE_DIR`) becomes the first folder pair.

Excluded names are matched against every part of a path, so `.git` skips `.git` folders at any depth. Skipped folders are paths within one pair, such as `Photos/2019`.

---

## Usage

```bash
./proton-sync-tui.sh
```

On launch, the script checks your Proton Drive login. If you're not logged in, it walks you through `proton-drive auth login`.

### Main Menu

The top of the menu shows the folder pair it's working with (the arrow shows the direction: `<->` two-way, `->` backup, `<-` download), when it was last synced and how that went, whether you're logged in, and how conflicts are handled.

| Option | Description |
|---|---|
| **Sync now** | Sync the current folder pair, then show a summary (with any failed files) and offer to open the log |
| **Sync all folder pairs** | Shown when you have more than one pair: sync each in turn and show all results |
| **Preview sync** | List every file that would be uploaded, downloaded, moved or deleted (and what's not synced), without changing anything, then offer to run that sync |
| **Restore deleted files** | Browse files that syncs deleted locally, and restore all or selected files to their original place |
| **Sync history and logs** | Past syncs with their results; view each log in full or just its changes and problems |
| **Folder pairs** | Add, change or remove folder pairs; set each pair's sync mode and skipped folders; start a pair fresh; choose which pair the menu uses |
| **Settings** | Conflict handling, deletion safety limit, size limit, exclusions, notifications, retention, debug logging |
| **Automatic sync** | Every hour, every 6 hours, daily, continuously, or off |
| **Log in / Log out** | Manage your Proton Drive login |

Exit with the **Quit** button (or `Esc`).

### Folder pairs and sync modes

Each local/Proton folder pair keeps its own sync history, logs and trash. When you add a pair, or change a pair's folders to ones you haven't synced together before, the first sync copies files that exist on only one side to the other side and doesn't delete anything. Use **Preview sync** first to check what it will do. The app warns you if a new pair overlaps another one, since the same files would then be synced twice.

| Mode | What it does |
|---|---|
| **Two-way** | Changes, moves and deletions go both ways; conflicts follow your conflict setting |
| **Backup to Proton** | Uploads new and changed local files. Never deletes anything on Proton and never downloads; files that go missing on Proton are uploaded again. If a file changed on both sides, the local version wins |
| **Download from Proton** | Downloads new and changed Proton files. Never uploads and never deletes local files; files that go missing locally are downloaded again. If a file changed on both sides, the Proton version wins and the local copy goes to the local trash |

Files that aren't synced (Proton Docs, which can't be downloaded, and files over the size limit) are listed under **Not synced** in the preview. A file over the size limit is never deleted because of it. The preview also notes new files whose names can't be used on Windows (such as `report?.txt` or `CON.txt`), in case you open the same Proton folder there.

### Large deletions

If a sync would delete more files than your limit (Settings → Confirm deletions), nothing is changed until you confirm. From the menu you see the list of files and choose whether to go ahead. Headless and automatic syncs stop with an error and record it under **Last sync**; run a sync from the menu, or use `--allow-deletes`, to proceed.

### Empty or missing local folder

If a folder pair has been synced before and its local folder is now empty or missing, the app stops before changing anything. This covers an unplugged drive, a folder moved elsewhere, or setting up a new computer. Without this check, a two-way sync would treat the empty folder as "everything was deleted" and delete the files on Proton too. From the menu you can choose:

- **Download everything from Proton (start fresh):** forgets the pair's sync history (kept as a backup) and syncs as if for the first time, so everything is downloaded and nothing is deleted.
- **I deleted them:** also delete the files on Proton (two-way pairs only).
- **Cancel:** for example, to connect the drive first.

Headless and automatic syncs stop with an error instead; run `--headless --start-fresh --pair N` to download everything again. Backup-only pairs never delete on Proton, so they aren't stopped.

You can also clear a pair's history yourself: **Folder pairs** → a pair → **Start fresh**.

### Headless Mode (cron / systemd)

Sync without the menu, then exit. This mode doesn't need `dialog` and never prompts:

```bash
./proton-sync-tui.sh --headless                  # sync all folder pairs
./proton-sync-tui.sh --headless --pair 2         # only folder pair 2
./proton-sync-tui.sh --headless --dry-run        # preview: prints the planned changes
./proton-sync-tui.sh --headless --allow-deletes  # skip the large-deletion stop
./proton-sync-tui.sh --headless --start-fresh --pair 1  # forget pair 1's history, sync as if new
./proton-sync-tui.sh --status                    # folder pairs, last results, automatic sync
```

The script also switches to headless mode automatically when there is no terminal (cron, systemd, pipes). It uses your saved settings, prints a summary for each folder pair, and exits `1` if any pair hit errors, stopped for safety, wasn't logged in, or another sync held the lock. Conflicts are skipped when the conflict setting is "Ask me", because nobody is there to ask. Log in once interactively (`proton-drive auth login`) before scheduling it.

### Automatic sync

Choose **Automatic sync** in the main menu. It syncs all folder pairs in the background, using:

- a **systemd user timer** when your system has one. Timers catch up on a missed run after the computer was asleep or off. See the output with `journalctl --user -u proton-drive-sync`.
- otherwise **cron**, with one line in your crontab (marked `# proton-drive-sync`; your other cron jobs are left alone). Output is appended to `~/.local/share/proton-sync/cron.log`, which is rotated at 1 MB.

The **Continuously** option (systemd and `inotify-tools` needed) runs `--watch` as a user service. Local changes are synced a few seconds after you stop editing, and Proton Drive is checked for changes every 15 minutes (Settings → Continuous sync checks Proton every). Download-only folder pairs are only checked on that schedule. You can also run `./proton-sync-tui.sh --watch` yourself, for example from your desktop's autostart; it restarts itself when you change settings.

Results show up under **Last sync** and in **Sync history**. With **Notifications** turned on in Settings, background syncs also send a desktop notification when something needs attention (errors, a stop, or skipped conflicts), or after every sync that changed files.

To set up cron by hand instead:

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
- **Logged out:** systemd user timers and services run while you're logged in. To keep syncing after you log out, run `loginctl enable-linger`.
- **`XDG_CONFIG_HOME` / `XDG_DATA_HOME`:** if your shell sets these, the menu's Automatic sync option passes them on. When editing the crontab by hand, set them there too.
- **"Not logged in" only in the background:** if a manual run works but background runs report `Cannot access ... are you logged in?`, `proton-drive` probably can't reach its stored login outside your desktop session.
- **Crashes:** if a sync is killed outright (for example, by a power loss), the next run notices that the sync holding the lock is gone and continues.

### Environment Variables

Override saved settings for one run (these work in both interactive and headless mode, and are never written to the settings file):

```bash
# Preview mode (forces every sync, including "Sync now", to make no changes)
PROTON_SYNC_DRY_RUN=true ./proton-sync-tui.sh

# Conflict handling (ask | local | remote | both | skip)
PROTON_SYNC_CONFLICT=local ./proton-sync-tui.sh

# Folders (replaces your folder pairs for this run)
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

This is for two-way folder pairs. Backup-only and download-only pairs never delete, and resolve conflicts in one direction; see [Folder pairs and sync modes](#folder-pairs-and-sync-modes).

---

## State & Data Locations

Settings live in `~/.config/proton-sync/config`; systemd units for automatic sync in `~/.config/systemd/user/proton-drive-sync*`. Everything else lives under `$XDG_DATA_HOME/proton-sync` (default `~/.local/share/proton-sync`), with a separate folder for each local/Proton folder pair:

```
~/.local/share/proton-sync/
├── sync.lock/             # Present only while a sync is running (holds its PID)
├── cron.log               # Output of cron-based automatic syncs (older output in cron.log.1)
├── watch.log              # Errors from the continuous-sync file watcher
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

- **Proton Docs** (`application/vnd.proton.doc`) aren't synced, because they can't be downloaded as regular files. They're listed under **Not synced** in the preview, and a local file with the same name isn't uploaded over them.
- **Change detection uses size + modification time**, not content hashes. This is fast and reliable for typical use, but two different edits producing the same size and mtime won't be distinguished.
- **Move detection matches on fingerprint** (size + mtime). A move is only recognized when its fingerprint is unique; files with identical fingerprints fall back to upload/download plus delete. This is safe, just less efficient.
- **Filenames containing a line break** are skipped and noted in the log. All other characters, including `|` and leading or trailing spaces, are supported.
- **First sync** establishes the baseline snapshot. Files existing on both sides are recorded without transfer; files on only one side are copied to the other; nothing is deleted.
- **Empty folder guards**: if Proton comes back empty (e.g., auth expired mid-run) but a snapshot exists, the sync aborts to avoid wiping local files. If the local folder is empty or missing but a snapshot exists, the sync stops and asks (see [Empty or missing local folder](#empty-or-missing-local-folder)).
- **Continuous sync** reacts to local changes within seconds, but notices changes made on Proton Drive (for example, from another computer) only at its regular check (every 15 minutes by default).
- **Bandwidth limits, file version history and checksum comparison** aren't supported, because they depend on options in the `proton-drive` CLI.
- **Remote listing failures**: each remote folder listing is retried 3 times. If one still fails, the sync stops before making any changes, since that folder's files would otherwise look deleted.

---

## Troubleshooting

**"Another sync is already running"**
Another sync really is running (for example, automatic sync), so wait for it to finish. A lock left by a sync that crashed is removed automatically. `--status` shows whether a sync is running.

**A first sync to an empty folder wants to delete files, or says the folder is empty**
The app has sync history for these folders, for example from an earlier version or an earlier test. Choose **Download everything from Proton (start fresh)**, or use **Folder pairs** → the pair → **Start fresh** before syncing.

**Everything shows as re-downloading, or the history looks wrong**
Check the log in **Sync history**. To start over for a folder pair, use **Folder pairs** → the pair → **Start fresh** (or `--start-fresh --pair N`). The next sync then behaves like a first sync: it copies files that exist on only one side and deletes nothing.

**Files keep re-uploading**
Something is changing the local modification time between runs (e.g., an editor, backup tool, or filesystem quirk). Enable debug logging in Settings to inspect fingerprints.

**Automatic sync stopped with "deletions need confirmation"**
A sync would have deleted more files than your safety limit. Open the menu and choose **Sync now** to review the list and confirm, or raise the limit in Settings → Confirm deletions.

**Continuous sync stops with "the file watcher stopped"**
Very large folders can exceed the system's limit on watched folders; `~/.local/share/proton-sync/watch.log` will say so. Raise the limit, for example with `echo fs.inotify.max_user_watches=524288 | sudo tee /etc/sysctl.d/90-inotify.conf && sudo sysctl --system`, or use a timed schedule instead.

**No notifications from background syncs**
Check that Settings → Notifications is on and that `notify-send` is installed. Notifications appear only while you're logged in to a desktop session.

**Recovering a deleted file**
Use **Restore deleted files** in the main menu. Files deleted on Proton Drive are in Proton's own trash.

---

## Contributing

Issues and pull requests are welcome. Please:

1. Test changes with **Preview sync** / `--dry-run` and non-critical data.
2. Keep the script working with Bash 4.4 and with both `dialog` and `whiptail`.
3. Run `shellcheck proton-sync-tui.sh` before submitting.
4. Describe the scenario your change addresses.

---

## License

[MIT](LICENSE)

---

## Acknowledgements

Built around the `proton-drive` CLI. Not affiliated with Proton AG.
