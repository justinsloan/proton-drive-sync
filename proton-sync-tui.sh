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

# Field separator for manifests, snapshot and conflict list. The ASCII unit
# separator can't realistically appear in a filename, unlike "|".
SEP=$'\x1f'

mkdir -p "$STATE_DIR" "$LOG_DIR"
touch "$SNAPSHOT"

DIALOG=/usr/bin/dialog
DIALOG_BACKTITLE="Proton Drive Sync"
DIALOG_HEIGHT=20
DIALOG_WIDTH=76

DEBUG="${PROTON_SYNC_DEBUG:-false}"
# PROTON_SYNC_DRY_RUN=true forces every sync (menu or headless) to be a dry run.
FORCE_DRY_RUN="${PROTON_SYNC_DRY_RUN:-false}"
DRY_RUN="$FORCE_DRY_RUN"

# How many transfers / remote listings run at the same time.
SYNC_JOBS="${PROTON_SYNC_JOBS:-4}"
case "$SYNC_JOBS" in ''|*[!0-9]*|0) SYNC_JOBS=4 ;; esac

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

# Queued file transfers (run in parallel by run_job_queue)
declare -a JOB_QUEUE=()
declare -A JOB_LFP=() JOB_RFP=() JOB_PREV_L=() JOB_PREV_R=()
JOB_RESULTS="$STATE_DIR/job_results"
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
        snap_file "${rel}" "${lfp}" "${rfp}"
    else
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
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
        both      "Keep BOTH   (local wins; remote saved as .remote copy)" \
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
        local spec kind rel running=0
        for spec in "${JOB_QUEUE[@]}"; do
            kind="${spec%%"$SEP"*}"; rel="${spec#*"$SEP"}"
            if [ "$running" -ge "$SYNC_JOBS" ]; then
                wait -n; running=$((running - 1))
            fi
            case "$kind" in
                up_*)   gauge_update "Upload: $rel" ;;
                down_*) gauge_update "Download: $rel" ;;
                trash)  gauge_update "Trash remote: $rel" ;;
            esac
            run_one_job "$kind" "$rel" &
            running=$((running + 1))
        done
        wait
    )
    PROCESSED_ITEMS=$((PROCESSED_ITEMS + ${#JOB_QUEUE[@]}))
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
    JOB_QUEUE=(); JOB_LFP=(); JOB_RFP=(); JOB_PREV_L=(); JOB_PREV_R=()
    ABORT_REASON=""
    COUNT_OK=0; COUNT_UPLOADED=0; COUNT_DOWNLOADED=0
    COUNT_MOVED_REMOTE=0; COUNT_MOVED_LOCAL=0
    COUNT_DELETED_LOCAL=0; COUNT_TRASHED_REMOTE=0
    COUNT_CONFLICTS=0; COUNT_ERRORS=0; COUNT_FIRST_SYNC=0
    PROCESSED_ITEMS=0

    log "=== Sync started $(date) ==="
    [ "$DRY_RUN" = true ] && log "=== DRY RUN MODE ==="

    gauge_update "Building local manifest..."
    # One find pass collects type, size and mtime for every local item
    # (instead of a stat per file) and skips excluded names without
    # descending into them. Records are "path<TAB>type size mtime".
    local -a prune=()
    local pattern
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        prune+=(-name "$pattern" -o)
    done
    unset 'prune[${#prune[@]}-1]'
    local rec meta ftype fsize fmtime
    find "$LOCAL_DIR" -mindepth 1 \( "${prune[@]}" \) -prune -o \
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

    gauge_update "Building remote manifest..."
    if ! list_remote_tree > "$REMOTE_MANIFEST.unsorted"; then
        rm -f "$REMOTE_MANIFEST.unsorted"
        ABORT_REASON="Could not list one or more remote folders (see log). Stopped so their files aren't treated as deleted."
        log "[FATAL] $ABORT_REASON"
        echo "XXX"; echo "100"; echo "ABORTED: remote listing failed (see log)"; echo "XXX"
        return 1
    fi
    sort "$REMOTE_MANIFEST.unsorted" > "$REMOTE_MANIFEST"
    rm -f "$REMOTE_MANIFEST.unsorted"

    if ! check_remote_manifest_sane; then
        ABORT_REASON="Remote listing came back empty but sync history exists. If the remote really is empty, remove $SNAPSHOT to reset."
        log "[FATAL] $ABORT_REASON"
        echo "XXX"; echo "100"; echo "ABORTED: unsafe remote state (see log)"; echo "XXX"
        return 1
    fi

    load_snapshot
    load_manifests_to_memory
    build_remote_dir_cache

    TOTAL_ITEMS=$(( $(wc -l < "$LOCAL_MANIFEST") + $(wc -l < "$REMOTE_MANIFEST") + 2 ))

    # ---------- PHASE 2: local items ----------
    while IFS="$SEP" read -r type rel lsize lmtime; do
        gauge_update "Local: $rel"
        remote_path="$REMOTE_DIR/$rel"
        local_path="$LOCAL_DIR/$rel"

        if [ "$type" = "folder" ]; then
            if [ -n "${REMOTE_ITEMS[folder|${rel}]+x}" ]; then
                log "[OK] folder: $rel"
                snap_folder "$rel"
            elif was_previously_synced "$rel"; then
                DEL_LOCAL_FOLDERS+=("$rel")
            else
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
                    queue_job up_mod "$rel" "$local_fp" "$remote_fp" "$prev_local_fp" "$prev_remote_fp"
                elif [ "$local_changed" = false ] && [ "$remote_changed" = true ]; then
                    log "[DOWNLOAD MODIFIED] $rel"
                    queue_job down_mod "$rel" "$local_fp" "$remote_fp" "$prev_local_fp" "$prev_remote_fp"
                else
                    log "[CONFLICT] $rel"
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
        gauge_update "Remote: $rel"
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
    gauge_update "Detecting moves..."
    local old_rel new_rel fp match
    declare -A OLD_FP_COUNT=() NEW_FP_COUNT=() FP_TO_OLD=() MOVED_FROM=()

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
        match=""
        if [ "${OLD_FP_COUNT[$fp]:-0}" -eq 1 ] && [ "${NEW_FP_COUNT[$fp]:-0}" -eq 1 ]; then
            match="${FP_TO_OLD[$fp]}"
        fi
        if [ -n "$match" ]; then
            log "[MOVE REMOTE] $match -> $new_rel"
            if do_remote_move "$match" "$new_rel"; then
                COUNT_MOVED_REMOTE=$((COUNT_MOVED_REMOTE + 1))
                snap_file "$new_rel" "$fp" "${SNAPSHOT_REMOTE_FP[$match]:-}"
                MOVED_FROM["$match"]=1
            else
                COUNT_ERRORS=$((COUNT_ERRORS + 1))
            fi
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
            log "[MOVE LOCAL] $match -> $new_rel"
            ensure_local_folders "$(dirname "$LOCAL_DIR/$new_rel")"
            if run mv "$LOCAL_DIR/$match" "$LOCAL_DIR/$new_rel"; then
                COUNT_MOVED_LOCAL=$((COUNT_MOVED_LOCAL + 1))
                local lfp
                if [ "$DRY_RUN" = false ]; then lfp=$(get_local_fingerprint "$LOCAL_DIR/$new_rel"); else lfp="${SNAPSHOT_LOCAL_FP[$match]:-}"; fi
                snap_file "$new_rel" "$lfp" "$fp"
                MOVED_FROM["$match"]=1
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
        [ -f "$LOCAL_DIR/$rel" ] || continue
        log "[UPLOAD NEW] $rel"
        # Folder creation updates KNOWN_DIRS, so it stays serial.
        ensure_remote_folders "$(dirname "$rel")"
        queue_job up_new "$rel" "${NEW_LOCAL_FP[$rel]}" "" "" ""
    done

    for rel in "${REMAINING_NEW_REMOTE[@]+"${REMAINING_NEW_REMOTE[@]}"}"; do
        [ -z "$rel" ] && continue
        log "[DOWNLOAD NEW] $rel"
        ensure_local_folders "$(dirname "$LOCAL_DIR/$rel")"
        queue_job down_new "$rel" "" "${NEW_REMOTE_FP[$rel]}" "" ""
    done

    for rel in "${TRASH_REMOTE_FILES[@]+"${TRASH_REMOTE_FILES[@]}"}"; do
        [ -n "${MOVED_FROM[$rel]+x}" ] && continue
        [ -f "$LOCAL_DIR/$rel" ] && continue
        log "[DELETED LOCALLY] $rel -> trashing remote"
        queue_job trash "$rel" "" "" "" ""
    done

    # Run every queued file transfer (modified and new files, remote
    # trashes) in parallel, then record the results.
    run_job_queue
    process_job_results

    for rel in "${DELETED_REMOTELY_FILES[@]+"${DELETED_REMOTELY_FILES[@]}"}"; do
        [ -n "${MOVED_FROM[$rel]+x}" ] && continue
        local_path="$LOCAL_DIR/$rel"; [ -f "$local_path" ] || continue
        gauge_update "Delete local: $rel"
        log "[DELETED REMOTELY] $rel -> removing local"
        trash_local "$local_path" "$rel"
        COUNT_DELETED_LOCAL=$((COUNT_DELETED_LOCAL + 1))
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
    [ "$FORCE_DRY_RUN" = true ] && dry=true
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

    # Feed the gauge through a process substitution rather than a pipeline,
    # so sync_engine runs in this shell and its counters and status survive.
    local engine_rc=0
    sync_engine "$conflict_dump" > >("$DIALOG" --backtitle "$DIALOG_BACKTITLE" \
        --title "$title" --gauge "Starting..." 10 "$DIALOG_WIDTH" 0) || engine_rc=$?
    wait "$!" 2>/dev/null || true

    if [ "$engine_rc" -ne 0 ]; then
        # Aborted before any changes: keep the existing snapshot untouched.
        rm -f "$conflict_dump" "$NEW_SNAPSHOT" "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"
        release_lock
        "$DIALOG" --backtitle "$DIALOG_BACKTITLE" --title "Sync Aborted" --msgbox \
"$ABORT_REASON

No changes were made and the snapshot was left unchanged.

Log: $LOG_FILE" 14 "$DIALOG_WIDTH"
        return
    fi

    load_conflicts "$conflict_dump"
    [ "${#CONFLICTS[@]}" -gt 0 ] && resolve_all_conflicts
    rm -f "$conflict_dump"

    finalize_snapshot

    release_lock

    local summary
    summary=$(sync_summary)

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

Debug:       $DEBUG
Dry run:     $FORCE_DRY_RUN (forced via PROTON_SYNC_DRY_RUN)" 20 "$DIALOG_WIDTH"
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
    local sync_label="Run sync now"
    [ "$FORCE_DRY_RUN" = true ] && sync_label="Run sync now (DRY RUN forced by PROTON_SYNC_DRY_RUN)"
    while true; do
        local choice
        choice=$("$DIALOG" --backtitle "$DIALOG_BACKTITLE" \
            --title "Main Menu" \
            --cancel-label "Quit" \
            --menu "Local:  $LOCAL_DIR\nRemote: $REMOTE_DIR\n\nChoose an action:" \
            "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 11 \
            sync     "$sync_label" \
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
# HEADLESS MODE
# ============================================================

# Non-interactive sync for cron/systemd: no dialog, no prompts.
# Exits 0 on success, 1 on any failure or transfer error.
headless_sync() {
    echo "Proton Drive Sync (headless)"
    echo "Local:   $LOCAL_DIR"
    echo "Remote:  $REMOTE_DIR"
    echo "State:   $STATE_DIR"
    [ "$DRY_RUN" = true ] && echo "Mode:    DRY RUN — no changes will be made"
    echo

    if ! acquire_lock; then
        echo "ERROR: Another sync is already running (lock: $LOCK_FILE)" >&2
        echo "If you are sure no sync is running, remove it manually:" >&2
        echo "  rmdir '$LOCK_FILE'" >&2
        return 1
    fi

    if ! is_authenticated; then
        echo "ERROR: Cannot access $REMOTE_DIR — are you logged in?" >&2
        echo "Run: proton-drive auth login" >&2
        return 1
    fi

    # Conflicts can't be asked about without a terminal; leave them unresolved.
    if [ "$CONFLICT_STRATEGY" = "ask" ]; then
        CONFLICT_STRATEGY=skip
    fi

    local conflict_dump="$STATE_DIR/conflicts.tmp"
    > "$conflict_dump"

    # Run in the current shell (not a pipeline) so the counters survive.
    if ! sync_engine "$conflict_dump" >/dev/null; then
        rm -f "$conflict_dump" "$NEW_SNAPSHOT" "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"
        echo "ERROR: $ABORT_REASON" >&2
        echo "No changes were made." >&2
        echo "Log: $LOG_FILE" >&2
        return 1
    fi

    load_conflicts "$conflict_dump"
    [ "${#CONFLICTS[@]}" -gt 0 ] && resolve_all_conflicts
    rm -f "$conflict_dump"

    finalize_snapshot
    release_lock

    echo "=== Sync Summary ==="
    sync_summary | sed 's/^/  /'
    [ "$CONFLICT_STRATEGY" = "skip" ] && [ "$COUNT_CONFLICTS" -gt 0 ] && \
        echo "  ($COUNT_CONFLICTS conflict(s) left unresolved; set PROTON_SYNC_CONFLICT to resolve)"
    echo "Log: $LOG_FILE"

    [ "$COUNT_ERRORS" -eq 0 ]
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--headless] [--dry-run] [--help]

  (no options)  Start the interactive dialog menu.
  --headless    Run one sync without the menu (for cron/systemd) and exit.
                Also used automatically when there is no terminal.
  --dry-run     Preview only; make no changes (same as PROTON_SYNC_DRY_RUN=true).
  --help        Show this help.
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
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

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

if [ ! -x "$DIALOG" ]; then
    echo "ERROR: $DIALOG not found. Install it with:"
    echo "  sudo apt install dialog     # Debian/Ubuntu"
    echo "  sudo dnf install dialog     # Fedora"
    echo "Or run a single sync without the menu: $0 --headless"
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
