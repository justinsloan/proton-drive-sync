#!/bin/bash
set -uo pipefail

# ============================================================
# DEFAULT SETTINGS
# Settings saved from the Settings menu (in $CONFIG_FILE) override these,
# and PROTON_SYNC_* environment variables override both.
# ============================================================

LOCAL_DIR="$HOME/Proton Drive/root"
REMOTE_DIR="/my-files"
CONFLICT_STRATEGY=ask          # ask | local | remote | both | skip
SYNC_JOBS=4                    # transfers / folder listings at the same time
TRASH_RETENTION_DAYS=30
LOG_RETENTION_DAYS=90
DELETE_CONFIRM_COUNT=50        # confirm before deleting more files than this (0 = off)
DELETE_CONFIRM_PERCENT=25      # ...or more than this % of synced files (0 = off)
DEBUG=false

EXCLUDE_PATTERNS=(
    "*.tmp"
    "*.swp"
    "*.partial"
    ".DS_Store"
    "Thumbs.db"
    ".git"
    ".proton-sync"
)

# ============================================================
# FILE LOCATIONS
# ============================================================

CONFIG_FILE="${PROTON_SYNC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/proton-sync/config}"
STATE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/proton-sync"
LOCK_FILE="$STATE_ROOT/sync.lock"
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")

# Field separator for manifests, snapshot and conflict list. The ASCII unit
# separator can't realistically appear in a filename, unlike "|".
SEP=$'\x1f'

# ============================================================
# SETTINGS FILE
# ============================================================

SETTING_KEYS=(LOCAL_DIR REMOTE_DIR CONFLICT_STRATEGY SYNC_JOBS
    TRASH_RETENTION_DAYS LOG_RETENTION_DAYS
    DELETE_CONFIRM_COUNT DELETE_CONFIRM_PERCENT DEBUG)

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    # shellcheck source=/dev/null
    if ! source "$CONFIG_FILE"; then
        echo "WARNING: could not read settings from $CONFIG_FILE" >&2
    fi
}

# Keep a copy of the saved (not environment-overridden) values, so saving
# from the Settings menu never writes a temporary override to the file.
remember_saved_settings() {
    local key
    for key in "${SETTING_KEYS[@]}"; do
        printf -v "CFG_$key" '%s' "${!key}"
    done
    CFG_EXCLUDE_PATTERNS=("${EXCLUDE_PATTERNS[@]}")
}

save_config() {
    local key var tmp="$CONFIG_FILE.tmp"
    mkdir -p "$(dirname "$CONFIG_FILE")" || return 1
    {
        echo "# Proton Drive Sync settings, written by proton-sync-tui.sh."
        echo "# Edit with the Settings menu, or by hand (this file is bash)."
        for key in "${SETTING_KEYS[@]}"; do
            var="CFG_$key"
            printf '%s=%q\n' "$key" "${!var}"
        done
        printf 'EXCLUDE_PATTERNS=('
        printf ' %q' "${CFG_EXCLUDE_PATTERNS[@]}"
        printf ' )\n'
    } > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

# set_setting KEY VALUE — change a setting now and save it.
set_setting() {
    printf -v "$1" '%s' "$2"
    printf -v "CFG_$1" '%s' "$2"
    save_config
}

apply_env_overrides() {
    LOCAL_DIR="${PROTON_SYNC_LOCAL_DIR:-$LOCAL_DIR}"
    REMOTE_DIR="${PROTON_SYNC_REMOTE_DIR:-$REMOTE_DIR}"
    CONFLICT_STRATEGY="${PROTON_SYNC_CONFLICT:-$CONFLICT_STRATEGY}"
    SYNC_JOBS="${PROTON_SYNC_JOBS:-$SYNC_JOBS}"
    DEBUG="${PROTON_SYNC_DEBUG:-$DEBUG}"
}

is_number() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

validate_settings() {
    is_number "$SYNC_JOBS" && [ "$SYNC_JOBS" -gt 0 ] || SYNC_JOBS=4
    is_number "$TRASH_RETENTION_DAYS" || TRASH_RETENTION_DAYS=30
    is_number "$LOG_RETENTION_DAYS" || LOG_RETENTION_DAYS=90
    is_number "$DELETE_CONFIRM_COUNT" || DELETE_CONFIRM_COUNT=50
    is_number "$DELETE_CONFIRM_PERCENT" || DELETE_CONFIRM_PERCENT=25
    case "$CONFLICT_STRATEGY" in ask|local|remote|both|skip) ;; *) CONFLICT_STRATEGY=ask ;; esac
    [ "$DEBUG" = true ] || DEBUG=false
    [ "$LOCAL_DIR" != "/" ] && LOCAL_DIR="${LOCAL_DIR%/}"
    [ "$REMOTE_DIR" != "/" ] && REMOTE_DIR="${REMOTE_DIR%/}"
}

# ============================================================
# PER-FOLDER-PAIR STATE
# Sync history, logs and local trash are kept separately for each
# local/remote folder pair, so switching folders never compares one
# folder against another folder's history.
# ============================================================

pair_id() {
    printf '%s\n%s' "$1" "$2" | sha256sum | cut -c1-12
}

init_state_paths() {
    STATE_DIR="$STATE_ROOT/pairs/$(pair_id "$LOCAL_DIR" "$REMOTE_DIR")"
    SNAPSHOT="$STATE_DIR/snapshot"
    NEW_SNAPSHOT="$STATE_DIR/snapshot.new"
    LOCAL_MANIFEST="$STATE_DIR/local_manifest"
    REMOTE_MANIFEST="$STATE_DIR/remote_manifest"
    JOB_RESULTS="$STATE_DIR/job_results"
    PLAN_FILE="$STATE_DIR/plan"
    PENDING_DELETES="$STATE_DIR/pending_deletions"
    STATUS_FILE="$STATE_DIR/last_status"
    LOG_DIR="$STATE_DIR/logs"
    TRASH_DIR="$STATE_DIR/trash"
    LOCAL_TRASH="$TRASH_DIR/$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"

    mkdir -p "$STATE_DIR" "$LOG_DIR"
    printf 'Local:  %s\nProton: %s\n' "$LOCAL_DIR" "$REMOTE_DIR" > "$STATE_DIR/folders"
    migrate_legacy_state
    touch "$SNAPSHOT"
}

# Older versions kept one snapshot, log folder and trash directly in
# $STATE_ROOT. Hand them to the current folder pair if it has no history.
migrate_legacy_state() {
    [ -f "$STATE_ROOT/snapshot" ] || return 0
    [ -s "$SNAPSHOT" ] && return 0
    mv "$STATE_ROOT/snapshot" "$SNAPSHOT" || return 0
    local f
    for f in "$STATE_ROOT"/logs/*; do
        [ -e "$f" ] && mv "$f" "$LOG_DIR/"
    done
    if [ -d "$STATE_ROOT/trash" ]; then
        mkdir -p "$TRASH_DIR"
        for f in "$STATE_ROOT"/trash/*; do
            [ -e "$f" ] && mv "$f" "$TRASH_DIR/"
        done
        rmdir "$STATE_ROOT/trash" 2>/dev/null
    fi
    rmdir "$STATE_ROOT/logs" 2>/dev/null
    rm -f "$STATE_ROOT/local_manifest" "$STATE_ROOT/remote_manifest" \
          "$STATE_ROOT/snapshot.new" "$STATE_ROOT/conflicts.tmp"
    log "Moved sync history from an earlier version into $STATE_DIR"
}

# Deletion safety limit as text, e.g. "more than 50 files or 25%".
delete_limit_text() {
    local -a parts=()
    [ "$DELETE_CONFIRM_COUNT" -gt 0 ] && parts+=("more than $DELETE_CONFIRM_COUNT files")
    [ "$DELETE_CONFIRM_PERCENT" -gt 0 ] && parts+=("more than $DELETE_CONFIRM_PERCENT% of files")
    if [ "${#parts[@]}" -eq 0 ]; then
        echo "off"
    elif [ "${#parts[@]}" -eq 1 ]; then
        echo "${parts[0]}"
    else
        echo "${parts[0]} or ${parts[1]}"
    fi
}

# PROTON_SYNC_DRY_RUN=true forces every sync (menu or headless) to be a dry run.
FORCE_DRY_RUN="${PROTON_SYNC_DRY_RUN:-false}"
DRY_RUN="$FORCE_DRY_RUN"
# Skip the large-deletion confirmation (--allow-deletes).
ALLOW_DELETES="${PROTON_SYNC_ALLOW_DELETES:-false}"
DELETE_WARNING=false

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

# Queued file transfers (run in parallel by run_job_queue)
declare -a JOB_QUEUE=()
declare -A JOB_LFP=() JOB_RFP=() JOB_PREV_L=() JOB_PREV_R=()
ABORT_REASON=""
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
# SNAPSHOT RECORDS
# ============================================================

# snap_file REL LOCAL_FP REMOTE_FP   (fingerprints are "size|mtime")
snap_file() {
    printf 'file%s%s%s%s%s%s\n' "$SEP" "$1" "$SEP" "$2" "$SEP" "$3" >> "$NEW_SNAPSHOT"
}

snap_folder() {
    printf 'folder%s%s\n' "$SEP" "$1" >> "$NEW_SNAPSHOT"
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

cleanup_old_logs() {
    [ "$DRY_RUN" = true ] && return 0
    [ "$LOG_RETENTION_DAYS" -gt 0 ] || return 0
    find "$LOG_DIR" -maxdepth 1 -type f -name 'sync-*.log' \
        -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

cleanup_old_trash() {
    [ "$DRY_RUN" = true ] && return 0
    [ "$TRASH_RETENTION_DAYS" -gt 0 ] || return 0
    if [ -d "$TRASH_DIR" ]; then
        find "$TRASH_DIR" -mindepth 1 -maxdepth 1 -type d \
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

# list_remote_dir PREFIX
# Print manifest lines for the direct children of $REMOTE_DIR/PREFIX:
#   folder<SEP>rel<SEP><SEP>   and   file<SEP>rel<SEP>size<SEP>mtime
# Returns 1 if the folder couldn't be listed after 3 attempts.
list_remote_dir() {
    local prefix="$1"
    local remote_path="$REMOTE_DIR" json="" attempt ok=false
    [ -n "$prefix" ] && remote_path="$REMOTE_DIR/$prefix"

    for attempt in 1 2 3; do
        if json=$(proton-drive filesystem list "$remote_path" -j 2>>"$LOG_FILE"); then
            ok=true
            break
        fi
        log "[RETRY $attempt/3] Could not list $remote_path"
        [ "$attempt" -lt 3 ] && sleep $((attempt * 2))
    done
    if [ "$ok" = false ]; then
        log "[ERROR] Giving up listing $remote_path"
        return 1
    fi

    # Timestamps in the usual "YYYY-MM-DDTHH:MM:SS[.fff]Z" form are converted
    # to epoch seconds here (prefixed "@"); anything else goes to `date -d`
    # below, exactly as before, so existing snapshots stay valid.
    printf '%s' "$json" | jq -r '
        .[] |
        (if .type | type == "object" then .type.value else .type end) as $type |
        (if .name | type == "object" then .name.value else .name end) as $name |
        (if .mediaType | type == "object" then .mediaType.value else (.mediaType // "") end) as $media |
        (.activeRevision.value.claimedSize // 0) as $size |
        (.activeRevision.value.claimedModificationTime // "") as $mtime |
        (if ($mtime | type) == "string"
            and ($mtime | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))
         then "@" + ($mtime | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | floor | tostring)
         else $mtime end) as $mt |
        if ($name | test("\n")) then "skip\u001f\($name | gsub("\n"; "\\n"))"
        else "\($type)\u001f\($name)\u001f\($media)\u001f\($size)\u001f\($mt)" end
    ' | \
    while IFS="$SEP" read -r type name media size mtime; do
        local rel_path
        if [ -z "$prefix" ]; then
            rel_path="$name"
        else
            rel_path="$prefix/$name"
        fi

        if [ "$type" = "skip" ]; then
            log "[SKIP] remote name contains a line break: $rel_path"
            continue
        fi

        if is_excluded "$rel_path"; then
            continue
        fi

        if [ "$type" = "folder" ]; then
            printf 'folder%s%s%s%s\n' "$SEP" "$rel_path" "$SEP" "$SEP"
        else
            if [ "$media" = "application/vnd.proton.doc" ]; then
                log "[SKIP PROTON DOC] $rel_path"
                continue
            fi
            local mtime_epoch=0
            if [[ "$mtime" == @* ]]; then
                mtime_epoch="${mtime#@}"
            elif [ -n "$mtime" ]; then
                mtime_epoch=$(date -d "$mtime" +%s 2>/dev/null || echo 0)
            fi
            printf 'file%s%s%s%s%s%s\n' "$SEP" "$rel_path" "$SEP" "$size" "$SEP" "$mtime_epoch"
        fi
    done
}

# list_remote_dirs OUT_DIR PREFIX...
# List several remote folders in parallel (up to $SYNC_JOBS at a time).
# Folder i's lines go to OUT_DIR/i.out; a failed listing leaves OUT_DIR/i.failed.
# Runs in a subshell so `wait` only sees these jobs.
list_remote_dirs() {
    local out_dir="$1"; shift
    (
        local i=0 running=0 prefix
        for prefix in "$@"; do
            if [ "$running" -ge "$SYNC_JOBS" ]; then
                wait -n; running=$((running - 1))
            fi
            { list_remote_dir "$prefix" > "$out_dir/$i.out" || : > "$out_dir/$i.failed"; } &
            running=$((running + 1)); i=$((i + 1))
        done
        wait
    )
}

# Print the manifest for the whole remote tree, listing each level of
# folders in parallel. Returns 1 if any folder couldn't be listed, since a
# missing listing would make its files look deleted remotely.
list_remote_tree() {
    local tmp level_dir f type rel _rest n=0 failed=0
    tmp=$(mktemp -d "$STATE_DIR/list.XXXXXX") || return 1
    local -a level=("") next=()
    while [ "${#level[@]}" -gt 0 ]; do
        n=$((n + 1))
        level_dir="$tmp/$n"
        mkdir "$level_dir"
        list_remote_dirs "$level_dir" "${level[@]}"
        if compgen -G "$level_dir/*.failed" >/dev/null; then
            failed=1
            break
        fi
        next=()
        for f in "$level_dir"/*.out; do
            [ -f "$f" ] || continue
            cat "$f"
            while IFS="$SEP" read -r type rel _rest; do
                [ "$type" = "folder" ] && next+=("$rel")
            done < "$f"
        done
        level=("${next[@]+"${next[@]}"}")
    done
    rm -rf -- "${tmp:?}"
    return "$failed"
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
    while IFS="$SEP" read -r type rel _rest; do
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
    local line type rel f3 f4 f5 f6 lfp rfp
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" == *"$SEP"* ]]; then
            IFS="$SEP" read -r type rel lfp rfp <<< "$line"
        else
            # Snapshot written by an older version, separated by "|"
            IFS='|' read -r type rel f3 f4 f5 f6 <<< "$line"
            lfp="${f3}|${f4}"; rfp="${f5}|${f6}"
        fi
        SNAPSHOT_SEEN["$rel"]=1
        if [ "$type" = "file" ]; then
            SNAPSHOT_LOCAL_FP["$rel"]="$lfp"
            SNAPSHOT_REMOTE_FP["$rel"]="$rfp"
        fi
    done < "$SNAPSHOT"
}

load_manifests_to_memory() {
    while IFS="$SEP" read -r type rel _size _mtime; do
        LOCAL_ITEMS["${type}|${rel}"]=1
    done < "$LOCAL_MANIFEST"
    while IFS="$SEP" read -r type rel size mtime; do
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
        AUTH_STATE=in
        return 0
    fi
    AUTH_STATE=out

    local ans
    while true; do
        if [ -z "$UI_TOOL" ]; then
            echo "You are not logged in to Proton Drive."
            read -rp "Log in now? [Y/n] " ans
            case "$ans" in [nN]*) return 1 ;; esac
        else
            ui_yesno "Not Logged In" "You're not logged in to Proton Drive.

Log in now? (Choosing Cancel closes the app.)" "Log in" "Cancel" || return 1
        fi
        perform_login

        if is_authenticated; then
            AUTH_STATE=in
            if [ -n "$UI_TOOL" ]; then
                ui_msgbox "Logged In" "You're logged in to Proton Drive."
            else
                echo "Successfully logged in."
            fi
            return 0
        fi

        if [ -n "$UI_TOOL" ]; then
            ui_yesno "Login Failed" "Still can't open $REMOTE_DIR on Proton Drive.

The login may not have finished. Try again?" "Try again" "Cancel" || return 1
        else
            read -rp "Login failed. Try again? [Y/n] " ans
            case "$ans" in [nN]*) return 1 ;; esac
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
        snap_file "${rel}" "${lfp}" "${rfp}"
    else
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
        plan failed "Upload failed (conflict): $rel"
        snap_file "${rel}" "${CONFLICT_PREV_L[$rel]}" "${CONFLICT_PREV_R[$rel]}"
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
        snap_file "${rel}" "${lfp}" "${CONFLICT_REMOTE_FP[$rel]}"
    else
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
        plan failed "Download failed (conflict): $rel"
        snap_file "${rel}" "${CONFLICT_PREV_L[$rel]}" "${CONFLICT_PREV_R[$rel]}"
    fi
}

# Keep both: save the remote version beside the local file as a ".remote"
# copy, then upload the local file so both sides agree on the original name.
# The copy is uploaded as a new file on the next sync.
resolve_keep_both() {
    local rel="$1"
    local remote_path="$REMOTE_DIR/$rel"
    local dir name stem copy_name copy_rel n=1
    dir=$(dirname "$rel")
    name=$(basename "$rel")
    stem="${name%.*}"

    # Pick a name that doesn't exist yet: a.remote.txt, a.remote-2.txt, ...
    while true; do
        local tag=".remote"
        [ "$n" -gt 1 ] && tag=".remote-$n"
        if [ -z "$stem" ] || [ "$stem" = "$name" ]; then
            copy_name="${name}${tag}"
        else
            copy_name="${stem}${tag}.${name##*.}"
        fi
        if [ "$dir" = "." ]; then copy_rel="$copy_name"; else copy_rel="$dir/$copy_name"; fi
        [ -e "$LOCAL_DIR/$copy_rel" ] || break
        n=$((n + 1))
    done

    log "[RESOLVE keep-both] $rel -> saving remote version as $copy_rel"
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] download $remote_path -> $LOCAL_DIR/$copy_rel"
    else
        # Download into a scratch folder so the local file is never overwritten.
        local tmp
        tmp=$(mktemp -d "$STATE_DIR/download.XXXXXX")
        if ! retry proton-drive filesystem download "$remote_path" "$tmp" \
            || [ ! -f "$tmp/$name" ] \
            || ! mv "$tmp/$name" "$LOCAL_DIR/$copy_rel"; then
            rm -rf -- "${tmp:?}"
            log "[ERROR] Could not save remote copy of $rel; leaving conflict unresolved"
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Couldn't save the Proton copy (conflict): $rel"
            snap_file "$rel" "${CONFLICT_PREV_L[$rel]}" "${CONFLICT_PREV_R[$rel]}"
            return
        fi
        rm -rf -- "${tmp:?}"
        COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
    fi

    resolve_keep_local "$rel"
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
            snap_file "${rel}" "${CONFLICT_PREV_L[$rel]}" "${CONFLICT_PREV_R[$rel]}"
            ;;
    esac
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

        resolve_conflict_interactive "$rel"
        choice="$CONFLICT_CHOICE"

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
# PARALLEL FILE TRANSFERS
# ============================================================

# queue_job KIND REL LOCAL_FP REMOTE_FP PREV_LOCAL_FP PREV_REMOTE_FP
# KIND: up_mod | down_mod | up_new | down_new | trash
queue_job() {
    JOB_QUEUE+=("$1${SEP}$2")
    JOB_LFP["$2"]="$3"; JOB_RFP["$2"]="$4"
    JOB_PREV_L["$2"]="$5"; JOB_PREV_R["$2"]="$6"
}

# Runs in a background job: do the network operation, report ok/fail.
run_one_job() {
    local kind="$1" rel="$2" rc=0
    local local_path="$LOCAL_DIR/$rel" remote_path="$REMOTE_DIR/$rel"
    case "$kind" in
        up_mod)   run_retry proton-drive filesystem upload -f replace "$local_path" "$(dirname "$remote_path")" || rc=1 ;;
        up_new)   run_retry proton-drive filesystem upload "$local_path" "$(dirname "$remote_path")" || rc=1 ;;
        down_mod) run_retry proton-drive filesystem download -f replace "$remote_path" "$(dirname "$local_path")" || rc=1 ;;
        down_new) run_retry proton-drive filesystem download "$remote_path" "$(dirname "$local_path")" || rc=1 ;;
        trash)    run_retry proton-drive filesystem trash "$remote_path" || rc=1 ;;
    esac
    local status=ok
    [ "$rc" -ne 0 ] && status=fail
    # One short line per append, so concurrent writes don't interleave.
    printf '%s\n' "${kind}${SEP}${rel}${SEP}${status}" >> "$JOB_RESULTS"
}

# Run JOB_QUEUE with up to $SYNC_JOBS jobs at a time. The pool runs in a
# subshell so `wait` only sees these jobs (not the progress dialog).
run_job_queue() {
    : > "$JOB_RESULTS"
    [ "${#JOB_QUEUE[@]}" -eq 0 ] && return 0
    (
        local spec kind rel running=0 started=0 total="${#JOB_QUEUE[@]}"
        for spec in "${JOB_QUEUE[@]}"; do
            kind="${spec%%"$SEP"*}"; rel="${spec#*"$SEP"}"
            if [ "$running" -ge "$SYNC_JOBS" ]; then
                wait -n; running=$((running - 1))
            fi
            started=$((started + 1))
            gauge $((45 + 50 * started / total)) "Transferring $started of $total: $rel"
            run_one_job "$kind" "$rel" &
            running=$((running + 1))
        done
        wait
    )
}

# Update counters and the snapshot from the job results. Uploaded files'
# new remote fingerprints are read by listing each affected folder once,
# instead of one `info` call per file.
process_job_results() {
    local kind rel status lfp
    local -a refetch=()
    [ -s "$JOB_RESULTS" ] || return 0

    while IFS="$SEP" read -r kind rel status; do
        local local_path="$LOCAL_DIR/$rel"
        if [ "$status" != ok ]; then
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            case "$kind" in
                up_*)   plan failed "Upload failed: $rel" ;;
                down_*) plan failed "Download failed: $rel" ;;
                trash)  plan failed "Deleting on Proton failed: $rel" ;;
            esac
            case "$kind" in
                up_mod|down_mod) snap_file "$rel" "${JOB_PREV_L[$rel]}" "${JOB_PREV_R[$rel]}" ;;
            esac
            continue
        fi
        case "$kind" in
            up_mod|up_new)
                COUNT_UPLOADED=$((COUNT_UPLOADED + 1))
                if [ "$DRY_RUN" = true ]; then
                    [ "$kind" = up_mod ] && snap_file "$rel" "${JOB_LFP[$rel]}" "${JOB_RFP[$rel]}"
                else
                    refetch+=("$kind${SEP}$rel")
                fi
                ;;
            down_mod)
                COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
                lfp="${JOB_LFP[$rel]}"
                [ "$DRY_RUN" = false ] && lfp=$(get_local_fingerprint "$local_path")
                snap_file "$rel" "$lfp" "${JOB_RFP[$rel]}"
                ;;
            down_new)
                if [ -f "$local_path" ]; then
                    COUNT_DOWNLOADED=$((COUNT_DOWNLOADED + 1))
                    snap_file "$rel" "$(get_local_fingerprint "$local_path")" "${JOB_RFP[$rel]}"
                elif [ "$DRY_RUN" = false ]; then
                    COUNT_ERRORS=$((COUNT_ERRORS + 1))
                    plan failed "Download failed: $rel"
                fi
                ;;
            trash)
                COUNT_TRASHED_REMOTE=$((COUNT_TRASHED_REMOTE + 1))
                ;;
        esac
    done < "$JOB_RESULTS"
    rm -f "$JOB_RESULTS"

    [ "${#refetch[@]}" -eq 0 ] && return 0

    # List each parent folder of an uploaded file once, in parallel.
    local -A dir_seen=() remote_fp=()
    local -a dirs=()
    local spec dir tmp f type size mtime
    for spec in "${refetch[@]}"; do
        rel="${spec#*"$SEP"}"
        dir=$(dirname "$rel"); [ "$dir" = "." ] && dir=""
        if [ -z "${dir_seen[x$dir]+x}" ]; then
            dir_seen["x$dir"]=1
            dirs+=("$dir")
        fi
    done
    tmp=$(mktemp -d "$STATE_DIR/list.XXXXXX") || return 0
    list_remote_dirs "$tmp" "${dirs[@]}"
    for f in "$tmp"/*.out; do
        [ -f "$f" ] || continue
        while IFS="$SEP" read -r type rel size mtime; do
            [ "$type" = "file" ] && remote_fp["$rel"]="${size}|${mtime}"
        done < "$f"
    done
    rm -rf -- "${tmp:?}"

    for spec in "${refetch[@]}"; do
        kind="${spec%%"$SEP"*}"; rel="${spec#*"$SEP"}"
        lfp=$(get_local_fingerprint "$LOCAL_DIR/$rel")
        if [ "$kind" = up_mod ]; then
            snap_file "$rel" "$lfp" "${remote_fp[$rel]:-}"
        elif [ -n "${remote_fp[$rel]:-}" ]; then
            snap_file "$rel" "$lfp" "${remote_fp[$rel]}"
        fi
    done
}

# ============================================================
# PROGRESS AND PLAN
# ============================================================

# gauge PERCENT MESSAGE — update the progress bar (stdout feeds the dialog;
# in headless mode it goes to /dev/null).
gauge() {
    printf 'XXX\n%s\n%s\nXXX\n' "$1" "$2"
}

# plan CATEGORY TEXT — record one action for the preview and the summary.
# Categories: up down move del_local del_remote conflict folder failed
plan() {
    printf '%s\t%s\n' "$1" "$2" >> "$PLAN_FILE"
}

plan_count() {
    grep -c "^$1"$'\t' "$PLAN_FILE" 2>/dev/null || true
}

# What happens to a conflict under the current strategy (for the preview).
conflict_note() {
    case "$CONFLICT_STRATEGY" in
        ask)    echo "you'll be asked" ;;
        local)  echo "will keep the local version" ;;
        remote) echo "will keep the Proton version" ;;
        both)   echo "will keep both" ;;
        skip)   echo "will be skipped" ;;
    esac
}

# Human-readable plan: counts, then one section per kind of change.
format_plan() {
    local -a parts=()
    local n
    n=$(plan_count up);         [ "$n" -gt 0 ] && parts+=("$n to upload")
    n=$(plan_count down);       [ "$n" -gt 0 ] && parts+=("$n to download")
    n=$(plan_count move);       [ "$n" -gt 0 ] && parts+=("$n to move")
    n=$(( $(plan_count del_local) + $(plan_count del_remote) ))
                                [ "$n" -gt 0 ] && parts+=("$n to delete")
    n=$(plan_count conflict);   [ "$n" -gt 0 ] && parts+=("$n conflicts")
    n=$(plan_count failed);     [ "$n" -gt 0 ] && parts+=("$n problems")
    if [ "${#parts[@]}" -eq 0 ]; then
        echo "No changes: everything is already in sync."
    else
        local IFS=,
        echo "${parts[*]}" | sed 's/,/, /g'
    fi
    if [ "$DELETE_WARNING" = true ]; then
        echo
        echo "Note: this is more deletions than your safety limit, so a real"
        echo "sync will ask you to confirm before deleting anything."
    fi
    awk -F'\t' '
        BEGIN {
            n = split("up down move del_local del_remote conflict folder failed", order, " ")
            title["up"] = "Upload to Proton"
            title["down"] = "Download from Proton"
            title["move"] = "Move or rename"
            title["del_local"] = "Delete locally, kept in the local trash"
            title["del_remote"] = "Delete on Proton, moved to Proton trash"
            title["conflict"] = "Conflicts, changed on both sides"
            title["folder"] = "New folders"
            title["failed"] = "Problems"
        }
        { cat = $1; sub(/^[^\t]*\t/, ""); items[cat] = items[cat] "  " $0 "\n"; count[cat]++ }
        END {
            for (i = 1; i <= n; i++) {
                c = order[i]
                if (count[c]) printf "\n%s (%d)\n%s", title[c], count[c], items[c]
            }
        }' "$PLAN_FILE"
}

# Short one-line result, used in the status line, log list and cron log.
result_text() {
    local -a parts=()
    [ "$COUNT_UPLOADED" -gt 0 ] && parts+=("$COUNT_UPLOADED up")
    [ "$COUNT_DOWNLOADED" -gt 0 ] && parts+=("$COUNT_DOWNLOADED down")
    local moved=$((COUNT_MOVED_REMOTE + COUNT_MOVED_LOCAL))
    [ "$moved" -gt 0 ] && parts+=("$moved moved")
    local deleted=$((COUNT_DELETED_LOCAL + COUNT_TRASHED_REMOTE))
    [ "$deleted" -gt 0 ] && parts+=("$deleted deleted")
    [ "$COUNT_CONFLICTS" -gt 0 ] && parts+=("$COUNT_CONFLICTS conflicts")
    [ "${#parts[@]}" -eq 0 ] && parts+=("no changes")
    if [ "$COUNT_ERRORS" -gt 0 ]; then
        parts+=("$COUNT_ERRORS errors")
    else
        parts+=("no errors")
    fi
    local IFS=,
    echo "${parts[*]}" | sed 's/,/, /g'
}

# record_result TEXT — note the outcome in the log and, for real syncs,
# in the status file shown on the main menu.
record_result() {
    log "RESULT: $1"
    [ "$DRY_RUN" = true ] && return 0
    printf '%s\t%s\n' "$(date +%s)" "$1" > "$STATUS_FILE"
}

# True if deleting N files needs the user's confirmation.
deletions_exceed_limit() {
    local n="$1" total="${#SNAPSHOT_LOCAL_FP[@]}"
    [ "$n" -eq 0 ] && return 1
    if [ "$DELETE_CONFIRM_COUNT" -gt 0 ] && [ "$n" -gt "$DELETE_CONFIRM_COUNT" ]; then
        return 0
    fi
    if [ "$DELETE_CONFIRM_PERCENT" -gt 0 ] && [ "$n" -ge 5 ] \
        && [ $((n * 100)) -gt $((DELETE_CONFIRM_PERCENT * total)) ]; then
        return 0
    fi
    return 1
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
    JOB_QUEUE=(); JOB_LFP=(); JOB_RFP=(); JOB_PREV_L=(); JOB_PREV_R=()
    ABORT_REASON=""
    DELETE_WARNING=false
    : > "$PLAN_FILE"
    rm -f "$PENDING_DELETES"
    COUNT_OK=0; COUNT_UPLOADED=0; COUNT_DOWNLOADED=0
    COUNT_MOVED_REMOTE=0; COUNT_MOVED_LOCAL=0
    COUNT_DELETED_LOCAL=0; COUNT_TRASHED_REMOTE=0
    COUNT_CONFLICTS=0; COUNT_ERRORS=0; COUNT_FIRST_SYNC=0

    log "=== Sync started $(date) ==="
    log "Local:  $LOCAL_DIR"
    log "Proton: $REMOTE_DIR"
    [ "$DRY_RUN" = true ] && log "=== DRY RUN MODE ==="

    gauge 2 "Scanning local files..."
    # One find pass collects type, size and mtime for every local item
    # (instead of a stat per file) and skips excluded names without
    # descending into them. Records are "path<TAB>type size mtime".
    local -a prune=()
    local pattern
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        prune+=(-name "$pattern" -o)
    done
    local -a skip_excluded=()
    if [ "${#prune[@]}" -gt 0 ]; then
        unset 'prune[${#prune[@]}-1]'
        skip_excluded=(\( "${prune[@]}" \) -prune -o)
    fi
    local rec meta ftype fsize fmtime
    find "$LOCAL_DIR" -mindepth 1 "${skip_excluded[@]}" \
        -printf '%P\t%Y %s %T@\0' | sort -z | \
        while IFS= read -r -d '' rec; do
            rel="${rec%$'\t'*}"
            meta="${rec##*$'\t'}"
            if [[ "$rel" == *$'\n'* ]]; then
                log "[SKIP] local name contains a line break: ${rel//$'\n'/\\n}"
                continue
            fi
            ftype="${meta%% *}"; meta="${meta#* }"
            fsize="${meta%% *}"; fmtime="${meta#* }"; fmtime="${fmtime%.*}"
            case "$ftype" in
                d) printf 'folder%s%s\n' "$SEP" "$rel" ;;
                f) printf 'file%s%s%s%s%s%s\n' "$SEP" "$rel" "$SEP" "$fsize" "$SEP" "$fmtime" ;;
            esac
        done > "$LOCAL_MANIFEST"

    gauge 5 "Listing folders on Proton Drive..."
    if ! list_remote_tree > "$REMOTE_MANIFEST.unsorted"; then
        rm -f "$REMOTE_MANIFEST.unsorted"
        ABORT_REASON="Could not list one or more remote folders (see log). Stopped so their files aren't treated as deleted."
        log "[FATAL] $ABORT_REASON"
        gauge 100 "Stopped: a Proton folder couldn't be listed"
        return 1
    fi
    sort "$REMOTE_MANIFEST.unsorted" > "$REMOTE_MANIFEST"
    rm -f "$REMOTE_MANIFEST.unsorted"

    if ! check_remote_manifest_sane; then
        ABORT_REASON="Remote listing came back empty but sync history exists. If the remote really is empty, remove $SNAPSHOT to reset."
        log "[FATAL] $ABORT_REASON"
        gauge 100 "Stopped: unsafe remote state"
        return 1
    fi

    load_snapshot
    load_manifests_to_memory
    build_remote_dir_cache

    # Progress: comparing takes 10-40% of the bar, transfers 45-95%.
    local compare_total compare_done=0
    compare_total=$(( $(wc -l < "$LOCAL_MANIFEST") + $(wc -l < "$REMOTE_MANIFEST") ))
    [ "$compare_total" -eq 0 ] && compare_total=1

    # ---------- PHASE 2: local items ----------
    while IFS="$SEP" read -r type rel lsize lmtime; do
        compare_done=$((compare_done + 1))
        (( compare_done % 50 == 0 )) && gauge $((10 + 30 * compare_done / compare_total)) \
            "Comparing files ($compare_done of $compare_total)..."
        remote_path="$REMOTE_DIR/$rel"
        local_path="$LOCAL_DIR/$rel"

        if [ "$type" = "folder" ]; then
            if [ -n "${REMOTE_ITEMS[folder|${rel}]+x}" ]; then
                log "[OK] folder: $rel"
                snap_folder "$rel"
            elif was_previously_synced "$rel"; then
                DEL_LOCAL_FOLDERS+=("$rel")
            else
                remote_dir_exists "$rel" || plan folder "On Proton: $rel"
                ensure_remote_folders "$rel"
                snap_folder "$rel"
            fi

        elif [ "$type" = "file" ]; then
            [ -f "$local_path" ] || continue
            local local_fp="${lsize}|${lmtime}"
            local prev_local_fp="${SNAPSHOT_LOCAL_FP[$rel]:-}"
            local prev_remote_fp="${SNAPSHOT_REMOTE_FP[$rel]:-}"

            if [ -n "${REMOTE_ITEMS[file|${rel}]+x}" ]; then
                local remote_fp="${REMOTE_ITEMS[file|${rel}]}"
                local local_changed=false remote_changed=false
                [ -n "$prev_local_fp" ] && [ "$prev_local_fp" != "$local_fp" ] && local_changed=true
                [ -n "$prev_remote_fp" ] && [ "$prev_remote_fp" != "$remote_fp" ] && remote_changed=true
                debug "$rel: local $local_fp (was ${prev_local_fp:-none}), Proton $remote_fp (was ${prev_remote_fp:-none})"

                if [ -z "$prev_local_fp" ] || [ -z "$prev_remote_fp" ]; then
                    log "[FIRST SYNC] $rel"
                    COUNT_FIRST_SYNC=$((COUNT_FIRST_SYNC + 1))
                    snap_file "${rel}" "${local_fp}" "${remote_fp}"
                elif [ "$local_changed" = false ] && [ "$remote_changed" = false ]; then
                    log "[OK] $rel"
                    COUNT_OK=$((COUNT_OK + 1))
                    snap_file "${rel}" "${local_fp}" "${remote_fp}"
                elif [ "$local_changed" = true ] && [ "$remote_changed" = false ]; then
                    log "[UPLOAD MODIFIED] $rel"
                    plan up "$rel (changed)"
                    queue_job up_mod "$rel" "$local_fp" "$remote_fp" "$prev_local_fp" "$prev_remote_fp"
                elif [ "$local_changed" = false ] && [ "$remote_changed" = true ]; then
                    log "[DOWNLOAD MODIFIED] $rel"
                    plan down "$rel (changed)"
                    queue_job down_mod "$rel" "$local_fp" "$remote_fp" "$prev_local_fp" "$prev_remote_fp"
                else
                    log "[CONFLICT] $rel"
                    plan conflict "$rel ($(conflict_note))"
                    COUNT_CONFLICTS=$((COUNT_CONFLICTS + 1))
                    printf '%s\n' "${rel}${SEP}${local_fp}${SEP}${remote_fp}${SEP}${prev_local_fp}${SEP}${prev_remote_fp}" \
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
    while IFS="$SEP" read -r type rel size mtime; do
        compare_done=$((compare_done + 1))
        (( compare_done % 50 == 0 )) && gauge $((10 + 30 * compare_done / compare_total)) \
            "Comparing files ($compare_done of $compare_total)..."
        local_path="$LOCAL_DIR/$rel"
        [ -n "${LOCAL_ITEMS[${type}|${rel}]:-}" ] && continue

        if [ "$type" = "folder" ]; then
            if [ -d "$local_path" ]; then
                snap_folder "$rel"
                continue
            fi
            if was_previously_synced "$rel"; then
                TRASH_REMOTE_FOLDERS+=("$rel")
            else
                log "[DOWNLOAD NEW FOLDER] $rel"
                plan folder "Local: $rel"
                ensure_local_folders "$local_path"
                snap_folder "$rel"
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
    # A file counts as moved only when its size+mtime fingerprint is unique
    # on both sides; otherwise identical copies could be matched to the
    # wrong file. Unmatched files fall through to plain upload/download/delete.
    gauge 40 "Detecting moved files..."
    local old_rel new_rel fp match spec
    declare -A OLD_FP_COUNT=() NEW_FP_COUNT=() FP_TO_OLD=() MOVED_FROM=() MOVE_SRC=()
    declare -a REMOTE_MOVES=() LOCAL_MOVES=()

    for old_rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        fp="${SNAPSHOT_LOCAL_FP[$old_rel]:-}"
        { [ -z "$fp" ] || [ "$fp" = "0|0" ]; } && continue
        OLD_FP_COUNT["$fp"]=$(( ${OLD_FP_COUNT[$fp]:-0} + 1 ))
        FP_TO_OLD["$fp"]="$old_rel"
    done
    for new_rel in "${NEW_LOCAL_FILES[@]+"${NEW_LOCAL_FILES[@]}"}"; do
        fp="${NEW_LOCAL_FP[$new_rel]}"
        NEW_FP_COUNT["$fp"]=$(( ${NEW_FP_COUNT[$fp]:-0} + 1 ))
    done
    declare -a REMAINING_NEW_LOCAL=()
    for new_rel in "${NEW_LOCAL_FILES[@]+"${NEW_LOCAL_FILES[@]}"}"; do
        fp="${NEW_LOCAL_FP[$new_rel]}"
        if [ "${OLD_FP_COUNT[$fp]:-0}" -eq 1 ] && [ "${NEW_FP_COUNT[$fp]:-0}" -eq 1 ]; then
            match="${FP_TO_OLD[$fp]}"
            REMOTE_MOVES+=("${match}${SEP}${new_rel}")
            MOVE_SRC["$match"]=1
        else
            REMAINING_NEW_LOCAL+=("$new_rel")
        fi
    done

    OLD_FP_COUNT=(); NEW_FP_COUNT=(); FP_TO_OLD=()
    for old_rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        fp="${SNAPSHOT_REMOTE_FP[$old_rel]:-}"
        { [ -z "$fp" ] || [ "$fp" = "0|0" ]; } && continue
        OLD_FP_COUNT["$fp"]=$(( ${OLD_FP_COUNT[$fp]:-0} + 1 ))
        FP_TO_OLD["$fp"]="$old_rel"
    done
    for new_rel in "${NEW_REMOTE_FILES[@]+"${NEW_REMOTE_FILES[@]}"}"; do
        fp="${NEW_REMOTE_FP[$new_rel]}"
        NEW_FP_COUNT["$fp"]=$(( ${NEW_FP_COUNT[$fp]:-0} + 1 ))
    done
    declare -a REMAINING_NEW_REMOTE=()
    for new_rel in "${NEW_REMOTE_FILES[@]+"${NEW_REMOTE_FILES[@]}"}"; do
        fp="${NEW_REMOTE_FP[$new_rel]}"
        match=""
        if [ "${OLD_FP_COUNT[$fp]:-0}" -eq 1 ] && [ "${NEW_FP_COUNT[$fp]:-0}" -eq 1 ]; then
            match="${FP_TO_OLD[$fp]}"
        fi
        if [ -n "$match" ] && [ -f "$LOCAL_DIR/$match" ]; then
            LOCAL_MOVES+=("${match}${SEP}${new_rel}")
            MOVE_SRC["$match"]=1
        else
            REMAINING_NEW_REMOTE+=("$new_rel")
        fi
    done

    # ---------- Deletion safety check ----------
    # Runs before any file is moved, transferred or deleted.
    local -a deletions=()
    for rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        [ -n "${MOVE_SRC[$rel]+x}" ] && continue
        [ -f "$LOCAL_DIR/$rel" ] && deletions+=("Local (to local trash):   $rel")
    done
    for rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        [ -n "${MOVE_SRC[$rel]+x}" ] && continue
        [ -f "$LOCAL_DIR/$rel" ] || deletions+=("Proton (to Proton trash): $rel")
    done
    if [ "$ALLOW_DELETES" != true ] && deletions_exceed_limit "${#deletions[@]}"; then
        if [ "$DRY_RUN" = true ]; then
            DELETE_WARNING=true
        else
            printf '%s\n' "${deletions[@]}" > "$PENDING_DELETES"
            ABORT_REASON="This sync would delete ${#deletions[@]} files, more than the safety limit ($(delete_limit_text))."
            log "[STOPPED] $ABORT_REASON"
            gauge 100 "Stopped: ${#deletions[@]} files would be deleted"
            return 2
        fi
    fi

    # ---------- Execute moves ----------
    for spec in "${REMOTE_MOVES[@]+"${REMOTE_MOVES[@]}"}"; do
        match="${spec%%"$SEP"*}"; new_rel="${spec#*"$SEP"}"
        fp="${NEW_LOCAL_FP[$new_rel]}"
        log "[MOVE REMOTE] $match -> $new_rel"
        plan move "On Proton: $match -> $new_rel"
        if do_remote_move "$match" "$new_rel"; then
            COUNT_MOVED_REMOTE=$((COUNT_MOVED_REMOTE + 1))
            snap_file "$new_rel" "$fp" "${SNAPSHOT_REMOTE_FP[$match]:-}"
            MOVED_FROM["$match"]=1
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Move on Proton failed: $match -> $new_rel"
        fi
    done
    for spec in "${LOCAL_MOVES[@]+"${LOCAL_MOVES[@]}"}"; do
        match="${spec%%"$SEP"*}"; new_rel="${spec#*"$SEP"}"
        fp="${NEW_REMOTE_FP[$new_rel]}"
        log "[MOVE LOCAL] $match -> $new_rel"
        plan move "Locally: $match -> $new_rel"
        ensure_local_folders "$(dirname "$LOCAL_DIR/$new_rel")"
        if run mv "$LOCAL_DIR/$match" "$LOCAL_DIR/$new_rel"; then
            COUNT_MOVED_LOCAL=$((COUNT_MOVED_LOCAL + 1))
            local lfp
            if [ "$DRY_RUN" = false ]; then lfp=$(get_local_fingerprint "$LOCAL_DIR/$new_rel"); else lfp="${SNAPSHOT_LOCAL_FP[$match]:-}"; fi
            snap_file "$new_rel" "$lfp" "$fp"
            MOVED_FROM["$match"]=1
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Local move failed: $match -> $new_rel"
            REMAINING_NEW_REMOTE+=("$new_rel")
        fi
    done

    # ---------- PHASE 5: remaining actions ----------
    for rel in "${REMAINING_NEW_LOCAL[@]+"${REMAINING_NEW_LOCAL[@]}"}"; do
        [ -z "$rel" ] && continue
        [ -f "$LOCAL_DIR/$rel" ] || continue
        log "[UPLOAD NEW] $rel"
        plan up "$rel"
        # Folder creation updates KNOWN_DIRS, so it stays serial.
        ensure_remote_folders "$(dirname "$rel")"
        queue_job up_new "$rel" "${NEW_LOCAL_FP[$rel]}" "" "" ""
    done

    for rel in "${REMAINING_NEW_REMOTE[@]+"${REMAINING_NEW_REMOTE[@]}"}"; do
        [ -z "$rel" ] && continue
        log "[DOWNLOAD NEW] $rel"
        plan down "$rel"
        ensure_local_folders "$(dirname "$LOCAL_DIR/$rel")"
        queue_job down_new "$rel" "" "${NEW_REMOTE_FP[$rel]}" "" ""
    done

    for rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        [ -n "${MOVED_FROM[$rel]+x}" ] && continue
        [ -f "$LOCAL_DIR/$rel" ] && continue
        log "[DELETED LOCALLY] $rel -> trashing remote"
        plan del_remote "$rel"
        queue_job trash "$rel" "" "" "" ""
    done

    # Run every queued file transfer (modified and new files, remote
    # trashes) in parallel, then record the results.
    run_job_queue
    process_job_results

    for rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        [ -n "${MOVED_FROM[$rel]+x}" ] && continue
        local_path="$LOCAL_DIR/$rel"; [ -f "$local_path" ] || continue
        log "[DELETED REMOTELY] $rel -> removing local"
        plan del_local "$rel"
        trash_local "$local_path" "$rel"
        COUNT_DELETED_LOCAL=$((COUNT_DELETED_LOCAL + 1))
    done

    for rel in "${DEL_LOCAL_FOLDERS[@]+"${DEL_LOCAL_FOLDERS[@]}"}"; do
        [ -z "$rel" ] && continue
        local_path="$LOCAL_DIR/$rel"; [ -d "$local_path" ] || continue
        log "[DELETED REMOTELY] folder: $rel -> removing local"
        plan del_local "$rel/ (folder)"
        trash_local "$local_path" "$rel"
        COUNT_DELETED_LOCAL=$((COUNT_DELETED_LOCAL + 1))
    done

    for rel in "${TRASH_REMOTE_FOLDERS[@]+"${TRASH_REMOTE_FOLDERS[@]}"}"; do
        [ -z "$rel" ] && continue
        [ -d "$LOCAL_DIR/$rel" ] && continue
        log "[DELETED LOCALLY] folder: $rel -> trashing remote"
        plan del_remote "$rel/ (folder)"
        if run_retry proton-drive filesystem trash "$REMOTE_DIR/$rel"; then
            COUNT_TRASHED_REMOTE=$((COUNT_TRASHED_REMOTE + 1))
        else
            COUNT_ERRORS=$((COUNT_ERRORS + 1))
            plan failed "Deleting folder on Proton failed: $rel"
        fi
    done

    # ---------- Finalize (snapshot handled by caller) ----------
    gauge 97 "Finishing up..."
    rm -f "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"
    cleanup_old_trash
    cleanup_old_logs

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

    gauge 100 "Done"
    return 0
}

# ============================================================
# SYNC RUN HELPERS (shared by TUI and headless mode)
# ============================================================

load_conflicts() {
    local conflict_dump="$1"
    CONFLICTS=(); CONFLICT_LOCAL_FP=(); CONFLICT_REMOTE_FP=()
    CONFLICT_PREV_L=(); CONFLICT_PREV_R=()
    [ -s "$conflict_dump" ] || return 0
    local rel lfp rfp pl pr
    while IFS="$SEP" read -r rel lfp rfp pl pr; do
        CONFLICTS+=("$rel")
        CONFLICT_LOCAL_FP["$rel"]="$lfp"
        CONFLICT_REMOTE_FP["$rel"]="$rfp"
        CONFLICT_PREV_L["$rel"]="$pl"
        CONFLICT_PREV_R["$rel"]="$pr"
    done < "$conflict_dump"
}

finalize_snapshot() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Snapshot not updated."
        rm -f "$NEW_SNAPSHOT"
    else
        mv "$NEW_SNAPSHOT" "$SNAPSHOT" 2>/dev/null || true
    fi
}

sync_summary() {
    printf "%s\n" \
        "Unchanged:       $COUNT_OK" \
        "First sync:      $COUNT_FIRST_SYNC" \
        "Uploaded:        $COUNT_UPLOADED" \
        "Downloaded:      $COUNT_DOWNLOADED" \
        "Moved (remote):  $COUNT_MOVED_REMOTE" \
        "Moved (local):   $COUNT_MOVED_LOCAL" \
        "Deleted local:   $COUNT_DELETED_LOCAL" \
        "Trashed remote:  $COUNT_TRASHED_REMOTE" \
        "Conflicts:       $COUNT_CONFLICTS" \
        "Errors:          $COUNT_ERRORS"
}

# ============================================================
# USER INTERFACE LAYER (dialog, or whiptail as a fallback)
# ============================================================

UI_TOOL=""
UI_BACKTITLE="Proton Drive Sync"
AUTH_STATE=unknown     # in | out | unknown

# Use $PROTON_SYNC_UI if set, else dialog, else whiptail.
find_ui_tool() {
    local tool
    for tool in ${PROTON_SYNC_UI:-} dialog whiptail; do
        if command -v "$tool" >/dev/null 2>&1; then
            UI_TOOL="$tool"
            return 0
        fi
    done
    return 1
}

# Fit dialogs to the terminal (checked every time, so resizing works).
ui_size() {
    local rows=24 cols=80 size
    if size=$(stty size < /dev/tty 2>/dev/null) && [ -n "$size" ]; then
        rows="${size% *}"; cols="${size#* }"
    fi
    UI_H=$((rows - 4)); ((UI_H > 30)) && UI_H=30; ((UI_H < 10)) && UI_H=10
    UI_W=$((cols - 6)); ((UI_W > 100)) && UI_W=100; ((UI_W < 40)) && UI_W=40
}

# ui_fit TEXT EXTRA_ROWS — size a box for TEXT (sets BOX_H and BOX_W).
ui_fit() {
    local text="$1" extra="$2" line longest=0 rows=0 inner
    ui_size
    while IFS= read -r line; do
        ((${#line} > longest)) && longest=${#line}
    done <<< "$text"
    BOX_W=$((longest + 6)); ((BOX_W < 50)) && BOX_W=50; ((BOX_W > UI_W)) && BOX_W=$UI_W
    inner=$((BOX_W - 4))
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            rows=$((rows + 1))
        elif ((${#line} <= inner)); then
            rows=$((rows + 1))
        else
            # Wrapping happens at spaces, which can take an extra row.
            rows=$((rows + (${#line} + inner - 1) / inner + 1))
        fi
    done <<< "$text"
    BOX_H=$((rows + extra)); ((BOX_H > UI_H)) && BOX_H=$UI_H
}

_ui() {
    local -a common=(--backtitle "$UI_BACKTITLE")
    [ "$UI_TOOL" = dialog ] && common+=(--no-collapse)
    "$UI_TOOL" "${common[@]}" "$@"
}

ui_msgbox() {   # TITLE TEXT
    ui_fit "$2" 6
    _ui --title "$1" --msgbox "$2" "$BOX_H" "$BOX_W"
}

ui_infobox() {  # TITLE TEXT
    ui_fit "$2" 4
    _ui --title "$1" --infobox "$2" "$BOX_H" "$BOX_W"
}

ui_yesno() {    # TITLE TEXT [YES_LABEL NO_LABEL] — returns 0 for yes
    local -a labels=()
    if [ -n "${3:-}" ]; then
        if [ "$UI_TOOL" = dialog ]; then
            labels=(--yes-label "$3" --no-label "${4:-No}")
        else
            labels=(--yes-button "$3" --no-button "${4:-No}")
        fi
    fi
    ui_fit "$2" 6
    _ui --title "$1" "${labels[@]}" --yesno "$2" "$BOX_H" "$BOX_W"
}

ui_input() {    # TITLE TEXT DEFAULT — prints the entered value
    ui_fit "$2" 8
    _ui --title "$1" --inputbox "$2" "$BOX_H" "$BOX_W" "$3" 3>&1 1>&2 2>&3
}

ui_textbox() {  # TITLE FILE
    ui_size
    if [ "$UI_TOOL" = dialog ]; then
        _ui --title "$1" --exit-label "Close" --textbox "$2" "$UI_H" "$UI_W"
    else
        _ui --title "$1" --scrolltext --textbox "$2" "$UI_H" "$UI_W"
    fi
}

ui_gauge() {    # TITLE — reads the gauge protocol from stdin
    ui_size
    _ui --title "$1" --gauge "Starting..." 8 "$UI_W" 0
}

# Size a list box: TEXT, number of items, longest item (sets BOX_H/BOX_W/LIST_H).
_ui_list_size() {
    local text="$1" n="$2" longest="$3" text_h max_list
    ui_fit "$text" 0
    text_h=$BOX_H
    max_list=$((UI_H - text_h - 7)); ((max_list < 3)) && max_list=3
    LIST_H=$n; ((LIST_H > max_list)) && LIST_H=$max_list; ((LIST_H < 1)) && LIST_H=1
    BOX_H=$((text_h + LIST_H + 7)); ((BOX_H > UI_H)) && BOX_H=$UI_H
    ((longest + 12 > BOX_W)) && BOX_W=$((longest + 12))
    ((BOX_W > UI_W)) && BOX_W=$UI_W
}

# ui_menu TITLE TEXT CANCEL_LABEL DEFAULT_TAG TAG ITEM... — prints the chosen
# tag. Tags are hidden; an empty CANCEL_LABEL hides the cancel button.
ui_menu() {
    local title="$1" text="$2" cancel="$3" default="$4"; shift 4
    local -a opts=()
    local i longest=0
    local item
    for ((i = 2; i <= $#; i += 2)); do
        item="${!i}"
        ((${#item} > longest)) && longest=${#item}
    done
    _ui_list_size "$text" $(($# / 2)) "$longest"
    [ -n "$default" ] && opts+=(--default-item "$default")
    if [ "$UI_TOOL" = dialog ]; then
        opts+=(--no-tags)
        if [ -z "$cancel" ]; then opts+=(--no-cancel); else opts+=(--cancel-label "$cancel"); fi
    else
        opts+=(--notags)
        if [ -z "$cancel" ]; then opts+=(--nocancel); else opts+=(--cancel-button "$cancel"); fi
    fi
    _ui --title "$title" "${opts[@]}" --menu "$text" "$BOX_H" "$BOX_W" "$LIST_H" "$@" 3>&1 1>&2 2>&3
}

# ui_checklist TITLE TEXT TAG ITEM STATUS... — prints chosen tags, one per line.
ui_checklist() {
    local title="$1" text="$2"; shift 2
    local i longest=0
    local item
    for ((i = 2; i <= $#; i += 3)); do
        item="${!i}"
        ((${#item} > longest)) && longest=${#item}
    done
    _ui_list_size "$text" $(($# / 3)) $((longest + 4))
    local notags=--no-tags
    [ "$UI_TOOL" = whiptail ] && notags=--notags
    _ui --title "$title" --separate-output "$notags" \
        --checklist "$text" "$BOX_H" "$BOX_W" "$LIST_H" "$@" 3>&1 1>&2 2>&3
}

# ============================================================
# SHARED TEXT HELPERS
# ============================================================

ago() {
    local s=$(( $(date +%s) - $1 ))
    if ((s < 60)); then echo "just now"
    elif ((s < 3600)); then echo "$((s / 60)) min ago"
    elif ((s < 86400)); then echo "$((s / 3600)) h ago"
    else echo "$((s / 86400)) days ago"
    fi
}

# "20260927-052856" -> "2026-09-27 05:28"
pretty_stamp() {
    local s="$1"
    echo "${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}"
}

last_sync_text() {
    local when text
    if [ -s "$STATUS_FILE" ] && IFS=$'\t' read -r when text < "$STATUS_FILE"; then
        echo "$(ago "$when"): $text"
    else
        echo "never"
    fi
}

# Show paths under the home folder as ~/...
display_path() {
    if [ "$1" = "$HOME" ] || [[ "$1" == "$HOME"/* ]]; then
        echo "~${1#"$HOME"}"
    else
        echo "$1"
    fi
}

conflict_label() {
    case "$CONFLICT_STRATEGY" in
        ask)    echo "Ask me" ;;
        local)  echo "Keep local" ;;
        remote) echo "Keep Proton" ;;
        both)   echo "Keep both" ;;
        skip)   echo "Skip" ;;
    esac
}

# Text = no NUL bytes and valid UTF-8 (grep -I in a UTF-8 locale).
is_text_file() {
    [ ! -s "$1" ] || LC_ALL=C.UTF-8 grep -Iq . "$1" 2>/dev/null
}

# ============================================================
# SYNC SCREENS
# ============================================================

# Re-check the login before a sync (the session may have expired).
preflight() {
    ui_infobox "Please Wait" "Checking your Proton Drive login..."
    if ! is_authenticated; then
        if ! ensure_authenticated; then
            ui_msgbox "Not Logged In" "Can't open $REMOTE_DIR on Proton Drive, so the sync can't run."
            return 1
        fi
    fi
    AUTH_STATE=in
    return 0
}

# run_sync_with_gauge DRY_RUN — run one sync (or preview) with a progress bar.
run_sync_with_gauge() {
    local dry="$1"
    [ "$FORCE_DRY_RUN" = true ] && dry=true
    DRY_RUN="$dry"

    preflight || return

    if ! acquire_lock; then
        ui_msgbox "Sync Already Running" "Another sync is running right now (lock: $LOCK_FILE).

If you're sure none is running, delete that folder and try again."
        return
    fi

    LOG_FILE="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S).log"
    LOCAL_TRASH="$TRASH_DIR/$(date +%Y%m%d-%H%M%S)"

    local title="Syncing"
    [ "$dry" = true ] && title="Preview (no changes are made)"

    local conflict_dump="$STATE_DIR/conflicts.tmp"
    : > "$conflict_dump"

    # Feed the gauge through a process substitution rather than a pipeline,
    # so sync_engine runs in this shell and its counters and status survive.
    local engine_rc=0
    sync_engine "$conflict_dump" > >(ui_gauge "$title") || engine_rc=$?
    wait "$!" 2>/dev/null || true

    if [ "$engine_rc" -ne 0 ]; then
        # Stopped before any changes: keep the existing snapshot untouched.
        rm -f "$conflict_dump" "$NEW_SNAPSHOT" "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"
        release_lock
        if [ "$engine_rc" -eq 2 ]; then
            confirm_large_deletion
        else
            record_result "Stopped: $ABORT_REASON"
            ui_msgbox "Sync Stopped" "$ABORT_REASON

No changes were made. Details are in the log:
$LOG_FILE"
        fi
        return
    fi

    load_conflicts "$conflict_dump"
    if [ "${#CONFLICTS[@]}" -gt 0 ] && [ "$DRY_RUN" != true ]; then
        resolve_all_conflicts
    fi
    rm -f "$conflict_dump"

    finalize_snapshot
    release_lock

    if [ "$DRY_RUN" = true ]; then
        record_result "Preview: $(result_text)"
        show_preview
    else
        record_result "$(result_text)"
        show_summary
    fi
}

show_preview() {
    if [ ! -s "$PLAN_FILE" ]; then
        ui_msgbox "Preview" "Everything is already in sync. There's nothing to do."
        return
    fi
    local view="$STATE_DIR/view.txt" headline
    format_plan > "$view"
    headline=$(head -1 "$view")
    ui_textbox "Preview: what a sync would change" "$view"
    rm -f "$view"
    [ "$FORCE_DRY_RUN" = true ] && return
    if ui_yesno "Preview" "Run this sync now?

$headline" "Run sync now" "Not now"; then
        run_sync_with_gauge false
    fi
}

show_summary() {
    local text n_failed
    if [ "$COUNT_ERRORS" -gt 0 ]; then
        text="The sync finished with $COUNT_ERRORS error(s)."
    else
        text="Sync complete."
    fi
    text+=$'\n\n'"$(sync_summary)"
    n_failed=$(plan_count failed)
    if [ "$n_failed" -gt 0 ]; then
        text+=$'\n\nProblems:\n'"$(grep "^failed"$'\t' "$PLAN_FILE" | cut -f2- | head -8 | sed 's/^/  /')"
        [ "$n_failed" -gt 8 ] && text+=$'\n'"  ...and $((n_failed - 8)) more (see the log)"
        text+=$'\n\nFailed items are tried again on the next sync.'
    fi
    if ui_yesno "Sync Summary" "$text" "View log" "Close"; then
        view_log "$LOG_FILE"
    fi
}

# The sync stopped because it would delete more than the safety limit.
confirm_large_deletion() {
    local n view="$STATE_DIR/view.txt"
    n=$(wc -l < "$PENDING_DELETES")
    {
        echo "$ABORT_REASON"
        echo
        echo "Nothing has been changed yet. If you go ahead, local files go to the"
        echo "local trash (see Restore deleted files) and files on Proton go to"
        echo "Proton's trash."
        echo
        cat "$PENDING_DELETES"
    } > "$view"
    ui_textbox "Large Deletion: $n files" "$view"
    rm -f "$view"
    if ui_yesno "Large Deletion" "Delete these $n files and finish the sync?" "Delete and sync" "Cancel"; then
        ALLOW_DELETES=true
        run_sync_with_gauge false
        ALLOW_DELETES="${PROTON_SYNC_ALLOW_DELETES:-false}"
    else
        record_result "Stopped: $n deletions not confirmed"
        ui_msgbox "Sync Cancelled" "Nothing was changed. The next sync will ask again."
    fi
}

# ============================================================
# CONFLICT SCREENS
# ============================================================

# Ask how to resolve one conflict; sets CONFLICT_CHOICE. (Not echoed: the
# follow-up dialogs must draw on the terminal, so this can't run in $(...).)
resolve_conflict_interactive() {
    local rel="$1" local_desc remote_desc
    local_desc=$(fmt_fp "${CONFLICT_LOCAL_FP[$rel]}")
    remote_desc=$(fmt_fp "${CONFLICT_REMOTE_FP[$rel]}")
    local default=local
    while true; do
        CONFLICT_CHOICE=$(ui_menu "Conflict: $rel" \
"This file changed both here and on Proton Drive since the last sync.

  Local:  $local_desc
  Proton: $remote_desc

What would you like to do?" "" "$default" \
            diff      "Show differences" \
            local     "Keep LOCAL  (upload, replace the Proton version)" \
            remote    "Keep PROTON (download, replace the local version)" \
            both      "Keep BOTH   (local wins; Proton version saved as .remote copy)" \
            skip      "Skip        (decide next time)" \
            alllocal  "Keep LOCAL for all remaining conflicts" \
            allremote "Keep PROTON for all remaining conflicts") || CONFLICT_CHOICE=skip
        [ "$CONFLICT_CHOICE" = diff ] || return 0
        show_conflict_diff "$rel" "$local_desc" "$remote_desc"
        default=diff
    done
}

show_conflict_diff() {
    local rel="$1" local_desc="$2" remote_desc="$3" name tmp
    name=$(basename "$rel")
    tmp=$(mktemp -d "$STATE_DIR/diff.XXXXXX") || return
    mkdir "$tmp/remote"
    ui_infobox "Conflict: $rel" "Downloading the Proton version to compare..."
    if ! proton-drive filesystem download "$REMOTE_DIR/$rel" "$tmp/remote" >>"$LOG_FILE" 2>&1 \
        || [ ! -f "$tmp/remote/$name" ]; then
        ui_msgbox "Conflict: $rel" "Couldn't download the Proton version to compare. Details are in the log."
    elif is_text_file "$LOCAL_DIR/$rel" && is_text_file "$tmp/remote/$name"; then
        if diff -u --label "Local: $rel" --label "Proton: $rel" \
            "$LOCAL_DIR/$rel" "$tmp/remote/$name" > "$tmp/diff.txt"; then
            ui_msgbox "Conflict: $rel" "Both versions have exactly the same contents; only their timestamps differ. Keeping either one is safe."
        else
            ui_textbox "Differences (- local, + Proton): $rel" "$tmp/diff.txt"
        fi
    else
        ui_msgbox "Conflict: $rel" "These aren't text files, so they can't be compared line by line.

  Local:  $local_desc
  Proton: $remote_desc"
    fi
    rm -rf -- "${tmp:?}"
}

# ============================================================
# HISTORY AND LOG SCREENS
# ============================================================

logs_menu() {
    local -a items=()
    local f name result
    while IFS= read -r f; do
        name=$(basename "$f" .log)
        result=$(grep -m1 '^RESULT: ' "$f" 2>/dev/null | cut -c9-)
        [ -z "$result" ] && result="(no result recorded)"
        items+=("$f" "$(pretty_stamp "${name#sync-}")  $result")
    done < <(ls -1 "$LOG_DIR"/sync-*.log 2>/dev/null | sort -r | head -200)

    if [ "${#items[@]}" -eq 0 ]; then
        ui_msgbox "Sync History" "No syncs have run for this folder pair yet."
        return
    fi
    local choice="${items[0]}"
    while true; do
        choice=$(ui_menu "Sync History" "Newest first. Choose a sync to see its log." \
            "Back" "$choice" "${items[@]}") || return
        view_log "$choice"
    done
}

view_log() {
    local f="$1" choice view="$STATE_DIR/view.txt" name
    name=$(basename "$f" .log)
    choice=$(ui_menu "Log: $(pretty_stamp "${name#sync-}")" "What would you like to see?" "Back" "" \
        changes "Changes and problems only" \
        full    "Full log") || return
    if [ "$choice" = full ]; then
        ui_textbox "Full log: $(pretty_stamp "${name#sync-}")" "$f"
        return
    fi
    grep -E '^(RESULT:|=== Sync started|\[(UPLOAD|DOWNLOAD|MOVE|DELETED|CONFLICT|RESOLVE|ERROR|FATAL|STOPPED|RETRY|SKIP|CREATE))' \
        "$f" > "$view" 2>/dev/null
    [ -s "$view" ] || echo "No changes or problems in this sync." > "$view"
    ui_textbox "Changes and problems: $(pretty_stamp "${name#sync-}")" "$view"
    rm -f "$view"
}

# ============================================================
# RESTORE SCREENS
# ============================================================

restore_menu() {
    local -a items=()
    local d n
    while IFS= read -r d; do
        d="${d%/}"
        n=$(find "$d" -type f | wc -l)
        [ "$n" -eq 0 ] && continue
        items+=("$d" "$(pretty_stamp "$(basename "$d")")  $n file(s)")
    done < <(ls -1d "$TRASH_DIR"/*/ 2>/dev/null | sort -r)

    if [ "${#items[@]}" -eq 0 ]; then
        local keep="$TRASH_RETENTION_DAYS days"
        [ "$TRASH_RETENTION_DAYS" -eq 0 ] && keep="until you delete them"
        ui_msgbox "Restore Deleted Files" "There's nothing to restore.

When a sync deletes a local file (because it was deleted on Proton Drive), the file is kept here for $keep."
        return
    fi

    local session
    session=$(ui_menu "Restore Deleted Files" "Files deleted locally by each sync, newest first:" \
        "Back" "" "${items[@]}") || return

    local -a files=()
    mapfile -t files < <(cd "$session" && find . -type f | sed 's|^\./||' | sort)
    local count="${#files[@]}" action
    action=$(ui_menu "Restore: $(pretty_stamp "$(basename "$session")")" \
        "$count file(s) were deleted by this sync." "Back" "" \
        pick "Choose files to restore" \
        all  "Restore all $count files") || return

    local -a chosen=()
    if [ "$action" = all ]; then
        chosen=("${files[@]}")
    else
        local -a list=()
        local i picked
        for i in "${!files[@]}"; do
            list+=("$i" "${files[$i]}" off)
        done
        picked=$(ui_checklist "Restore Deleted Files" \
            "Select files with Space, then press Enter:" "${list[@]}") || return
        while IFS= read -r i; do
            [ -n "$i" ] && chosen+=("${files[$i]}")
        done <<< "$picked"
        [ "${#chosen[@]}" -eq 0 ] && return
    fi
    restore_files "$session" "${chosen[@]}"
}

# "dir/name.ext" -> "dir/name (restored).ext", "(restored 2)", ...
unique_restore_name() {
    local path="$1" dir name stem ext="" n=1 cand
    dir=$(dirname "$path"); name=$(basename "$path"); stem="${name%.*}"
    if [ -z "$stem" ] || [ "$stem" = "$name" ]; then
        stem="$name"
    else
        ext=".${name##*.}"
    fi
    while true; do
        if [ "$n" -eq 1 ]; then cand="$dir/$stem (restored)$ext"; else cand="$dir/$stem (restored $n)$ext"; fi
        [ -e "$cand" ] || { echo "$cand"; return; }
        n=$((n + 1))
    done
}

restore_files() {
    local session="$1"; shift
    local rel dest restored=0 failed=0 text
    local -a renamed=()
    for rel in "$@"; do
        dest="$LOCAL_DIR/$rel"
        if [ -e "$dest" ]; then
            dest=$(unique_restore_name "$dest")
            renamed+=("$rel -> ${dest#"$LOCAL_DIR"/}")
        fi
        if mkdir -p "$(dirname "$dest")" && mv "$session/$rel" "$dest"; then
            restored=$((restored + 1))
            log "[RESTORED] $rel -> $dest"
        else
            failed=$((failed + 1))
        fi
    done
    # Remove folders left empty in this trash session.
    find "$session" -depth -type d -empty -delete 2>/dev/null

    text="Restored $restored file(s) to $LOCAL_DIR. The next sync uploads them to Proton Drive again."
    if [ "${#renamed[@]}" -gt 0 ]; then
        text+=$'\n\nThese already existed, so the restored copies got new names:\n'
        text+="$(printf '  %s\n' "${renamed[@]:0:8}")"
        [ "${#renamed[@]}" -gt 8 ] && text+=$'\n'"  ...and $((${#renamed[@]} - 8)) more"
    fi
    [ "$failed" -gt 0 ] && text+=$'\n\n'"$failed file(s) couldn't be restored."
    ui_msgbox "Restore Complete" "$text"
}

# ============================================================
# SETTINGS SCREENS
# ============================================================

settings_menu() {
    local choice=local
    while true; do
        choice=$(ui_menu "Settings" "Changes are saved right away and used by automatic syncs too." \
            "Back" "$choice" \
            local    "Local folder:        $(display_path "$LOCAL_DIR")" \
            remote   "Proton folder:       $REMOTE_DIR" \
            conflict "Conflicts:           $(conflict_label)" \
            jobs     "Parallel transfers:  $SYNC_JOBS" \
            deletes  "Confirm deletions:   $(delete_limit_text)" \
            excludes "Excluded names:      ${EXCLUDE_PATTERNS[*]}" \
            trash    "Keep local trash:    $(days_text "$TRASH_RETENTION_DAYS")" \
            logdays  "Keep logs:           $(days_text "$LOG_RETENTION_DAYS")" \
            debug    "Debug logging:       $( [ "$DEBUG" = true ] && echo on || echo off )" \
            where    "Where settings, logs and trash are stored") || return
        case "$choice" in
            local|remote) change_folder "$choice" ;;
            conflict)     choose_conflict_strategy ;;
            jobs)         ask_number "Parallel Transfers" "How many transfers and folder listings should run at the same time? (1-16)

Lower this if Proton Drive starts refusing requests." SYNC_JOBS 1 16 ;;
            deletes)      ask_delete_limits ;;
            excludes)     edit_excludes ;;
            trash)        ask_number "Local Trash" "Keep files that syncs delete locally for how many days? (0 = keep until you delete them)" TRASH_RETENTION_DAYS 0 36500 ;;
            logdays)      ask_number "Logs" "Keep sync logs for how many days? (0 = keep forever)" LOG_RETENTION_DAYS 0 36500 ;;
            debug)        if [ "$DEBUG" = true ]; then set_setting DEBUG false; else set_setting DEBUG true; fi ;;
            where)        show_locations ;;
        esac
    done
}

days_text() {
    if [ "$1" -eq 0 ]; then echo "forever"; else echo "$1 days"; fi
}

# ask_number TITLE TEXT KEY MIN MAX — returns 1 if cancelled.
ask_number() {
    local title="$1" text="$2" key="$3" min="$4" max="$5" value
    while true; do
        value=$(ui_input "$title" "$text" "${!key}") || return 1
        value="${value// /}"
        if is_number "$value" && [ "$((10#$value))" -ge "$min" ] && [ "$((10#$value))" -le "$max" ]; then
            set_setting "$key" "$((10#$value))"
            return 0
        fi
        ui_msgbox "$title" "Please enter a whole number from $min to $max."
    done
}

ask_delete_limits() {
    ask_number "Confirm Deletions" "Ask before a sync deletes more than how many files? (0 = no limit)

Automatic syncs stop instead of asking; run a sync from the menu to confirm." \
        DELETE_CONFIRM_COUNT 0 100000000 || return
    ask_number "Confirm Deletions" "Also ask when a sync would delete more than what percentage of your synced files? (0 = off)

This only applies when 5 or more files would be deleted." \
        DELETE_CONFIRM_PERCENT 0 100
}

edit_excludes() {
    local value
    local -a patterns=()
    value=$(ui_input "Excluded Names" "Files and folders with these names are never synced. Separate names with spaces; * and ? work as wildcards.

Example: *.tmp .git node_modules" "${EXCLUDE_PATTERNS[*]}") || return
    read -ra patterns <<< "$value"
    EXCLUDE_PATTERNS=("${patterns[@]+"${patterns[@]}"}")
    CFG_EXCLUDE_PATTERNS=("${patterns[@]+"${patterns[@]}"}")
    save_config
}

choose_conflict_strategy() {
    local value
    value=$(ui_menu "Conflicts" "When a file changed both here and on Proton Drive since the last sync:" \
        "Back" "$CONFLICT_STRATEGY" \
        ask    "Ask me each time (automatic syncs skip the file instead)" \
        local  "Keep the local version" \
        remote "Keep the Proton version" \
        both   "Keep both (local wins; Proton version saved as a .remote copy)" \
        skip   "Skip it and leave both versions as they are") || return
    set_setting CONFLICT_STRATEGY "$value"
}

change_folder() {
    local which="$1" value
    if [ "$which" = local ]; then
        value=$(ui_input "Local Folder" "Folder on this computer to keep in sync:" "$LOCAL_DIR") || return
        value="${value/#\~/$HOME}"
        [ -z "$value" ] && return
        [[ "$value" = /* ]] || value="$PWD/$value"
        if [ ! -d "$value" ]; then
            ui_yesno "Local Folder" "$value doesn't exist. Create it?" "Create" "Cancel" || return
            if ! mkdir -p "$value"; then
                ui_msgbox "Local Folder" "Couldn't create $value."
                return
            fi
        fi
        [ "$value" != "/" ] && value="${value%/}"
        [ "$value" = "$LOCAL_DIR" ] && return
        set_setting LOCAL_DIR "$value"
    else
        value=$(ui_input "Proton Folder" "Folder on Proton Drive to keep in sync (starts with /):" "$REMOTE_DIR") || return
        [ -z "$value" ] && return
        [[ "$value" = /* ]] || value="/$value"
        [ "$value" != "/" ] && value="${value%/}"
        [ "$value" = "$REMOTE_DIR" ] && return
        ui_infobox "Proton Folder" "Checking $value on Proton Drive..."
        if ! proton-drive filesystem list "$value" -j >/dev/null 2>&1; then
            ui_yesno "Proton Folder" "Couldn't open $value on Proton Drive. It may not exist yet, or you may not be logged in.

Use it anyway?" "Use it" "Cancel" || return
        fi
        set_setting REMOTE_DIR "$value"
    fi

    init_state_paths
    if [ ! -s "$SNAPSHOT" ]; then
        ui_msgbox "New Folder Pair" "These folders haven't been synced together before:

  Local:  $LOCAL_DIR
  Proton: $REMOTE_DIR

The first sync copies files that exist on only one side to the other side, and doesn't delete anything. Use Preview sync first to see what it will do."
    else
        ui_msgbox "Folders Changed" "You've synced these folders together before, so their earlier history is used. Each folder pair keeps its own history, logs and trash."
    fi
}

show_locations() {
    ui_msgbox "Where Things Are Stored" "Settings:      $CONFIG_FILE
Sync history:  $STATE_DIR
Logs:          $LOG_DIR
Local trash:   $TRASH_DIR
Automatic sync output: $STATE_ROOT/cron.log

Each local/Proton folder pair has its own history, logs and trash."
}

# ============================================================
# ACCOUNT AND AUTOMATIC SYNC SCREENS
# ============================================================

account_action() {
    if [ "$AUTH_STATE" = out ]; then
        perform_login
        if is_authenticated; then
            AUTH_STATE=in
            ui_msgbox "Logged In" "You're logged in to Proton Drive."
        else
            ui_msgbox "Not Logged In" "The login didn't complete. You can try again from the main menu."
        fi
    elif ui_yesno "Log Out" "Log out of Proton Drive?

Syncs, including automatic ones, won't work until you log in again." "Log out" "Cancel"; then
        proton-drive auth logout >/dev/null 2>&1
        AUTH_STATE=out
        ui_msgbox "Logged Out" "You've been logged out of Proton Drive."
    fi
}

CRON_MARKER="# proton-drive-sync"

cron_entry() {
    crontab -l 2>/dev/null | grep -F "$CRON_MARKER" | head -1
}

describe_schedule() {
    local min hour dom mon dow
    read -r min hour dom mon dow _ <<< "$1"
    if [ "$dom $mon $dow" != "* * *" ]; then
        echo "custom schedule"
    elif [ "$hour" = "*" ]; then
        echo "every hour"
    elif [ "$hour" = "*/6" ]; then
        echo "every 6 hours"
    elif is_number "$hour" && is_number "$min"; then
        printf 'daily at %02d:%02d\n' "$((10#$hour))" "$((10#$min))"
    else
        echo "custom schedule"
    fi
}

schedule_text() {
    command -v crontab >/dev/null 2>&1 || { echo "unavailable (cron not installed)"; return; }
    local line
    line=$(cron_entry)
    if [ -z "$line" ]; then echo "off"; else describe_schedule "$line"; fi
}

# Quote a string for /bin/sh.
sh_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

# build_cron_entry hourly|six|daily
build_cron_entry() {
    local when min=$((RANDOM % 60)) path_dirs="" dir cmd var
    case "$1" in
        hourly) when="$min * * * *" ;;
        six)    when="$min */6 * * *" ;;
        daily)  when="$min 3 * * *" ;;
    esac
    # cron's PATH is minimal: include wherever proton-drive, jq and bash live.
    for dir in "$(dirname "$(command -v proton-drive)")" "$(dirname "$(command -v jq)")" \
               "$(dirname "$(command -v bash)")" /usr/local/bin /usr/bin /bin; do
        case ":$path_dirs:" in *":$dir:"*) ;; *) path_dirs="${path_dirs:+$path_dirs:}$dir" ;; esac
    done
    cmd="env $(sh_quote "PATH=$path_dirs")"
    for var in XDG_CONFIG_HOME XDG_DATA_HOME PROTON_SYNC_CONFIG; do
        [ -n "${!var:-}" ] && cmd+=" $(sh_quote "$var=${!var}")"
    done
    cmd+=" $(sh_quote "$(command -v bash)") $(sh_quote "$SCRIPT_PATH") --headless"
    cmd+=" >> $(sh_quote "$STATE_ROOT/cron.log") 2>&1"
    # cron treats a bare % as a line break.
    echo "$when ${cmd//%/\\%} $CRON_MARKER"
}

# install_cron_entry LINE — replace this script's crontab line ("" removes it).
install_cron_entry() {
    local line="$1"
    {
        crontab -l 2>/dev/null | grep -vF "$CRON_MARKER"
        [ -n "$line" ] && printf '%s\n' "$line"
    } | crontab -
}

schedule_menu() {
    if ! command -v crontab >/dev/null 2>&1; then
        ui_msgbox "Automatic Sync" "Automatic sync uses cron, but the crontab command isn't installed.

Install cron (for example: sudo apt install cron), then come back here."
        return
    fi
    local choice line note=""
    choice=$(ui_menu "Automatic Sync" "Syncs these folders in the background with your saved settings, even when this menu is closed.

Currently: $(schedule_text)" "Back" "" \
        hourly "Every hour" \
        six    "Every 6 hours" \
        daily  "Once a day (around 3 AM)" \
        off    "Turn off") || return

    if [ "$choice" = off ]; then
        if install_cron_entry ""; then
            ui_msgbox "Automatic Sync" "Automatic sync is off."
        else
            ui_msgbox "Automatic Sync" "Couldn't update your crontab."
        fi
        return
    fi

    line=$(build_cron_entry "$choice")
    if ! install_cron_entry "$line"; then
        ui_msgbox "Automatic Sync" "Couldn't update your crontab."
        return
    fi
    [ "$CONFLICT_STRATEGY" = ask ] && note=$'\n\n'"Conflicts are set to \"Ask me\", so automatic syncs skip files that changed on both sides until you sync from this menu. You can change that in Settings."
    ui_msgbox "Automatic Sync" "Automatic sync is on: $(describe_schedule "$line").

Results show up under Last sync on the main menu and in Sync history. Each run's output is also added to:
  $STATE_ROOT/cron.log

If a run would delete more files than your safety limit, it stops without changing anything; run a sync from this menu to confirm.$note"
}

# ============================================================
# MAIN MENU
# ============================================================

menu_header() {
    local account="logged in"
    [ "$AUTH_STATE" = out ] && account="not logged in"
    printf 'Local:      %s\n' "$(display_path "$LOCAL_DIR")"
    printf 'Proton:     %s\n' "$REMOTE_DIR"
    printf 'Last sync:  %s\n' "$(last_sync_text)"
    printf 'Account:    %s    Conflicts: %s' "$account" "$(conflict_label)"
    [ "$FORCE_DRY_RUN" = true ] && printf '\n\nPreview only: PROTON_SYNC_DRY_RUN is set, so syncs make no changes.'
    return 0
}

main_menu() {
    local choice=sync account_item
    while true; do
        if [ "$AUTH_STATE" = out ]; then
            account_item="Log in to Proton Drive"
        else
            account_item="Log out of Proton Drive"
        fi
        choice=$(ui_menu "Main Menu" "$(menu_header)" "Quit" "$choice" \
            sync     "Sync now" \
            preview  "Preview sync (see what would change)" \
            restore  "Restore deleted files" \
            logs     "Sync history and logs" \
            settings "Settings" \
            schedule "Automatic sync: $(schedule_text)" \
            account  "$account_item") || break
        case "$choice" in
            sync)     run_sync_with_gauge false ;;
            preview)  run_sync_with_gauge true ;;
            restore)  restore_menu ;;
            logs)     logs_menu ;;
            settings) settings_menu ;;
            schedule) schedule_menu ;;
            account)  account_action ;;
        esac
    done
    clear
    echo "Goodbye."
}

# ============================================================
# HEADLESS MODE
# ============================================================

# Non-interactive sync for cron/systemd: no dialogs, no prompts.
# Exits 0 on success, 1 on any failure, transfer error or stop.
headless_sync() {
    echo "Proton Drive Sync (headless) $(date '+%Y-%m-%d %H:%M')"
    echo "Local:   $LOCAL_DIR"
    echo "Proton:  $REMOTE_DIR"
    [ "$DRY_RUN" = true ] && echo "Mode:    DRY RUN (no changes will be made)"
    echo

    if ! acquire_lock; then
        echo "ERROR: Another sync is already running (lock: $LOCK_FILE)" >&2
        echo "If you are sure no sync is running, remove it manually:" >&2
        echo "  rmdir '$LOCK_FILE'" >&2
        return 1
    fi

    if ! is_authenticated; then
        record_result "Stopped: not logged in to Proton Drive"
        echo "ERROR: Cannot access $REMOTE_DIR — are you logged in?" >&2
        echo "Run: proton-drive auth login" >&2
        return 1
    fi

    # Conflicts can't be asked about without a terminal; leave them unresolved.
    [ "$CONFLICT_STRATEGY" = "ask" ] && CONFLICT_STRATEGY=skip

    local conflict_dump="$STATE_DIR/conflicts.tmp" rc=0
    : > "$conflict_dump"

    # Run in the current shell (not a pipeline) so the counters survive.
    sync_engine "$conflict_dump" >/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$conflict_dump" "$NEW_SNAPSHOT" "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"
        echo "ERROR: $ABORT_REASON" >&2
        echo "No changes were made." >&2
        if [ "$rc" -eq 2 ]; then
            local n
            n=$(wc -l < "$PENDING_DELETES")
            record_result "Stopped: $n deletions need confirmation"
            echo >&2
            echo "Files that would be deleted:" >&2
            head -20 "$PENDING_DELETES" | sed 's/^/  /' >&2
            [ "$n" -gt 20 ] && echo "  ...and $((n - 20)) more" >&2
            echo >&2
            echo "To go ahead, run a sync from the menu, or run:" >&2
            echo "  $SCRIPT_PATH --headless --allow-deletes" >&2
        else
            record_result "Stopped: $ABORT_REASON"
        fi
        echo "Log: $LOG_FILE" >&2
        return 1
    fi

    load_conflicts "$conflict_dump"
    if [ "${#CONFLICTS[@]}" -gt 0 ] && [ "$DRY_RUN" != true ]; then
        resolve_all_conflicts
    fi
    rm -f "$conflict_dump"

    finalize_snapshot
    release_lock

    if [ "$DRY_RUN" = true ]; then
        record_result "Preview: $(result_text)"
        format_plan
    else
        record_result "$(result_text)"
        echo "=== Sync Summary ==="
        sync_summary | sed 's/^/  /'
        if [ "$(plan_count failed)" -gt 0 ]; then
            echo "Problems (retried on the next sync):"
            grep "^failed"$'\t' "$PLAN_FILE" | cut -f2- | sed 's/^/  /'
        fi
        [ "$CONFLICT_STRATEGY" = "skip" ] && [ "$COUNT_CONFLICTS" -gt 0 ] && \
            echo "  ($COUNT_CONFLICTS conflict(s) left unresolved; set PROTON_SYNC_CONFLICT or sync from the menu to resolve)"
    fi
    echo "Log: $LOG_FILE"

    [ "$COUNT_ERRORS" -eq 0 ]
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--headless] [--dry-run] [--allow-deletes] [--help]

  (no options)     Start the interactive menu.
  --headless       Run one sync without the menu (for cron/systemd) and exit.
                   Also used automatically when there is no terminal.
  --dry-run        Preview only; make no changes (same as PROTON_SYNC_DRY_RUN=true).
  --allow-deletes  Don't stop when a sync would delete more files than the
                   safety limit set in Settings.
  --help           Show this help.

Settings are read from $CONFIG_FILE
USAGE
}

# ============================================================
# ENTRY POINT
# ============================================================

HEADLESS=false
while [ $# -gt 0 ]; do
    case "$1" in
        --headless|--sync) HEADLESS=true ;;
        --dry-run) FORCE_DRY_RUN=true; DRY_RUN=true ;;
        --allow-deletes) ALLOW_DELETES=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

load_config
validate_settings
remember_saved_settings
apply_env_overrides
validate_settings
mkdir -p "$STATE_ROOT"
init_state_paths

# No terminal (cron, systemd, piped) means the menu can't work.
if [ ! -t 0 ] || [ ! -t 1 ]; then
    HEADLESS=true
fi

if ! command -v proton-drive >/dev/null 2>&1; then
    echo "ERROR: 'proton-drive' command not found in PATH." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is required but not installed." >&2
    exit 1
fi

if [ "$HEADLESS" = true ]; then
    headless_sync
    exit $?
fi

if ! find_ui_tool; then
    echo "ERROR: the menu needs 'dialog' or 'whiptail'. Install one with:"
    echo "  sudo apt install dialog     # Debian/Ubuntu"
    echo "  sudo dnf install dialog     # Fedora"
    echo "Or run a single sync without the menu: $0 --headless"
    exit 1
fi

# Verify the login before showing the menu; offer to log in if needed.
ui_infobox "Please Wait" "Checking your Proton Drive login..."
if ! ensure_authenticated; then
    clear
    echo "Proton Drive login is required to continue."
    echo "Exiting."
    exit 1
fi

main_menu
