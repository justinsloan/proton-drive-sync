#!/bin/bash
set -uo pipefail

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

LOG_DIR="$STATE_DIR/logs"
LOG_FILE="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"

EXCLUDE_PATTERNS=(
    "*.tmp"
    "*.swp"
    "*.partial"
    ".DS_Store"
    "Thumbs.db"
    ".git"
    ".proton-sync"
)

mkdir -p "$STATE_DIR" "$LOG_DIR"
touch "$SNAPSHOT"

DIALOG=/usr/bin/dialog
DIALOG_BACKTITLE="Proton Drive Sync"
DIALOG_HEIGHT=20
DIALOG_WIDTH=76

DEBUG="${PROTON_SYNC_DEBUG:-false}"
DRY_RUN=false

# Conflict strategy: ask | local | remote | both | skip
CONFLICT_STRATEGY="${PROTON_SYNC_CONFLICT:-ask}"

# ============================================================
# IN-MEMORY STATE
# ============================================================

declare -A SNAPSHOT_LOCAL_FP
declare -A SNAPSHOT_REMOTE_FP
declare -A SNAPSHOT_SEEN
declare -A LOCAL_ITEMS
declare -A REMOTE_ITEMS
declare -A KNOWN_DIRS

declare -a NEW_LOCAL_FILES=()
declare -a NEW_REMOTE_FILES=()
declare -a DELETED_REMOTELY_FILES=()
declare -a TRASH_REMOTE_FILES=()
declare -a DEL_LOCAL_FOLDERS=()
declare -a TRASH_REMOTE_FOLDERS=()

declare -A NEW_LOCAL_FP=()
declare -A NEW_REMOTE_FP=()

# Conflict queue
declare -a CONFLICTS=()
declare -A CONFLICT_LOCAL_FP=()
declare -A CONFLICT_REMOTE_FP=()
declare -A CONFLICT_PREV_L=()
declare -A CONFLICT_PREV_R=()

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

TOTAL_ITEMS=0
PROCESSED_ITEMS=0

# ============================================================
# LOGGING
# ============================================================

log() {
    echo "$*" >> "$LOG_FILE"
}

# ============================================================
# LOCKING
# ============================================================

acquire_lock() {
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        return 1
    fi
    trap 'rm -rf "$LOCK_FILE"' EXIT
    return 0
}

release_lock() {
    rm -rf "$LOCK_FILE"
    trap - EXIT
}

# ============================================================
# EXECUTION HELPERS
# ============================================================

debug() {
    if [ "$DEBUG" = true ]; then
        log "[DEBUG] $*"
    fi
}

run() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] $*"
        return 0
    fi
    "$@" >>"$LOG_FILE" 2>&1
}

retry() {
    local attempts=3
    local delay=5
    local i
    for ((i = 1; i <= attempts; i++)); do
        if "$@" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            log "[RETRY $i/$attempts] Failed, waiting ${delay}s: $*"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    log "[ERROR] Giving up after $attempts attempts: $*"
    return 1
}

run_retry() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] $*"
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
# LOCAL TRASH
# ============================================================

trash_local() {
    local local_path="$1"
    local rel="$2"
    [ -e "$local_path" ] || return 0
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] trash_local $local_path"
        return 0
    fi
    mkdir -p "$LOCAL_TRASH/$(dirname "$rel")"
    mv "$local_path" "$LOCAL_TRASH/$rel"
    log "  (recoverable in $LOCAL_TRASH/$rel)"
}

cleanup_old_trash() {
    [ "$DRY_RUN" = true ] && return 0
    if [ -d "$STATE_DIR/trash" ]; then
        find "$STATE_DIR/trash" -mindepth 1 -maxdepth 1 -type d \
            -mtime +"$TRASH_RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true
    fi
}

# ============================================================
# FINGERPRINTS
# ============================================================

get_local_fingerprint() {
    stat -c '%s|%Y' "$1"
}

fmt_fp() {
    local fp="$1"
    local size="${fp%%|*}"
    local mtime="${fp##*|}"
    local when="unknown"
    if [ "$mtime" != "0" ] && [ -n "$mtime" ]; then
        when=$(date -d "@$mtime" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$mtime")
    fi
    echo "${size} bytes, modified ${when}"
}

# ============================================================
# REMOTE LISTING
# ============================================================

list_remote_recursive() {
    local remote_path="$1"
    local prefix="$2"

    proton-drive filesystem list "$remote_path" -j 2>>"$LOG_FILE" | \
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
                continue
            fi

            if [ "$type" = "folder" ]; then
                echo "folder|$rel_path||"
                list_remote_recursive "$remote_path/$name" "$rel_path"
            else
                if [ "$media" = "application/vnd.proton.doc" ]; then
                    log "[SKIP PROTON DOC] $rel_path"
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

fetch_remote_fingerprint() {
    local remote_path="$1"
    local info rsize rmtime rmtime_epoch
    info=$(proton-drive filesystem info "$remote_path" -j 2>/dev/null) || true
    [ -z "$info" ] && { echo ""; return; }
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
        [ "$type" = "folder" ] && KNOWN_DIRS["$rel"]=1
    done < "$REMOTE_MANIFEST"
}

remote_dir_exists() {
    local dir="$1"
    [ -z "$dir" ] && dir="/"
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
    log "[CREATE REMOTE FOLDER] $full_parent/$folder_name"
    run_retry proton-drive filesystem create-folder "$full_parent" "$folder_name"
    if [ -z "$parent_rel" ]; then
        KNOWN_DIRS["$folder_name"]=1
    else
        KNOWN_DIRS["$parent_rel/$folder_name"]=1
    fi
}

ensure_remote_folders() {
    local rel_dir="$1"
    { [ -z "$rel_dir" ] || [ "$rel_dir" = "." ]; } && return
    remote_dir_exists "$rel_dir" && return
    local current=""
    IFS='/' read -ra parts <<< "$rel_dir"
    for part in "${parts[@]}"; do
        local next
        if [ -z "$current" ]; then next="$part"; else next="$current/$part"; fi
        remote_dir_exists "$next" || create_remote_folder "$current" "$part"
        current="$next"
    done
}

ensure_local_folders() {
    local local_path="$1"
    if [ ! -d "$local_path" ]; then
        log "[CREATE LOCAL FOLDER] $local_path"
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
# AUTHENTICATION
# ============================================================

# Returns 0 if authenticated, 1 otherwise.
is_authenticated() {
    proton-drive filesystem list "$REMOTE_DIR" -j >/dev/null 2>&1
}

check_remote_manifest_sane() {
    if [ ! -s "$REMOTE_MANIFEST" ] && [ -s "$SNAPSHOT" ]; then
        return 1
    fi
    return 0
}

# Interactive login flow (drops out of dialog to run the CLI login).
perform_login() {
    clear
    echo "======================================"
    echo "  Proton Drive Authentication"
    echo "======================================"
    echo
    echo "Launching 'proton-drive auth login'."
    echo "Follow the prompts below to sign in."
    echo
    proton-drive auth login
    local rc=$?
    echo
    if [ "$rc" -eq 0 ]; then
        echo "Login command completed."
    else
        echo "Login command exited with status $rc."
    fi
    read -rp "Press Enter to continue..."
    return "$rc"
}

# Ensure the user is authenticated. If not, prompt to log in,
# retrying until success or the user gives up.
# Returns 0 if authenticated, 1 if the user declined / failed.
ensure_authenticated() {
    if is_authenticated; then
        return 0
    fi

    while true; do
        if [ ! -x "$DIALOG" ]; then
            # No dialog available — plain-text fallback
            echo "You are not logged in to Proton Drive."
            read -rp "Log in now? [Y/n] " ans
            case "$ans" in
                [nN]*) return 1 ;;
            esac
            perform_login
        else
            "$DIALOG" --backtitle "$DIALOG_BACKTITLE" \
                --title "Not Authenticated" \
                --yesno \
"You are not currently logged in to Proton Drive.

Would you like to log in now?

(Selecting 'No' will exit the application.)" \
                12 "$DIALOG_WIDTH"
            local rc=$?
            if [ "$rc" -ne 0 ]; then
                return 1
            fi
            perform_login
        fi

        # Re-check after the login attempt
        if is_authenticated; then
            if [ -x "$DIALOG" ]; then
                "$DIALOG" --backtitle "$DIALOG_BACKTITLE" \
                    --title "Authenticated" \
                    --msgbox "Successfully logged in to Proton Drive." \
                    7 "$DIALOG_WIDTH"
            else
                echo "Successfully logged in."
            fi
            return 0
        fi

        # Still not authenticated — offer to retry
        if [ -x "$DIALOG" ]; then
            "$DIALOG" --backtitle "$DIALOG_BACKTITLE" \
                --title "Login Failed" \
                --yesno \
"Still unable to access:
  $REMOTE_DIR

The login may not have completed successfully.

Try logging in again?" \
                12 "$DIALOG_WIDTH"
            [ $? -ne 0 ] && return 1
        else
            read -rp "Login failed. Try again? [Y/n] " ans
            case "$ans" in
                [nN]*) return 1 ;;
            esac
        fi
    done
}

# ============================================================
# MOVE EXECUTION
# ============================================================

do_remote_move() {
    local old_rel="$1"
    local new_rel="$2"
    local old_parent new_parent old_base new_base target_parent_path
    old_parent=$(dirname "$old_rel"); [ "$old_parent" = "." ] && old_parent=""
    new_parent=$(dirname "$new_rel"); [ "$new_parent" = "." ] && new_parent=""
    old_base=$(basename "$old_rel")
    new_base=$(basename "$new_rel")
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
# CONFLICT RESOLUTION
# ============================================================

resolve_keep_local() {
    local rel="$1"
    local local_path="$LOCAL_DIR/$rel"
    local remote_path="$REMOTE_DIR/$rel"
    log "[RESOLVE keep-local] $rel"
    if run_retry proton-drive filesystem upload -f replace "$local_path" "$(dirname "$remote_path")"; then
        COUNT_UPLOADED=$((COUNT_UPLOADED + 1))
        local lfp rfp
        lfp=$(get_local_fingerprint "$local_path")
        if [ "$DRY_RUN" = false ]; then
            rfp=$(fetch_remote_fingerprint "$remote_path")
        else
            rfp="${CONFLICT_REMOTE_FP[$rel]}"
        fi
        echo "file|${rel}|${lfp}|${rfp}" >> "$NEW_SNAPSHOT"
    else
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
        echo "file|${rel}|${CONFLICT_PREV_L[$rel]}|${CONFLICT_PREV_R[$rel]}" >> "$NEW_SNAPSHOT"
    fi
}

resolve_keep_remote() {
    local rel="$1"
    local local_path="$LOCAL_DIR/$rel"
    local remote_path="$REMOTE_DIR/$rel"
    log "[RESOLVE keep-remote] $rel"
    ensure_local_folders "$(dirname "$local_path")"
    if run_retry proton-drive filesystem download -f replace "$remote_path" "$(dirname "$local_path")"; then
        COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
        local lfp
        if [ "$DRY_RUN" = false ]; then
            lfp=$(get_local_fingerprint "$local_path")
        else
            lfp="${CONFLICT_LOCAL_FP[$rel]}"
        fi
        echo "file|${rel}|${lfp}|${CONFLICT_REMOTE_FP[$rel]}" >> "$NEW_SNAPSHOT"
    else
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
        echo "file|${rel}|${CONFLICT_PREV_L[$rel]}|${CONFLICT_PREV_R[$rel]}" >> "$NEW_SNAPSHOT"
    fi
}

resolve_keep_both() {
    local rel="$1"
    local local_path="$LOCAL_DIR/$rel"
    local remote_path="$REMOTE_DIR/$rel"
    local local_parent base ext conflict_name
    local_parent=$(dirname "$local_path")
    base="${rel%.*}"
    ext="${rel##*.}"
    if [ "$base" = "$rel" ]; then
        conflict_name="${rel}.remote"
    else
        conflict_name="${base}.remote.${ext}"
    fi
    log "[RESOLVE keep-both] $rel -> also saving remote as ${conflict_name}"
    if run_retry proton-drive filesystem download "$remote_path" "$local_parent"; then
        if [ "$DRY_RUN" = false ]; then
            mv "$local_parent/$(basename "$rel")" \
               "$(dirname "$LOCAL_DIR/$conflict_name")/$(basename "$conflict_name")" \
               2>/dev/null || true
        fi
    fi
    echo "file|${rel}|${CONFLICT_LOCAL_FP[$rel]}|${CONFLICT_REMOTE_FP[$rel]}" >> "$NEW_SNAPSHOT"
}

apply_conflict_resolution() {
    local rel="$1"
    local strategy="$2"
    case "$strategy" in
        local)  resolve_keep_local "$rel" ;;
        remote) resolve_keep_remote "$rel" ;;
        both)   resolve_keep_both "$rel" ;;
        skip)
            log "[RESOLVE skip] $rel — leaving unresolved"
            echo "file|${rel}|${CONFLICT_PREV_L[$rel]}|${CONFLICT_PREV_R[$rel]}" >> "$NEW_SNAPSHOT"
            ;;
    esac
}

resolve_conflict_interactive() {
    local rel="$1"
    local local_desc remote_desc
    local_desc=$(fmt_fp "${CONFLICT_LOCAL_FP[$rel]}")
    remote_desc=$(fmt_fp "${CONFLICT_REMOTE_FP[$rel]}")

    local choice
    choice=$("$DIALOG" --backtitle "$DIALOG_BACKTITLE" \
        --title "Conflict: $rel" \
        --no-cancel \
        --menu \
"This file changed on BOTH sides since the last sync.

  LOCAL:  $local_desc
  REMOTE: $remote_desc

How would you like to resolve it?" \
        18 "$DIALOG_WIDTH" 6 \
        local     "Keep LOCAL  (upload, overwrite remote)" \
        remote    "Keep REMOTE (download, overwrite local)" \
        both      "Keep BOTH   (save remote as .remote copy)" \
        skip      "Skip        (decide later)" \
        alllocal  "Keep LOCAL for ALL remaining conflicts" \
        allremote "Keep REMOTE for ALL remaining conflicts" \
        3>&1 1>&2 2>&3)

    echo "$choice"
}

resolve_all_conflicts() {
    local count="${#CONFLICTS[@]}"
    [ "$count" -eq 0 ] && return

    log "=== Resolving $count conflict(s) ==="

    if [ "$CONFLICT_STRATEGY" != "ask" ]; then
        local rel
        for rel in "${CONFLICTS[@]}"; do
            apply_conflict_resolution "$rel" "$CONFLICT_STRATEGY"
        done
        return
    fi

    local bulk=""
    local rel choice
    for rel in "${CONFLICTS[@]}"; do
        if [ -n "$bulk" ]; then
            apply_conflict_resolution "$rel" "$bulk"
            continue
        fi

        choice=$(resolve_conflict_interactive "$rel")

        case "$choice" in
            alllocal)
                bulk="local"
                apply_conflict_resolution "$rel" "local"
                ;;
            allremote)
                bulk="remote"
                apply_conflict_resolution "$rel" "remote"
                ;;
            local|remote|both|skip)
                apply_conflict_resolution "$rel" "$choice"
                ;;
            *)
                apply_conflict_resolution "$rel" "skip"
                ;;
        esac
    done
}

# ============================================================
# PROGRESS GAUGE HELPER
# ============================================================

gauge_update() {
    local msg="$1"
    PROCESSED_ITEMS=$((PROCESSED_ITEMS + 1))
    local pct=0
    if [ "$TOTAL_ITEMS" -gt 0 ]; then
        pct=$(( PROCESSED_ITEMS * 100 / TOTAL_ITEMS ))
        [ "$pct" -gt 100 ] && pct=100
    fi
    echo "XXX"
    echo "$pct"
    echo "$msg"
    echo "XXX"
}

# ============================================================
# CORE SYNC ENGINE
# ============================================================

sync_engine() {
    local conflict_dump="$1"
    > "$NEW_SNAPSHOT"

    SNAPSHOT_LOCAL_FP=(); SNAPSHOT_REMOTE_FP=(); SNAPSHOT_SEEN=()
    LOCAL_ITEMS=(); REMOTE_ITEMS=(); KNOWN_DIRS=()
    NEW_LOCAL_FILES=(); NEW_REMOTE_FILES=(); DELETED_REMOTELY_FILES=()
    TRASH_REMOTE_FILES=(); DEL_LOCAL_FOLDERS=(); TRASH_REMOTE_FOLDERS=()
    NEW_LOCAL_FP=(); NEW_REMOTE_FP=()
    CONFLICTS=(); CONFLICT_LOCAL_FP=(); CONFLICT_REMOTE_FP=()
    CONFLICT_PREV_L=(); CONFLICT_PREV_R=()
    COUNT_OK=0; COUNT_UPLOADED=0; COUNT_DOWNLOADED=0
    COUNT_MOVED_REMOTE=0; COUNT_MOVED_LOCAL=0
    COUNT_DELETED_LOCAL=0; COUNT_TRASHED_REMOTE=0
    COUNT_CONFLICTS=0; COUNT_ERRORS=0; COUNT_FIRST_SYNC=0
    PROCESSED_ITEMS=0

    log "=== Sync started $(date) ==="
    [ "$DRY_RUN" = true ] && log "=== DRY RUN MODE ==="

    gauge_update "Building local manifest..."
    > "$LOCAL_MANIFEST"
    find "$LOCAL_DIR" -mindepth 1 | sort | \
        while read -r path; do
            rel="${path#$LOCAL_DIR/}"
            is_excluded "$rel" && continue
            if [ -d "$path" ]; then
                echo "folder|$rel" >> "$LOCAL_MANIFEST"
            else
                echo "file|$rel" >> "$LOCAL_MANIFEST"
            fi
        done

    gauge_update "Building remote manifest..."
    > "$REMOTE_MANIFEST"
    list_remote_recursive "$REMOTE_DIR" "" | sort > "$REMOTE_MANIFEST"

    if ! check_remote_manifest_sane; then
        log "[FATAL] Remote listing empty but sync history exists. Aborting."
        echo "XXX"; echo "100"; echo "ABORTED: unsafe remote state (see log)"; echo "XXX"
        return 1
    fi

    load_snapshot
    load_manifests_to_memory
    build_remote_dir_cache

    TOTAL_ITEMS=$(( $(wc -l < "$LOCAL_MANIFEST") + $(wc -l < "$REMOTE_MANIFEST") + 2 ))

    # ---------- PHASE 2: local items ----------
    while IFS='|' read -r type rel; do
        gauge_update "Local: $rel"
        remote_path="$REMOTE_DIR/$rel"
        local_path="$LOCAL_DIR/$rel"

        if [ "$type" = "folder" ]; then
            if [ -n "${REMOTE_ITEMS[folder|${rel}]+x}" ]; then
                log "[OK] folder: $rel"
                echo "folder|${rel}|" >> "$NEW_SNAPSHOT"
            elif was_previously_synced "$rel"; then
                DEL_LOCAL_FOLDERS+=("$rel")
            else
                ensure_remote_folders "$rel"
                echo "folder|${rel}|" >> "$NEW_SNAPSHOT"
            fi

        elif [ "$type" = "file" ]; then
            [ -f "$local_path" ] || continue
            local local_fp; local_fp=$(get_local_fingerprint "$local_path")
            local prev_local_fp="${SNAPSHOT_LOCAL_FP[$rel]:-}"
            local prev_remote_fp="${SNAPSHOT_REMOTE_FP[$rel]:-}"

            if [ -n "${REMOTE_ITEMS[file|${rel}]+x}" ]; then
                local remote_fp="${REMOTE_ITEMS[file|${rel}]}"
                local local_changed=false remote_changed=false
                [ -n "$prev_local_fp" ] && [ "$prev_local_fp" != "$local_fp" ] && local_changed=true
                [ -n "$prev_remote_fp" ] && [ "$prev_remote_fp" != "$remote_fp" ] && remote_changed=true

                if [ -z "$prev_local_fp" ] || [ -z "$prev_remote_fp" ]; then
                    log "[FIRST SYNC] $rel"
                    COUNT_FIRST_SYNC=$((COUNT_FIRST_SYNC + 1))
                    echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
                elif [ "$local_changed" = false ] && [ "$remote_changed" = false ]; then
                    log "[OK] $rel"
                    COUNT_OK=$((COUNT_OK + 1))
                    echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
                elif [ "$local_changed" = true ] && [ "$remote_changed" = false ]; then
                    log "[UPLOAD MODIFIED] $rel"
                    if run_retry proton-drive filesystem upload -f replace "$local_path" "$(dirname "$remote_path")"; then
                        COUNT_UPLOADED=$((COUNT_UPLOADED + 1))
                        if [ "$DRY_RUN" = false ]; then
                            remote_fp=$(fetch_remote_fingerprint "$remote_path")
                            local_fp=$(get_local_fingerprint "$local_path")
                        fi
                        echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
                    else
                        COUNT_ERRORS=$((COUNT_ERRORS + 1))
                        echo "file|${rel}|${prev_local_fp}|${prev_remote_fp}" >> "$NEW_SNAPSHOT"
                    fi
                elif [ "$local_changed" = false ] && [ "$remote_changed" = true ]; then
                    log "[DOWNLOAD MODIFIED] $rel"
                    ensure_local_folders "$(dirname "$local_path")"
                    if run_retry proton-drive filesystem download -f replace "$remote_path" "$(dirname "$local_path")"; then
                        COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
                        [ "$DRY_RUN" = false ] && local_fp=$(get_local_fingerprint "$local_path")
                        echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
                    else
                        COUNT_ERRORS=$((COUNT_ERRORS + 1))
                        echo "file|${rel}|${prev_local_fp}|${prev_remote_fp}" >> "$NEW_SNAPSHOT"
                    fi
                else
                    log "[CONFLICT] $rel"
                    COUNT_CONFLICTS=$((COUNT_CONFLICTS + 1))
                    echo "${rel}|${local_fp}|${remote_fp}|${prev_local_fp}|${prev_remote_fp}" \
                        >> "$conflict_dump"
                fi
            else
                if was_previously_synced "$rel"; then
                    DELETED_REMOTELY_FILES+=("$rel")
                else
                    NEW_LOCAL_FILES+=("$rel")
                    NEW_LOCAL_FP["$rel"]="$local_fp"
                fi
            fi
        fi
    done < "$LOCAL_MANIFEST"

    # ---------- PHASE 3: remote-only items ----------
    while IFS='|' read -r type rel size mtime; do
        gauge_update "Remote: $rel"
        local_path="$LOCAL_DIR/$rel"
        [ -n "${LOCAL_ITEMS[${type}|${rel}]:-}" ] && continue

        if [ "$type" = "folder" ]; then
            if [ -d "$local_path" ]; then
                echo "folder|${rel}|" >> "$NEW_SNAPSHOT"
                continue
            fi
            if was_previously_synced "$rel"; then
                TRASH_REMOTE_FOLDERS+=("$rel")
            else
                log "[DOWNLOAD NEW FOLDER] $rel"
                ensure_local_folders "$local_path"
                echo "folder|${rel}|" >> "$NEW_SNAPSHOT"
            fi
        elif [ "$type" = "file" ]; then
            [ -f "$local_path" ] && continue
            if was_previously_synced "$rel"; then
                TRASH_REMOTE_FILES+=("$rel")
            else
                NEW_REMOTE_FILES+=("$rel")
                NEW_REMOTE_FP["$rel"]="${size}|${mtime}"
            fi
        fi
    done < "$REMOTE_MANIFEST"

    # ---------- PHASE 4: move detection ----------
    gauge_update "Detecting moves..."
    declare -A LFP_TO_OLD=()
    local old_rel new_rel fp match
    for old_rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        fp="${SNAPSHOT_LOCAL_FP[$old_rel]:-}"
        [ -n "$fp" ] && [ "$fp" != "0|0" ] && LFP_TO_OLD["$fp"]="$old_rel"
    done
    declare -a REMAINING_NEW_LOCAL=()
    for new_rel in "${NEW_LOCAL_FILES[@]+"${NEW_LOCAL_FILES[@]}"}"; do
        fp="${NEW_LOCAL_FP[$new_rel]}"
        match="${LFP_TO_OLD[$fp]:-}"
        if [ -n "$match" ]; then
            log "[MOVE REMOTE] $match -> $new_rel"
            if do_remote_move "$match" "$new_rel"; then
                COUNT_MOVED_REMOTE=$((COUNT_MOVED_REMOTE + 1))
                echo "file|${new_rel}|${fp}|${SNAPSHOT_REMOTE_FP[$match]:-}" >> "$NEW_SNAPSHOT"
                unset "LFP_TO_OLD[$fp]"
                TRASH_REMOTE_FILES=("${TRASH_REMOTE_FILES[@]/$match}")
            else
                COUNT_ERRORS=$((COUNT_ERRORS + 1))
            fi
        else
            REMAINING_NEW_LOCAL+=("$new_rel")
        fi
    done

    declare -A RFP_TO_OLD=()
    for old_rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        fp="${SNAPSHOT_REMOTE_FP[$old_rel]:-}"
        [ -n "$fp" ] && [ "$fp" != "0|0" ] && RFP_TO_OLD["$fp"]="$old_rel"
    done
    declare -a REMAINING_NEW_REMOTE=()
    for new_rel in "${NEW_REMOTE_FILES[@]+"${NEW_REMOTE_FILES[@]}"}"; do
        fp="${NEW_REMOTE_FP[$new_rel]}"
        match="${RFP_TO_OLD[$fp]:-}"
        if [ -n "$match" ] && [ -f "$LOCAL_DIR/$match" ]; then
            log "[MOVE LOCAL] $match -> $new_rel"
            ensure_local_folders "$(dirname "$LOCAL_DIR/$new_rel")"
            if run mv "$LOCAL_DIR/$match" "$LOCAL_DIR/$new_rel"; then
                COUNT_MOVED_LOCAL=$((COUNT_MOVED_LOCAL + 1))
                local lfp
                if [ "$DRY_RUN" = false ]; then lfp=$(get_local_fingerprint "$LOCAL_DIR/$new_rel"); else lfp="${SNAPSHOT_LOCAL_FP[$match]:-}"; fi
                echo "file|${new_rel}|${lfp}|${fp}" >> "$NEW_SNAPSHOT"
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

    # ---------- PHASE 5: remaining actions ----------
    for rel in "${REMAINING_NEW_LOCAL[@]+"${REMAINING_NEW_LOCAL[@]}"}"; do
        [ -z "$rel" ] && continue
        gauge_update "Upload: $rel"
        local_path="$LOCAL_DIR/$rel"; remote_path="$REMOTE_DIR/$rel"
        [ -f "$local_path" ] || continue
        log "[UPLOAD NEW] $rel"
        ensure_remote_folders "$(dirname "$rel")"
        if run_retry proton-drive filesystem upload "$local_path" "$(dirname "$remote_path")"; then
            COUNT_UPLOADED=$((COUNT_UPLOADED + 1))
            local lfp rfp=""
            lfp=$(get_local_fingerprint "$local_path")
            [ "$DRY_RUN" = false ] && rfp=$(fetch_remote_fingerprint "$remote_path")
            [ -n "$rfp" ] && echo "file|${rel}|${lfp}|${rfp}" >> "$NEW_SNAPSHOT"
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
        fi
    done

    for rel in "${REMAINING_NEW_REMOTE[@]+"${REMAINING_NEW_REMOTE[@]}"}"; do
        [ -z "$rel" ] && continue
        gauge_update "Download: $rel"
        local_path="$LOCAL_DIR/$rel"; remote_path="$REMOTE_DIR/$rel"
        log "[DOWNLOAD NEW] $rel"
        ensure_local_folders "$(dirname "$local_path")"
        if run_retry proton-drive filesystem download "$remote_path" "$(dirname "$local_path")"; then
            if [ -f "$local_path" ]; then
                COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
                local lfp; lfp=$(get_local_fingerprint "$local_path")
                echo "file|${rel}|${lfp}|${NEW_REMOTE_FP[$rel]}" >> "$NEW_SNAPSHOT"
            elif [ "$DRY_RUN" = false ]; then
                COUNT_ERRORS=$((COUNT_ERRORS + 1))
            fi
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
        fi
    done

    for rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        [ -z "$rel" ] && continue
        local_path="$LOCAL_DIR/$rel"; [ -f "$local_path" ] || continue
        gauge_update "Delete local: $rel"
        log "[DELETED REMOTELY] $rel -> removing local"
        trash_local "$local_path" "$rel"
        COUNT_DELETED_LOCAL=$((COUNT_DELETED_LOCAL + 1))
    done

    for rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        [ -z "$rel" ] && continue
        [ -f "$LOCAL_DIR/$rel" ] && continue
        gauge_update "Trash remote: $rel"
        log "[DELETED LOCALLY] $rel -> trashing remote"
        if run_retry proton-drive filesystem trash "$REMOTE_DIR/$rel"; then
            COUNT_TRASHED_REMOTE=$((COUNT_TRASHED_REMOTE + 1))
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
        fi
    done

    for rel in "${DEL_LOCAL_FOLDERS[@]+"${DEL_LOCAL_FOLDERS[@]}"}"; do
        [ -z "$rel" ] && continue
        local_path="$LOCAL_DIR/$rel"; [ -d "$local_path" ] || continue
        gauge_update "Delete local folder: $rel"
        log "[DELETED REMOTELY] folder: $rel -> removing local"
        trash_local "$local_path" "$rel"
        COUNT_DELETED_LOCAL=$((COUNT_DELETED_LOCAL + 1))
    done

    for rel in "${TRASH_REMOTE_FOLDERS[@]+"${TRASH_REMOTE_FOLDERS[@]}"}"; do
        [ -z "$rel" ] && continue
        [ -d "$LOCAL_DIR/$rel" ] && continue
        gauge_update "Trash remote folder: $rel"
        log "[DELETED LOCALLY] folder: $rel -> trashing remote"
        if run_retry proton-drive filesystem trash "$REMOTE_DIR/$rel"; then
            COUNT_TRASHED_REMOTE=$((COUNT_TRASHED_REMOTE + 1))
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
        fi
    done

    # ---------- Finalize (snapshot handled by caller) ----------
    gauge_update "Finalizing..."
    rm -f "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"
    cleanup_old_trash

    {
        echo "=== Scan/transfer summary (pre-conflict) ==="
        echo "  Unchanged:       $COUNT_OK"
        echo "  First sync:      $COUNT_FIRST_SYNC"
        echo "  Uploaded:        $COUNT_UPLOADED"
        echo "  Downloaded:      $COUNT_DOWNLOADED"
        echo "  Moved (remote):  $COUNT_MOVED_REMOTE"
        echo "  Moved (local):   $COUNT_MOVED_LOCAL"
        echo "  Deleted local:   $COUNT_DELETED_LOCAL"
        echo "  Trashed remote:  $COUNT_TRASHED_REMOTE"
        echo "  Conflicts:       $COUNT_CONFLICTS (resolved after gauge)"
        echo "  Errors:          $COUNT_ERRORS"
        echo "=== Scan finished $(date) ==="
    } >> "$LOG_FILE"

    echo "XXX"; echo "100"; echo "Scan complete"; echo "XXX"
    return 0
}

# ============================================================
# TUI SCREENS
# ============================================================

tui_msgbox() {
    "$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "$1" \
        --msgbox "$2" 12 "$DIALOG_WIDTH"
}

tui_yesno() {
    "$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "$1" \
        --yesno "$2" 10 "$DIALOG_WIDTH"
}

# Preflight now only checks tools + re-verifies auth (login handled at startup).
preflight() {
    if ! command -v proton-drive >/dev/null 2>&1; then
        tui_msgbox "Error" "proton-drive command not found in PATH."
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        tui_msgbox "Error" "jq is required but not installed."
        return 1
    fi
    "$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Checking" \
        --infobox "Verifying Proton Drive authentication..." 5 "$DIALOG_WIDTH"
    if ! is_authenticated; then
        # Session may have expired mid-run — offer to log back in.
        if ! ensure_authenticated; then
            tui_msgbox "Not Authenticated" \
"Cannot access:\n  $REMOTE_DIR\n\nYou are not logged in."
            return 1
        fi
    fi
    return 0
}

run_sync_with_gauge() {
    local dry="$1"
    DRY_RUN="$dry"

    preflight || return

    if ! acquire_lock; then
        tui_msgbox "Locked" \
"Another sync appears to be running.\n\nLock: $LOCK_FILE\n\nIf you are sure it is not, remove it and try again."
        return
    fi

    LOG_FILE="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"
    LOCAL_TRASH="$STATE_DIR/trash/$(date +%Y%m%d-%H%M%S)"

    local title="Syncing"
    [ "$dry" = true ] && title="Syncing (DRY RUN)"

    local conflict_dump="$STATE_DIR/conflicts.tmp"
    > "$conflict_dump"

    sync_engine "$conflict_dump" | "$DIALOG" --backtitle "$DIALOG_BACKTITLE" \
        --title "$title" --gauge "Starting..." 10 "$DIALOG_WIDTH" 0

    if [ -s "$conflict_dump" ]; then
        CONFLICTS=(); CONFLICT_LOCAL_FP=(); CONFLICT_REMOTE_FP=()
        CONFLICT_PREV_L=(); CONFLICT_PREV_R=()
        while IFS='|' read -r rel lfp_s lfp_m rfp_s rfp_m pl_s pl_m pr_s pr_m; do
            CONFLICTS+=("$rel")
            CONFLICT_LOCAL_FP["$rel"]="${lfp_s}|${lfp_m}"
            CONFLICT_REMOTE_FP["$rel"]="${rfp_s}|${rfp_m}"
            CONFLICT_PREV_L["$rel"]="${pl_s}|${pl_m}"
            CONFLICT_PREV_R["$rel"]="${pr_s}|${pr_m}"
        done < "$conflict_dump"

        resolve_all_conflicts
    fi
    rm -f "$conflict_dump"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Snapshot not updated."
        rm -f "$NEW_SNAPSHOT"
    else
        mv "$NEW_SNAPSHOT" "$SNAPSHOT" 2>/dev/null || true
    fi

    release_lock

    local summary
    summary=$(printf "%s\n" \
        "Unchanged:       $COUNT_OK" \
        "First sync:      $COUNT_FIRST_SYNC" \
        "Uploaded:        $COUNT_UPLOADED" \
        "Downloaded:      $COUNT_DOWNLOADED" \
        "Moved (remote):  $COUNT_MOVED_REMOTE" \
        "Moved (local):   $COUNT_MOVED_LOCAL" \
        "Deleted local:   $COUNT_DELETED_LOCAL" \
        "Trashed remote:  $COUNT_TRASHED_REMOTE" \
        "Conflicts:       $COUNT_CONFLICTS" \
        "Errors:          $COUNT_ERRORS")

    [ "$dry" = true ] && summary=$'DRY RUN — no changes were made.\n\n'"$summary"

    "$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Sync Summary" \
        --msgbox "$summary" 16 "$DIALOG_WIDTH"
}

view_current_log() {
    local latest
    latest=$(ls -t "$LOG_DIR"/sync-*.log 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
        tui_msgbox "Logs" "No log files found yet."
        return
    fi
    "$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Log: $(basename "$latest")" \
        --textbox "$latest" "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
}

browse_logs() {
    local -a items=()
    local f n=0
    while IFS= read -r f; do
        n=$((n + 1))
        items+=("$f" "$(basename "$f")")
    done < <(ls -t "$LOG_DIR"/sync-*.log 2>/dev/null)

    if [ "$n" -eq 0 ]; then
        tui_msgbox "Logs" "No log files found."
        return
    fi

    local choice
    choice=$("$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Select Log" \
        --menu "Choose a log to view:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 12 \
        "${items[@]}" 3>&1 1>&2 2>&3) || return
    "$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "$(basename "$choice")" \
        --textbox "$choice" "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
}

show_settings() {
    local excl auth_status
    excl=$(printf "%s " "${EXCLUDE_PATTERNS[@]}")
    if is_authenticated; then
        auth_status="Logged in"
    else
        auth_status="NOT logged in"
    fi
    "$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Current Settings" --msgbox \
"Auth:        $auth_status
Local dir:   $LOCAL_DIR
Remote dir:  $REMOTE_DIR
State dir:   $STATE_DIR
Log dir:     $LOG_DIR

Trash keep:  $TRASH_RETENTION_DAYS days
Conflicts:   $CONFLICT_STRATEGY
Excludes:    $excl

Debug:       $DEBUG" 20 "$DIALOG_WIDTH"
}

edit_paths() {
    local new_local new_remote
    new_local=$("$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Local Directory" \
        --inputbox "Enter local sync directory:" 8 "$DIALOG_WIDTH" "$LOCAL_DIR" \
        3>&1 1>&2 2>&3) || return
    new_remote=$("$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Remote Directory" \
        --inputbox "Enter remote Proton Drive path:" 8 "$DIALOG_WIDTH" "$REMOTE_DIR" \
        3>&1 1>&2 2>&3) || return

    if [ ! -d "$new_local" ]; then
        if tui_yesno "Create Directory?" "Local directory does not exist:\n$new_local\n\nCreate it?"; then
            mkdir -p "$new_local" || { tui_msgbox "Error" "Could not create directory."; return; }
        else
            return
        fi
    fi
    LOCAL_DIR="$new_local"
    REMOTE_DIR="$new_remote"
    tui_msgbox "Updated" "Paths updated for this session:\n\nLocal:  $LOCAL_DIR\nRemote: $REMOTE_DIR\n\n(Edit the script header to persist.)"
}

set_conflict_strategy() {
    local choice
    choice=$("$DIALOG" --backtitle "$DIALOG_BACKTITLE" \
        --title "Conflict Strategy" \
        --menu "How should conflicts be handled?" 15 "$DIALOG_WIDTH" 5 \
        ask    "Ask me each time (interactive)" \
        local  "Always keep LOCAL" \
        remote "Always keep REMOTE" \
        both   "Always keep BOTH (.remote copy)" \
        skip   "Always skip (resolve manually later)" \
        3>&1 1>&2 2>&3) || return
    CONFLICT_STRATEGY="$choice"
    tui_msgbox "Conflict Strategy" "Conflicts will now be handled with: $CONFLICT_STRATEGY"
}

do_login() {
    perform_login
    if is_authenticated; then
        tui_msgbox "Authenticated" "You are logged in to Proton Drive."
    else
        tui_msgbox "Not Authenticated" "Login did not complete successfully."
    fi
}

do_logout() {
    if tui_yesno "Logout" "Log out of Proton Drive?"; then
        proton-drive auth logout >/dev/null 2>&1
        tui_msgbox "Logged Out" "You have been logged out."
    fi
}

recover_trash() {
    local -a items=()
    local d n=0
    while IFS= read -r d; do
        n=$((n + 1))
        items+=("$d" "$(basename "$d")")
    done < <(ls -td "$STATE_DIR"/trash/*/ 2>/dev/null)

    if [ "$n" -eq 0 ]; then
        tui_msgbox "Trash" "Local trash is empty."
        return
    fi

    local choice
    choice=$("$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Trash Sessions" \
        --menu "Select a trash session to inspect:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 12 \
        "${items[@]}" 3>&1 1>&2 2>&3) || return

    local contents
    contents=$(cd "$choice" && find . -type f 2>/dev/null | sed 's|^\./||')
    [ -z "$contents" ] && contents="(empty)"

    "$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Contents: $(basename "$choice")" \
        --msgbox "$contents\n\nLocation:\n$choice\n\nMove files back manually with your file manager." \
        "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
}

toggle_debug() {
    if [ "$DEBUG" = true ]; then
        DEBUG=false
    else
        DEBUG=true
    fi
    tui_msgbox "Debug Mode" "Debug logging is now: $DEBUG"
}

main_menu() {
    while true; do
        local choice
        choice=$("$DIALOG" --backtitle "$DIALOG_BACKTITLE" \
            --title "Main Menu" \
            --cancel-label "Quit" \
            --menu "Local:  $LOCAL_DIR\nRemote: $REMOTE_DIR\n\nChoose an action:" \
            "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 11 \
            sync     "Run sync now" \
            dryrun   "Preview sync (dry run)" \
            conflict "Set conflict strategy (currently: $CONFLICT_STRATEGY)" \
            log      "View latest sync log" \
            logs     "Browse all sync logs" \
            trash    "Recover deleted files (local trash)" \
            paths    "Change local/remote directories" \
            settings "View current settings" \
            debug    "Toggle debug logging" \
            login    "Proton Drive login" \
            logout   "Proton Drive logout" \
            3>&1 1>&2 2>&3)

        local rc=$?
        if [ "$rc" -ne 0 ]; then
            break
        fi

        case "$choice" in
            sync)     run_sync_with_gauge false ;;
            dryrun)   run_sync_with_gauge true ;;
            conflict) set_conflict_strategy ;;
            log)      view_current_log ;;
            logs)     browse_logs ;;
            trash)    recover_trash ;;
            paths)    edit_paths ;;
            settings) show_settings ;;
            debug)    toggle_debug ;;
            login)    do_login ;;
            logout)   do_logout ;;
        esac
    done
    clear
    echo "Goodbye."
}

# ============================================================
# ENTRY POINT
# ============================================================

if [ ! -x "$DIALOG" ]; then
    echo "ERROR: $DIALOG not found. Install it with:"
    echo "  sudo apt install dialog     # Debian/Ubuntu"
    echo "  sudo dnf install dialog     # Fedora"
    exit 1
fi

if ! command -v proton-drive >/dev/null 2>&1; then
    echo "ERROR: 'proton-drive' command not found in PATH."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is required but not installed."
    exit 1
fi

# ---- Startup authentication check ----
# Verify the user is logged in before showing the menu. If not,
# kick off the login flow immediately (retrying until success or
# the user declines).
"$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Please Wait" \
    --infobox "Checking Proton Drive authentication..." 5 "$DIALOG_WIDTH"

if ! ensure_authenticated; then
    clear
    echo "Proton Drive authentication is required to continue."
    echo "Exiting."
    exit 1
fi

main_menu
