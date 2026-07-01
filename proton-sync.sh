#!/bin/bash
set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

LOCAL_DIR="$HOME/Proton Drive/root"
REMOTE_DIR="/my-files"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/proton-sync"
SNAPSHOT="$STATE_DIR/snapshot"

# Global temp/state files
KNOWN_REMOTE_DIRS="$STATE_DIR/known_remote_dirs"
LOCAL_MANIFEST="$STATE_DIR/local_manifest"
REMOTE_MANIFEST="$STATE_DIR/remote_manifest"
NEW_SNAPSHOT="$STATE_DIR/snapshot.new"

mkdir -p "$STATE_DIR"
touch "$SNAPSHOT"
> "$KNOWN_REMOTE_DIRS"

# In-memory maps
declare -A SNAPSHOT_LOCAL_FP
declare -A SNAPSHOT_REMOTE_FP
declare -A SNAPSHOT_SEEN
declare -A LOCAL_ITEMS
declare -A REMOTE_ITEMS
declare -A KNOWN_DIRS

# ============================================================
# DEBUG
# ============================================================

DEBUG="${PROTON_SYNC_DEBUG:-false}"

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

# ============================================================
# TIMESTAMP / FINGERPRINT FUNCTIONS
# ============================================================

get_local_fingerprint() {
    local file="$1"
    # Single stat call for both size and mtime
    stat -c '%s|%Y' "$file"
}

# ============================================================
# REMOTE LISTING (RECURSIVE) — now includes size+mtime
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

# ============================================================
# DIRECTORY MANAGEMENT (in-memory cache)
# ============================================================

build_remote_dir_cache() {
    KNOWN_DIRS=()
    KNOWN_DIRS["/"]=1        # Use "/" to represent root instead of ""
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
    proton-drive filesystem create-folder "$full_parent" "$folder_name"

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
        mkdir -p "$local_path"
    fi
}

# ============================================================
# IN-MEMORY LOADERS
# ============================================================

load_snapshot() {
    [ -f "$SNAPSHOT" ] || return
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
# MAIN SYNC
# ============================================================

sync() {
    > "$NEW_SNAPSHOT"

    # --------------------------------------------------------
    # PHASE 1: Build manifests
    # --------------------------------------------------------
    echo "=== Building local manifest ==="
    > "$LOCAL_MANIFEST"
    find "$LOCAL_DIR" -mindepth 1 -not -path "*/.proton-sync/*" | sort | \
        while read -r path; do
            rel="${path#$LOCAL_DIR/}"
            if [ -d "$path" ]; then
                echo "folder|$rel" >> "$LOCAL_MANIFEST"
            else
                echo "file|$rel" >> "$LOCAL_MANIFEST"
            fi
        done

    echo "=== Building remote manifest ==="
    > "$REMOTE_MANIFEST"
    list_remote_recursive "$REMOTE_DIR" "" | sort > "$REMOTE_MANIFEST"

    # Load everything into memory
    load_snapshot
    load_manifests_to_memory
    build_remote_dir_cache

    debug_file "Local manifest" "$LOCAL_MANIFEST"
    debug_file "Remote manifest" "$REMOTE_MANIFEST"

    # --------------------------------------------------------
    # PHASE 2: Process local items
    # --------------------------------------------------------
    echo ""
    echo "=== Processing local items ==="
    while IFS='|' read -r type rel _size _mtime; do
        remote_path="$REMOTE_DIR/$rel"
        local_path="$LOCAL_DIR/$rel"

        if [ "$type" = "folder" ]; then
            if [ -z "${REMOTE_ITEMS[folder|${rel}]+x}" ]; then
                if was_previously_synced "$rel"; then
                    echo "[DELETED REMOTELY] folder: $rel → removing local"
                    rm -rf "$local_path"
                    continue
                else
                    ensure_remote_folders "$rel"
                fi
            else
                echo "[OK] folder: $rel"
            fi
            echo "folder|${rel}|" >> "$NEW_SNAPSHOT"

        elif [ "$type" = "file" ]; then
            if [ ! -f "$local_path" ]; then
                continue
            fi

            local local_fp
            local_fp=$(get_local_fingerprint "$local_path")
            local prev_local_fp="${SNAPSHOT_LOCAL_FP[$rel]:-}"
            local prev_remote_fp="${SNAPSHOT_REMOTE_FP[$rel]:-}"
            local remote_fp=""

            if [ -n "${REMOTE_ITEMS[file|${rel}]+x}" ]; then
                # File exists on both sides — fingerprint already in manifest
                remote_fp="${REMOTE_ITEMS[file|${rel}]}"

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

                if [ -n "$prev_local_fp" ] && [ -n "$prev_remote_fp" ]; then
                    if [ "$local_changed" = false ] && [ "$remote_changed" = false ]; then
                        echo "[OK] $rel"

                    elif [ "$local_changed" = true ] && [ "$remote_changed" = false ]; then
                        echo "[UPLOAD MODIFIED] $rel (changed locally)"
                        local parent
                        parent=$(dirname "$remote_path")
                        proton-drive filesystem upload -f replace "$local_path" "$parent"
                        # Refresh fingerprints
                        local info
                        info=$(proton-drive filesystem info "$remote_path" -j 2>/dev/null)
                        local rsize rmtime
                        rsize=$(echo "$info" | jq -r '.activeRevision.value.claimedSize // 0')
                        rmtime=$(echo "$info" | jq -r '.activeRevision.value.claimedModificationTime // ""')
                        local rmtime_epoch=0
                        [ -n "$rmtime" ] && rmtime_epoch=$(date -d "$rmtime" +%s 2>/dev/null || echo 0)
                        remote_fp="${rsize}|${rmtime_epoch}"
                        local_fp=$(get_local_fingerprint "$local_path")

                    elif [ "$local_changed" = false ] && [ "$remote_changed" = true ]; then
                        echo "[DOWNLOAD MODIFIED] $rel (changed remotely)"
                        local local_parent
                        local_parent=$(dirname "$local_path")
                        ensure_local_folders "$local_parent"
                        proton-drive filesystem download -f replace "$remote_path" "$local_parent"
                        local_fp=$(get_local_fingerprint "$local_path")

                    else
                        echo "[CONFLICT] $rel — changed on BOTH sides!"
                        echo "  Local FP:       $local_fp"
                        echo "  Prev Local FP:  $prev_local_fp"
                        echo "  Remote FP:      $remote_fp"
                        echo "  Prev Remote FP: $prev_remote_fp"
                        local local_parent base ext
                        local_parent=$(dirname "$local_path")
                        base="${rel%.*}"
                        ext="${rel##*.}"
                        echo "  Saving remote as ${base}.remote.${ext}"
                        proton-drive filesystem download "$remote_path" "$local_parent"
                        mv "$local_parent/$(basename "$rel")" \
                           "$local_parent/$(basename "${base}.remote.${ext}")" 2>/dev/null || true
                    fi
                else
                    echo "[FIRST SYNC] $rel — recording state"
                fi
            else
                # File doesn't exist remotely
                if was_previously_synced "$rel"; then
                    echo "[DELETED REMOTELY] $rel → removing local"
                    rm "$local_path"
                    continue
                else
                    echo "[UPLOAD NEW] $rel"
                    local parent_rel
                    parent_rel=$(dirname "$rel")
                    ensure_remote_folders "$parent_rel"
                    local remote_parent
                    remote_parent=$(dirname "$remote_path")
                    proton-drive filesystem upload "$local_path" "$remote_parent"
                    # Get remote fingerprint after upload
                    local info
                    info=$(proton-drive filesystem info "$remote_path" -j 2>/dev/null)
                    local rsize rmtime
                    rsize=$(echo "$info" | jq -r '.activeRevision.value.claimedSize // 0')
                    rmtime=$(echo "$info" | jq -r '.activeRevision.value.claimedModificationTime // ""')
                    local rmtime_epoch=0
                    [ -n "$rmtime" ] && rmtime_epoch=$(date -d "$rmtime" +%s 2>/dev/null || echo 0)
                    remote_fp="${rsize}|${rmtime_epoch}"
                    local_fp=$(get_local_fingerprint "$local_path")
                fi
            fi

            echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
        fi
    done < "$LOCAL_MANIFEST"

    # --------------------------------------------------------
    # PHASE 3: Process remote-only items
    # --------------------------------------------------------
    echo ""
    echo "=== Processing remote-only items ==="
    while IFS='|' read -r type rel size mtime; do
        local_path="$LOCAL_DIR/$rel"
        remote_path="$REMOTE_DIR/$rel"

        # Skip if already handled in Phase 2
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
                echo "[DELETED LOCALLY] folder: $rel → trashing remote"
                proton-drive filesystem trash "$remote_path"
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
                echo "[DELETED LOCALLY] $rel → trashing remote"
                proton-drive filesystem trash "$remote_path"
            else
                echo "[DOWNLOAD NEW] $rel"
                local local_parent
                local_parent=$(dirname "$local_path")
                ensure_local_folders "$local_parent"
                proton-drive filesystem download "$remote_path" "$local_parent"

                if [ -f "$local_path" ]; then
                    local local_fp remote_fp
                    local_fp=$(get_local_fingerprint "$local_path")
                    remote_fp="${size}|${mtime}"
                    echo "file|${rel}|${local_fp}|${remote_fp}" >> "$NEW_SNAPSHOT"
                else
                    echo "[WARNING] Download failed or skipped: $rel"
                fi
            fi
        fi
    done < "$REMOTE_MANIFEST"

    # --------------------------------------------------------
    # Finalize
    # --------------------------------------------------------
    mv "$NEW_SNAPSHOT" "$SNAPSHOT"
    rm -f "$LOCAL_MANIFEST" "$REMOTE_MANIFEST"

    echo ""
    echo "=== Sync complete ==="
}

# ============================================================
# RUN
# ============================================================

echo "Proton Drive Sync"
echo "Local:  $LOCAL_DIR"
echo "Remote: $REMOTE_DIR"
echo "State:  $STATE_DIR"
echo ""

sync
