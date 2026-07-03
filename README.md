# proton-drive-sync
A simple BASH script for syncing Proton Drive to Linux

----

It works, but this is highly experimental and totally vibe-coded.

## Usage
```
# Normal sync
./proton-sync.sh

# Preview what would happen (highly recommended after this update)
PROTON_SYNC_DRY_RUN=true ./proton-sync.sh

# Verbose troubleshooting
PROTON_SYNC_DEBUG=true ./proton-sync.sh

# Recover an accidentally deleted file
ls ~/.local/share/proton-sync/trash/
```
