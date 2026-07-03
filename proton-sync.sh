#!/bin/bash
set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

LOCAL_DIR="$HOME/Proton Drive/root"
REMOTE_DIR="/my-files"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/proton-sync"
SNAPSHOT="$STATE_DIR/snapshot"

KNOWN_REMOTE_DIRS="$STATE_DIR/known_remote_dirs"
LOCAL_MANIFEST="$STATE_DIR/local_manifest"
REMOTE_MANIFEST="$STATE_DIR/remote_manifest"
NEW_SNAPSHOT="$STATE_DIR/snapshot.new"
LOCK_FILE="$STATE_DIR/sync.lock"
LOCAL_TRASH="$STATE_DIR/trash/$(date +%Y%m%d-%H%M%S)"
TRASH_RETENTION_DAYS=30

# Files/folders that never sync (shell glob patterns, matched
# against every path component)
EXCLUDE_PATTERNS=(
    "*.tmp"
    "*.swp"
    "*.partial"
    ".DS_Store"
    "Thumbs.db"
    ".git"
    ".proton-sync"
)

mkdir -p "$STATE_DIR"
touch "$SNAPSHOT"

# ============================================================
# MODES
# ============================================================

DEBUG="${PROTON_SYNC_DEBUG:-false}"
DRY_RUN="${PROTON_SYNC_DRY_RUN:-false}"

# ============================================================
# IN-MEMORY STATE
# ============================================================

declare -A SNAPSHOT_LOCAL_FP    # rel -> "size|mtime" at last sync (local)
declare -A SNAPSHOT_REMOTE_FP   # rel -> "size|mtime" at last sync (remote)
declare -A SNAPSHOT_SEEN        # rel -> 1 if in snapshot
declare -A LOCAL_ITEMS          # "type|rel" -> 1
declare -A REMOTE_ITEMS         # "type|rel" -> "size|mtime" (files) or "" (folders)
declare -A KNOWN_DIRS           # rel -> 1 for known remote dirs ("/" = root)

# Deferred action queues (for move detection)
declare -a NEW_LOCAL_FILES=()         # local-only, never synced -> upload?
declare -a NEW_REMOTE_FILES=()        # remote-only, never synced -> download?
declare -a DELETED_REMOTELY_FILES=()  # local-only, was synced -> delete local?
declare -a TRASH_REMOTE_FILES=()      # remote-only, was synced -> trash remote?
declare -a DEL_LOCAL_FOLDERS=()       # local folder, deleted remotely
declare -a TRASH_REMOTE_FOLDERS=()    # remote folder, deleted locally

declare -A NEW_LOCAL_FP=()            # rel -> current local fp
declare -A NEW_REMOTE_FP=()           # rel -> current remote fp

# Counters
COUNT_OK=0
COUNT_UPLOADED=0
COUNT_DOWNLOADED=0
COUNT_MOVED_REMOTE=0
COUNT_MOVED_LOCAL=0
COUNT_DELETED_LOCAL=0
COUNT_TRASHED_REMOTE=0
COUNT_CONFLICTS=0
COUNT_ERRORS=0
COUNT_FIRST_SYNC=0

# ============================================================
# LOCKING
# ============================================================

acquire_lock() {
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        echo "ERROR: Another sync is already running (lock: $LOCK_FILE)"
        echo "If you are sure no sync is running, remove it manually:"
        echo "  rmdir '$LOCK_FILE'"
        exit 1
    fi
    trap 'rm -rf "$LOCK_FILE"' EXIT
}

# ============================================================
# DEBUG / EXECUTION HELPERS
# ============================================================

debug() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] $*"
    fi
}

debug_file() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] === $1 ==="
        cat "$2"
        echo ""
    fi
}

# Run a command, or just print it in dry-run mode
run() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] $*"
        return 0
    fi
    "$@"
}

# Retry a command with exponential backoff
retry() {
    local attempts=3
    local delay=5
    local i
    for ((i = 1; i <= attempts; i++)); do
        if "$@"; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            echo "[RETRY $i/$attempts] Failed, waiting ${delay}s: $*"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    echo "[ERROR] Giving up after $attempts attempts: $*"
    return 1
}

# Run with retry, or print in dry-run mode
run_retry() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] $*"
        return 0
    fi
    retry "$@"
}

# ============================================================
# EXCLUDE PATTERNS
# ============================================================

is_excluded() {
    local rel="$1"
    local part pattern
    local -a parts
    IFS='/' read -ra parts <<< "$rel"
    for part in "${parts[@]}"; do
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            case "$part" in
                $pattern) return 0 ;;
            esac
        done
    done
    return 1
}

# ============================================================
# LOCAL TRASH (recoverable deletions)
# ============================================================

trash_local() {
    local local_path="$1"
    local rel="$2"

    if [ ! -e "$local_path" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] trash_local $local_path"
        return 0
    fi

    mkdir -p "$LOCAL_TRASH/$(dirname "$rel")"
    mv "$local_path" "$LOCAL_TRASH/$rel"
    echo "  (recoverable in $LOCAL_TRASH/$rel)"
}

cleanup_old_trash() {
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi
    if [ -d "$STATE_DIR/trash" ]; then
        find "$STATE_DIR/trash" -mindepth 1 -maxdepth 1 -type d \
            -mtime +"$TRASH_RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true
    fi
}

# ============================================================
# FINGERPRINT FUNCTIONS
# ============================================================

get_local_fingerprint() {
    stat -c '%s|%Y' "$1"
}

# ============================================================
# REMOTE LISTING (RECURSIVE)
# ============================================================

list_remote_recursive() {
    local remote_path="$1"
    local prefix="$2"

    proton-drive filesystem list "$remote_path" -j | \
        jq -r '
            .[] |
            (if .type | type == "object" then .type.value else .type end) as $type |
            (if .name | type == "object" then .name.value else .name end) as $name |
            (if .mediaType | type == "object" then .mediaType.value else (.mediaType // "") end) as $media |
            (.activeRevision.value.claimedSize // 0) as $size |
            (.activeRevision.value.claimedModificationTime // "") as $mtime |
            "\($type)|\($name)|\($media)|\($size)|\($mtime)"
        ' | \
        while IFS='|' read -r type name media size mtime; do
            local rel_path
            if [ -z "$prefix" ]; then
                rel_path="$name"
            else
                rel_path="$prefix/$name"
            fi

            if is_excluded "$rel_path"; then
                debug "Excluded remote: $rel_path"
                continue
            fi

            if [ "$type" = "folder" ]; then
                echo "folder|$rel_path||"
                list_remote_recursive "$remote_path/$name" "$rel_path"
            else
                if [ "$media" = "application/vnd.proton.doc" ]; then
                    echo "[SKIP PROTON DOC] $rel_path" >&2
                    continue
                fi
                local mtime_epoch=0
                if [ -n "$mtime" ]; then
                    mtime_epoch=$(date -d "$mtime" +%s 2>/dev/null || echo 0)
                fi
                echo "file|$rel_path|$size|$mtime_epoch"
            fi
        done
}

# Fetch remote fingerprint for one path (used after uploads)
fetch_remote_fingerprint() {
    local remote_path="$1"
    local info rsize rmtime rmtime_epoch
    info=$(proton-drive filesystem info "$remote_path" -j 2>/dev/null) || true
    if [ -z "$info" ]; then
        echo ""
        return
    fi
    rsize=$(echo "$info" | jq -r '.activeRevision.value.claimedSize // 0')
    rmtime=$(echo "$info" | jq -r '.activeRevision.value.claimedModificationTime // ""')
    rmtime_epoch=0
    [ -n "$rmtime" ] && rmtime_epoch=$(date -d "$rmtime" +%s 2>/dev/null || echo 0)
    echo "${rsize}|${rmtime_epoch}"
}

# ============================================================
# DIRECTORY MANAGEMENT
# ============================================================

build_remote_dir_cache() {
    KNOWN_DIRS=()
    KNOWN_DIRS["/"]=1
    while IFS='|' read -r type rel _rest; do
        if [ "$type" = "folder" ]; then
            KNOWN_DIRS["$rel"]=1
        fi
    done < "$REMOTE_MANIFEST"
}

remote_dir_exists() {
    local dir="$1"
    if [ -z "$dir" ]; then
        dir="/"
    fi
    [ -n "${KNOWN_DIRS[$dir]:-}" ]
}

create_remote_folder() {
    local parent_rel="$1"
    local folder_name="$2"

    local full_parent
    if [ -z "$parent_rel" ]; then
        full_parent="$REMOTE_DIR"
    else
        full_parent="$REMOTE_DIR/$parent_rel"
    fi

    echo "[CREATE REMOTE FOLDER] $full_parent/$folder_name"
    run_retry proton-drive filesystem create-folder "$full_parent" "$folder_name"

    if [ -z "$parent_rel" ]; then
        KNOWN_DIRS["$folder_name"]=1
    else
        KNOWN_DIRS["$parent_rel/$folder_name"]=1
    fi
}

ensure_remote_folders() {
    local rel_dir="$1"

    if [ -z "$rel_dir" ] || [ "$rel_dir" = "." ]; then
        return
    fi

    if remote_dir_exists "$rel_dir"; then
        return
    fi

    local current=""
    IFS='/' read -ra parts <<< "$rel_dir"
    for part in "${parts[@]}"; do
        local next
        if [ -z "$current" ]; then
            next="$part"
        else
            next="$current/$part"
        fi

        if ! remote_dir_exists "$next"; then
            create_remote_folder "$current" "$part"
        fi

        current="$next"
    done
}

ensure_local_folders() {
    local local_path="$1"
    if [ ! -d "$local_path" ]; then
        echo "[CREATE LOCAL FOLDER] $local_path"
        run mkdir -p "$local_path"
    fi
}

# ============================================================
# IN-MEMORY LOADERS
# ============================================================

load_snapshot() {
    [ -f "$SNAPSHOT" ] || return 0
    while IFS='|' read -r type rel f3 f4 f5 f6; do
        [ -z "$type" ] && continue
        SNAPSHOT_SEEN["$rel"]=1
        if [ "$type" = "file" ]; then
            SNAPSHOT_LOCAL_FP["$rel"]="${f3}|${f4}"
            SNAPSHOT_REMOTE_FP["$rel"]="${f5}|${f6}"
        fi
    done < "$SNAPSHOT"
}

load_manifests_to_memory() {
    while IFS='|' read -r type rel _size _mtime; do
        LOCAL_ITEMS["${type}|${rel}"]=1
    done < "$LOCAL_MANIFEST"

    while IFS='|' read -r type rel size mtime; do
        if [ "$type" = "file" ]; then
            REMOTE_ITEMS["${type}|${rel}"]="${size}|${mtime}"
        else
            REMOTE_ITEMS["${type}|${rel}"]=""
        fi
    done < "$REMOTE_MANIFEST"
}

was_previously_synced() {
    [ -n "${SNAPSHOT_SEEN[$1]:-}" ]
}

# ============================================================
# SAFETY CHECKS
# ============================================================

check_auth() {
    if ! proton-drive filesystem list "$REMOTE_DIR" -j >/dev/null 2>&1; then
        echo "ERROR: Cannot access $REMOTE_DIR — are you logged in?"
        echo "Run: proton-drive auth login"
        exit 1
    fi
}

check_remote_manifest_sane() {
    if [ ! -s "$REMOTE_MANIFEST" ] && [ -s "$SNAPSHOT" ]; then
        echo "ERROR: Remote listing came back empty but sync history exists."
        echo "Refusing to proceed — this would delete all local files."
        echo "If the remote really is empty, remove the snapshot to reset:"
        echo "  rm '$SNAPSHOT'"
        exit 1
    fi
}

# ============================================================
# MOVE EXECUTION
# ============================================================

# A file moved locally from old_rel -> new_rel.
# Mirror that move on the remote instead of trash + re-upload.
do_remote_move() {
    local old_rel="$1"
    local new_rel="$2"

    local old_parent new_parent
    old_parent=$(dirname "$old_rel")
    new_parent=$(dirname "$new_rel")
    [ "$old_parent" = "." ] && old_parent=""
    [ "$new_parent" = "." ] && new_parent=""

    local old_base new_base
    old_base=$(basename "$old_rel")
    new_base=$(basename "$new_rel")

    local target_parent_path
    if [ -z "$new_parent" ]; then
        target_parent_path="$REMOTE_DIR"
    else
        target_parent_path="$REMOTE_DIR/$new_parent"
    fi

    ensure_remote_folders "$new_parent"

    if [ "$old_parent" != "$new_parent" ]; then
        run_retry proton-drive filesystem move \
            "$REMOTE_DIR/$old_rel" "$target_parent_path" || return 1
    fi

    if [ "$old_base" != "$new_base" ]; then
        run_retry proton-drive filesystem rename \
            "$target_parent_path/$old_base" "$new_base" || return 1
    fi

    return 0
}

# ============================================================
# MAIN SYNC
# ============================================================

sync() {
    > "$NEW_SNAPSHOT"

    # --------------------------------------------------------
    # PHASE 1: Build manifests
    # --------------------------------------------------------
    echo "=== Building local manifest ==="
    > "$LOCAL_MANIFEST"
    find "$LOCAL_DIR" -mindepth 1 | sort | \
        while read -r path; do
            rel="${path#$LOCAL_DIR/}"
            if is_excluded "$rel"; then
                continue
            fi
            if [ -d "$path" ]; then
                echo "folder|$rel" >> "$LOCAL_MANIFEST"
            else
                echo "file|$rel" >> "$LOCAL_MANIFEST"
            fi
        done

    echo "=== Building remote manifest ==="
    > "$REMOTE_MANIFEST"
    list_remote_recursive "$REMOTE_DIR" "" | sort > "$REMOTE_MANIFEST"

    check_remote_manifest_sane

    load_snapshot
    load_manifests_to_memory
    build_remote_dir_cache

    debug_file "Local manifest" "$LOCAL_MANIFEST"
    debug_file "Remote manifest" "$REMOTE_MANIFEST"

    # --------------------------------------------------------
    # PHASE 2: Scan local items
    # --------------------------------------------------------
    echo ""
    echo "=== Processing local items ==="
    while IFS='|' read -r type rel; do
        remote_path="$REMOTE_DIR/$rel"
        local_path="$LOCAL_DIR/$rel"

        if [ "$type" = "folder" ]; then
            if [ -n "${REMOTE_ITEMS[folder|${rel}]+x}" ]; then
                echo "[OK] folder: $rel"
                echo "folder|${rel}|" >> "$NEW_SNAPSHOT"
            elif was_previously_synced "$rel"; then
                # Deleted remotely — defer until after move detection
                DEL_LOCAL_FOLDERS+=("$rel")
            else
                ensure_remote_folders "$rel"
                echo "folder|${rel}|" >> "$NEW_SNAPSHOT"
            fi

        elif [ "$type" = "file" ]; then
            if [ ! -f "$local_path" ]; then
                continue
            fi

            local local_fp
            local_fp=$(get_local_fingerprint "$local_path")
            local prev_local_fp="${SNAPSHOT_LOCAL_FP[$rel]:-}"
            local prev_remote_fp="${SNAPSHOT_REMOTE_FP[$rel]:-}"

            if [ -n "${REMOTE_ITEMS[file|${rel}]+x}" ]; then
                # --- File exists on both sides ---
                local remote_fp="${REMOTE_ITEMS[file|${rel}]}"

                local local_changed=false
                local remote_changed=false

                if [ -n "$prev_local_fp" ] && [ "$prev_local_fp" != "$local_fp" ]; then
                    local_changed=true
                fi
                if [ -n "$prev_remote_fp" ] && [ "$prev_remote_fp" != "$remote_fp" ]; then
                    remote_changed=true
                fi

                debug "$rel: local_fp=$local_fp prev=$prev_local_fp changed=$local_changed"
                debug "$rel: remote_fp=$remote_fp prev=$prev_remote_fp changed=$remote_changed"

                if [ -z "$prev_local_fp" ] || [ -z "$prev_remote_fp" ]; then
                    echo "[FIRST SYNC] $rel — recording state"
                    COUNT_FIRST_SYNC=$((COUNT_FIRST_SYNC + 1))
                    echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"

                elif [ "$local_changed" = false ] && [ "$remote_changed" = false ]; then
                    echo "[OK] $rel"
                    COUNT_OK=$((COUNT_OK + 1))
                    echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"

                elif [ "$local_changed" = true ] && [ "$remote_changed" = false ]; then
                    echo "[UPLOAD MODIFIED] $rel (changed locally)"
                    local parent
                    parent=$(dirname "$remote_path")
                    if run_retry proton-drive filesystem upload -f replace \
                        "$local_path" "$parent"; then
                        COUNT_UPLOADED=$((COUNT_UPLOADED + 1))
                        if [ "$DRY_RUN" = false ]; then
                            remote_fp=$(fetch_remote_fingerprint "$remote_path")
                            local_fp=$(get_local_fingerprint "$local_path")
                        fi
                        echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
                    else
                        COUNT_ERRORS=$((COUNT_ERRORS + 1))
                        echo "[SKIP] Will retry next sync: $rel"
                        # Keep old state so it retries next run
                        echo "file|${rel}|${prev_local_fp}|${prev_remote_fp}" >> "$NEW_SNAPSHOT"
                    fi

                elif [ "$local_changed" = false ] && [ "$remote_changed" = true ]; then
                    echo "[DOWNLOAD MODIFIED] $rel (changed remotely)"
                    local local_parent
                    local_parent=$(dirname "$local_path")
                    ensure_local_folders "$local_parent"
                    if run_retry proton-drive filesystem download -f replace \
                        "$remote_path" "$local_parent"; then
                        COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
                        if [ "$DRY_RUN" = false ]; then
                            local_fp=$(get_local_fingerprint "$local_path")
                        fi
                        echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
                    else
                        COUNT_ERRORS=$((COUNT_ERRORS + 1))
                        echo "[SKIP] Will retry next sync: $rel"
                        echo "file|${rel}|${prev_local_fp}|${prev_remote_fp}" >> "$NEW_SNAPSHOT"
                    fi

                else
                    echo "[CONFLICT] $rel — changed on BOTH sides!"
                    echo "  Local FP:       $local_fp"
                    echo "  Prev Local FP:  $prev_local_fp"
                    echo "  Remote FP:      $remote_fp"
                    echo "  Prev Remote FP: $prev_remote_fp"
                    COUNT_CONFLICTS=$((COUNT_CONFLICTS + 1))
                    local local_parent base ext
                    local_parent=$(dirname "$local_path")
                    base="${rel%.*}"
                    ext="${rel##*.}"
                    echo "  Saving remote as ${base}.remote.${ext}"
                    if run_retry proton-drive filesystem download \
                        "$remote_path" "$local_parent"; then
                        if [ "$DRY_RUN" = false ]; then
                            mv "$local_parent/$(basename "$rel")" \
                               "$local_parent/$(basename "${base}.remote.${ext}")" \
                               2>/dev/null || true
                        fi
                    fi
                    # Record current state; user resolves manually
                    echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
                fi
            else
                # --- File does not exist remotely ---
                if was_previously_synced "$rel"; then
                    # Deleted remotely — defer for move detection
                    DELETED_REMOTELY_FILES+=("$rel")
                else
                    # New local file — defer for move detection
                    NEW_LOCAL_FILES+=("$rel")
                    NEW_LOCAL_FP["$rel"]="$local_fp"
                fi
            fi
        fi
    done < "$LOCAL_MANIFEST"

    # --------------------------------------------------------
    # PHASE 3: Scan remote-only items
    # --------------------------------------------------------
    echo ""
    echo "=== Processing remote-only items ==="
    while IFS='|' read -r type rel size mtime; do
        local_path="$LOCAL_DIR/$rel"
        remote_path="$REMOTE_DIR/$rel"

        if [ -n "${LOCAL_ITEMS[${type}|${rel}]:-}" ]; then
            continue
        fi

        if [ "$type" = "folder" ]; then
            if [ -d "$local_path" ]; then
                debug "Folder exists locally, skipping: $rel"
                echo "folder|${rel}|" >> "$NEW_SNAPSHOT"
                continue
            fi

            if was_previously_synced "$rel"; then
                # Deleted locally — defer
                TRASH_REMOTE_FOLDERS+=("$rel")
            else
                echo "[DOWNLOAD NEW FOLDER] $rel"
                ensure_local_folders "$local_path"
                echo "folder|${rel}|" >> "$NEW_SNAPSHOT"
            fi

        elif [ "$type" = "file" ]; then
            if [ -f "$local_path" ]; then
                debug "File exists locally, skipping: $rel"
                continue
            fi

            if was_previously_synced "$rel"; then
                # Deleted locally — defer for move detection
                TRASH_REMOTE_FILES+=("$rel")
            else
                # New remote file — defer for move detection
                NEW_REMOTE_FILES+=("$rel")
                NEW_REMOTE_FP["$rel"]="${size}|${mtime}"
            fi
        fi
    done < "$REMOTE_MANIFEST"

    # --------------------------------------------------------
    # PHASE 4: Move detection
    # --------------------------------------------------------
    echo ""
    echo "=== Detecting moves ==="

    # --- Local moves: new local file matches a locally-deleted
    #     remote file's last-known LOCAL fingerprint ---
    declare -A LFP_TO_OLD=()
    local old_rel
    for old_rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        local fp="${SNAPSHOT_LOCAL_FP[$old_rel]:-}"
        if [ -n "$fp" ] && [ "$fp" != "0|0" ]; then
            LFP_TO_OLD["$fp"]="$old_rel"
        fi
    done

    declare -a REMAINING_NEW_LOCAL=()
    local new_rel
    for new_rel in "${NEW_LOCAL_FILES[@]+"${NEW_LOCAL_FILES[@]}"}"; do
        local fp="${NEW_LOCAL_FP[$new_rel]}"
        local match="${LFP_TO_OLD[$fp]:-}"
        if [ -n "$match" ]; then
            echo "[MOVE REMOTE] $match → $new_rel"
            if do_remote_move "$match" "$new_rel"; then
                COUNT_MOVED_REMOTE=$((COUNT_MOVED_REMOTE + 1))
                local remote_fp="${SNAPSHOT_REMOTE_FP[$match]:-}"
                echo "file|${new_rel}|${fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
                # Consume both sides of the match
                unset "LFP_TO_OLD[$fp]"
                TRASH_REMOTE_FILES=("${TRASH_REMOTE_FILES[@]/$match}")
            else
                COUNT_ERRORS=$((COUNT_ERRORS + 1))
                echo "[SKIP] Move failed, will resolve next sync: $new_rel"
            fi
        else
            REMAINING_NEW_LOCAL+=("$new_rel")
        fi
    done

    # --- Remote moves: new remote file matches a remotely-deleted
    #     local file's last-known REMOTE fingerprint ---
    declare -A RFP_TO_OLD=()
    for old_rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        local fp="${SNAPSHOT_REMOTE_FP[$old_rel]:-}"
        if [ -n "$fp" ] && [ "$fp" != "0|0" ]; then
            RFP_TO_OLD["$fp"]="$old_rel"
        fi
    done

    declare -a REMAINING_NEW_REMOTE=()
    for new_rel in "${NEW_REMOTE_FILES[@]+"${NEW_REMOTE_FILES[@]}"}"; do
        local fp="${NEW_REMOTE_FP[$new_rel]}"
        local match="${RFP_TO_OLD[$fp]:-}"
        if [ -n "$match" ] && [ -f "$LOCAL_DIR/$match" ]; then
            echo "[MOVE LOCAL] $match → $new_rel"
            ensure_local_folders "$(dirname "$LOCAL_DIR/$new_rel")"
            if run mv "$LOCAL_DIR/$match" "$LOCAL_DIR/$new_rel"; then
                COUNT_MOVED_LOCAL=$((COUNT_MOVED_LOCAL + 1))
                local local_fp
                if [ "$DRY_RUN" = false ]; then
                    local_fp=$(get_local_fingerprint "$LOCAL_DIR/$new_rel")
                else
                    local_fp="${SNAPSHOT_LOCAL_FP[$match]:-}"
                fi
                echo "file|${new_rel}|${local_fp}|${fp}" >> "$NEW_SNAPSHOT"
                unset "RFP_TO_OLD[$fp]"
                DELETED_REMOTELY_FILES=("${DELETED_REMOTELY_FILES[@]/$match}")
            else
                COUNT_ERRORS=$((COUNT_ERRORS + 1))
                REMAINING_NEW_REMOTE+=("$new_rel")
            fi
        else
            REMAINING_NEW_REMOTE+=("$new_rel")
        fi
    done

    # --------------------------------------------------------
    # PHASE 5: Execute remaining deferred actions
    # --------------------------------------------------------
    echo ""
    echo "=== Executing remaining actions ==="

    # Upload new local files
    for rel in "${REMAINING_NEW_LOCAL[@]+"${REMAINING_NEW_LOCAL[@]}"}"; do
        [ -z "$rel" ] && continue
        local_path="$LOCAL_DIR/$rel"
        remote_path="$REMOTE_DIR/$rel"
        [ -f "$local_path" ] || continue

        echo "[UPLOAD NEW] $rel"
        local parent_rel
        parent_rel=$(dirname "$rel")
        ensure_remote_folders "$parent_rel"
        if run_retry proton-drive filesystem upload \
            "$local_path" "$(dirname "$remote_path")"; then
            COUNT_UPLOADED=$((COUNT_UPLOADED + 1))
            local local_fp remote_fp=""
            local_fp=$(get_local_fingerprint "$local_path")
            if [ "$DRY_RUN" = false ]; then
                remote_fp=$(fetch_remote_fingerprint "$remote_path")
            fi
            if [ -n "$remote_fp" ]; then
                echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
            fi
            # If fingerprint fetch failed: no snapshot entry, retried next run
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            echo "[SKIP] Will retry next sync: $rel"
        fi
    done

    # Download new remote files
    for rel in "${REMAINING_NEW_REMOTE[@]+"${REMAINING_NEW_REMOTE[@]}"}"; do
        [ -z "$rel" ] && continue
        local_path="$LOCAL_DIR/$rel"
        remote_path="$REMOTE_DIR/$rel"

        echo "[DOWNLOAD NEW] $rel"
        local local_parent
        local_parent=$(dirname "$local_path")
        ensure_local_folders "$local_parent"
        if run_retry proton-drive filesystem download \
            "$remote_path" "$local_parent"; then
            if [ -f "$local_path" ]; then
                COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
                local local_fp
                local_fp=$(get_local_fingerprint "$local_path")
                echo "file|${rel}|${local_fp}|${NEW_REMOTE_FP[$rel]}" >> "$NEW_SNAPSHOT"
            elif [ "$DRY_RUN" = false ]; then
                COUNT_ERRORS=$((COUNT_ERRORS + 1))
                echo "[WARNING] Download failed or skipped: $rel"
            fi
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            echo "[SKIP] Will retry next sync: $rel"
        fi
    done

    # Delete local files that were deleted remotely
    for rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        [ -z "$rel" ] && continue
        local_path="$LOCAL_DIR/$rel"
        [ -f "$local_path" ] || continue
        echo "[DELETED REMOTELY] $rel → removing local"
        trash_local "$local_path" "$rel"
        COUNT_DELETED_LOCAL=$((COUNT_DELETED_LOCAL + 1))
    done

    # Trash remote files that were deleted locally
    for rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        [ -z "$rel" ] && continue
        # Safety: never trash remote if it somehow exists locally
        [ -f "$LOCAL_DIR/$rel" ] && continue
        echo "[DELETED LOCALLY] $rel → trashing remote"
        if run_retry proton-drive filesystem trash "$REMOTE_DIR/$rel"; then
            COUNT_TRASHED_REMOTE=$((COUNT_TRASHED_REMOTE + 1))
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
        fi
    done

    # Remove local folders that were deleted remotely
    for rel in "${DEL_LOCAL_FOLDERS[@]+"${DEL_LOCAL_FOLDERS[@]}"}"; do
        [ -z "$rel" ] && continue
        local_path="$LOCAL_DIR/$rel"
        [ -d "$local_path" ] || continue
        echo "[DELETED REMOTELY] folder: $rel → removing local"
        trash_local "$local_path" "$rel"
        COUNT_DELETED_LOCAL=$((COUNT_DELETED_LOCAL + 1))
    done

    # Trash remote folders that were deleted locally
    for rel in "${TRASH_REMOTE_FOLDERS[@]+"${TRASH_REMOTE_FOLDERS[@]}"}"; do
        [ -z "$rel" ] && continue
        [ -d "$LOCAL_DIR/$rel" ] && continue
        echo "[DELETED LOCALLY] folder: $rel → trashing remote"
        if run_retry proton-drive filesystem trash "$REMOTE_DIR/$rel"; then
            COUNT_TRASHED_REMOTE=$((COUNT_TRASHED_REMOTE + 1))
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
        fi
    done

    # --------------------------------------------------------
    # Finalize
    # --------------------------------------------------------
    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo "[DRY RUN] Snapshot not updated."
        rm -f "$NEW_SNAPSHOT"
    else
        mv "$NEW_SNAPSHOT" "$SNAPSHOT"
    fi
    rm -f "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"

    cleanup_old_trash

    # --------------------------------------------------------
    # Summary
    # --------------------------------------------------------
    echo ""
    echo "=== Sync Summary ==="
    echo "  Unchanged:       $COUNT_OK"
    echo "  First sync:      $COUNT_FIRST_SYNC"
    echo "  Uploaded:        $COUNT_UPLOADED"
    echo "  Downloaded:      $COUNT_DOWNLOADED"
    echo "  Moved (remote):  $COUNT_MOVED_REMOTE"
    echo "  Moved (local):   $COUNT_MOVED_LOCAL"
    echo "  Deleted local:   $COUNT_DELETED_LOCAL"
    echo "  Trashed remote:  $COUNT_TRASHED_REMOTE"
    echo "  Conflicts:       $COUNT_CONFLICTS"
    echo "  Errors:          $COUNT_ERRORS"

    if [ "$COUNT_ERRORS" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ============================================================
# RUN
# ============================================================

echo "Proton Drive Sync"
echo "Local:   $LOCAL_DIR"
echo "Remote:  $REMOTE_DIR"
echo "State:   $STATE_DIR"
[ "$DRY_RUN" = true ] && echo "Mode:    DRY RUN — no changes will be made"
echo ""

acquire_lock
check_auth
sync
