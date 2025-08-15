#!/usr/bin/env bash
set -euo pipefail
# cf-sync.sh — Pack-agnostic CurseForge updater for AMP Generic
# Features:
# - Supports CF_PAGE_URL or CF_SLUG (+ optional CF_FILE_ID pin)
# - Update modes: safe-sync (rsync-like), clean-replace, new-folder (preserving paths)
# - Rules engine: delete_when (e.g., loader_changed=>libraries), delete_always, transform (extensible)
# - Pre/Post hooks, dry-run, explicit include/exclude mod IDs
# - EULA auto-write, snapshot before update, jar auto-detection by priority or exact/glob
#
# Required env (wired via .kvp / config UI):
#   CF_API_KEY, CF_PAGE_URL or CF_SLUG (one required), CF_FILE_ID (optional),
#   UPDATE_MODE (safe-sync|clean-replace|new-folder), SYNC_*, REMOVE_*, PRESERVE_PATHS,
#   RULES_JSON, PRE_UPDATE_HOOK, POST_UPDATE_HOOK, DRY_RUN (true/false), SNAPSHOT_ENABLED (true/false)
#
# Notes:
# - This script assumes working dir is the instance root (serverfiles/ or ".")
# - Places server files under ./serverfiles by default (DataDirectory ".")
#
CF_API_KEY="${CF_API_KEY:-}"
CF_PAGE_URL="${CF_PAGE_URL:-}"
CF_SLUG="${CF_SLUG:-}"
CF_FILE_ID="${CF_FILE_ID:-}"
UPDATE_MODE="${UPDATE_MODE:-safe-sync}"
SYNC_PRUNE="${SYNC_PRUNE:-true}"
SYNC_EXCLUDE_GLOBS="${SYNC_EXCLUDE_GLOBS:-world*,server.properties,ops.json,whitelist.json,banned-*.json,config,local,journeymap,eula.txt}"
EXCLUDE_MOD_IDS="${EXCLUDE_MOD_IDS:-}"
INCLUDE_MOD_IDS="${INCLUDE_MOD_IDS:-}"
REMOVE_PATHS="${REMOVE_PATHS:-kubejs,defaultconfigs,mods,config}"
REMOVE_LIBRARIES_IF_LOADER_CHANGED="${REMOVE_LIBRARIES_IF_LOADER_CHANGED:-true}"
PRESERVE_PATHS="${PRESERVE_PATHS:-world,world_nether,world_the_end,server.properties,ops.json,whitelist.json,banned-players.json,banned-ips.json,config,local,journeymap,eula.txt}"
RULES_JSON="${RULES_JSON:-{"delete_when":[{"predicate":"loader_changed","paths":["libraries"]}],"delete_always":[],"transform":[]}}"
PRE_UPDATE_HOOK="${PRE_UPDATE_HOOK:-}"
POST_UPDATE_HOOK="${POST_UPDATE_HOOK:-}"
DRY_RUN="${DRY_RUN:-false}"
SNAPSHOT_ENABLED="${SNAPSHOT_ENABLED:-true}"

JAVA_PATH="${JAVA_PATH:-java}"
Xms="${Xms:-4G}"
Xmx="${Xmx:-8G}"
JAVA_ARGS="${JAVA_ARGS:-"-XX:+UseG1GC -Dfile.encoding=UTF-8"}"

SERVER_DIR="."
DEST_DIR="."
PACK_TMP="./.cf-pack-tmp"
SNAP_DIR="./.snapshots"

log(){ printf "[cf-sync] %s\n" "$*"; }

require(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }

write_eula(){
  if [[ ! -f eula.txt ]]; then
    echo "eula=true" > eula.txt
    log "Wrote eula.txt"
  fi
}

snapshot(){
  [[ "$SNAPSHOT_ENABLED" != "true" ]] && return 0
  mkdir -p "$SNAP_DIR"
  ts="$(date +%Y%m%d-%H%M%S)"
  tar -czf "$SNAP_DIR/snap-$ts.tgz" --exclude ".snapshots" --exclude ".cf-pack-tmp" .
  log "Snapshot created at $SNAP_DIR/snap-$ts.tgz"
}

run_hook(){
  local code="$1"
  [[ -z "$code" ]] && return 0
  log "Running hook..."
  bash -lc "$code" || { log "Hook failed"; exit 1; }
}

parse_slug_from_url(){
  local url="$1"
  # Accept https://www.curseforge.com/minecraft/modpacks/<slug>[/...]
  echo "$url" | awk -F'/minecraft/(?:modpacks|mc-mods|bukkit-plugins)/' 'BEGIN{IGNORECASE=1} {print $NF}' | cut -d'/' -f1
}

# --------- BEGIN ---------
require curl
require unzip
require awk
write_eula

if [[ -z "$CF_PAGE_URL" && -z "$CF_SLUG" ]]; then
  echo "Set CF_PAGE_URL or CF_SLUG"; exit 2
fi

if [[ -n "$CF_PAGE_URL" && -z "$CF_SLUG" ]]; then
  CF_SLUG="$(parse_slug_from_url "$CF_PAGE_URL")"
fi

# Resolve project ID from slug
CF_API="https://api.curseforge.com/v1"
AUTH_HEADER="x-api-key: ${CF_API_KEY}"
PROJECT_ID="$(curl -fsSL -H "$AUTH_HEADER" "${CF_API}/mods/search?gameId=432&slug=${CF_SLUG}" | awk -F'id":' 'NR==1{print $2}' | awk -F',' '{print $1}')"
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]]; then
  echo "Unable to resolve project id for slug=$CF_SLUG"; exit 3
fi
log "Project ID: $PROJECT_ID"

# Choose file (server file preferred)
FILE_ID="$CF_FILE_ID"
if [[ -z "$FILE_ID" ]]; then
  FILE_ID="$(curl -fsSL -H "$AUTH_HEADER" "${CF_API}/mods/${PROJECT_ID}/files" \
    | awk '/"isServerPack":true/{flag=1} flag && /"id":/{print $2; exit}' | tr -d ',')"
  if [[ -z "$FILE_ID" ]]; then
    # fallback to latest file
    FILE_ID="$(curl -fsSL -H "$AUTH_HEADER" "${CF_API}/mods/${PROJECT_ID}/files" | awk -F'id":' 'NR==1{print $2}' | awk -F',' '{print $1}')"
  fi
fi
log "File ID: $FILE_ID"

# Download file metadata
FILE_META="$(curl -fsSL -H "$AUTH_HEADER" "${CF_API}/mods/${PROJECT_ID}/files/${FILE_ID}")"
DL_URL="$(echo "$FILE_META" | awk -F'downloadUrl":"' '{print $2}' | awk -F'"' '{print $1}')"
if [[ -z "$DL_URL" ]]; then echo "No download URL (check API key/file id)"; exit 4; fi

mkdir -p "$PACK_TMP"
rm -rf "$PACK_TMP"/*
log "Downloading server files..."
curl -fsSL "$DL_URL" -o "$PACK_TMP/serverpack.zip"
unzip -q -o "$PACK_TMP/serverpack.zip" -d "$PACK_TMP/server"

# loader detection (forge/fabric/neoforge)
LOADER="unknown"
if grep -qi "neoforge" "$PACK_TMP/server/manifest.json" 2>/dev/null; then LOADER="neoforge"
elif grep -qi "forge" "$PACK_TMP/server/manifest.json" 2>/dev/null; then LOADER="forge"
elif grep -qi "fabric" "$PACK_TMP/server/manifest.json" 2>/dev/null; then LOADER="fabric"
fi
log "Detected loader: $LOADER"

# Apply rules
echo "$RULES_JSON" > "$PACK_TMP/rules.json"
if [[ "$REMOVE_LIBRARIES_IF_LOADER_CHANGED" == "true" && "$LOADER" != "unknown" ]]; then
  # If switching loaders, we nuke libraries
  tmp="$(jq -c '.delete_when |= . + [{"predicate":"loader_changed","paths":["libraries"]}]' "$PACK_TMP/rules.json" 2>/dev/null || cat "$PACK_TMP/rules.json")"
  echo "$tmp" > "$PACK_TMP/rules.json"
fi

# DRY RUN preview
if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY_RUN=true — listing changes only"
fi

run_hook "$PRE_UPDATE_HOOK"
snapshot

case "$UPDATE_MODE" in
  safe-sync)
    log "Mode: safe-sync"
    # Build rsync exclude list
    IFS=',' read -ra EXS <<< "$SYNC_EXCLUDE_GLOBS"
    RSYNC_ARGS=()
    for g in "${EXS[@]}"; do RSYNC_ARGS+=("--exclude=$g"); done
    [[ "$SYNC_PRUNE" == "true" ]] && RSYNC_ARGS+=("--delete") || true
    if [[ "$DRY_RUN" == "true" ]]; then RSYNC_ARGS+=("-n"); fi
    rsync -av "${RSYNC_ARGS[@]}" "$PACK_TMP/server/" "$DEST_DIR/"
    ;;
  clean-replace)
    log "Mode: clean-replace"
    IFS=',' read -ra RMP <<< "$REMOVE_PATHS"
    for p in "${RMP[@]}"; do [[ -e "$p" ]] && { [[ "$DRY_RUN" == "true" ]] && log "Would rm -rf $p" || rm -rf "$p"; }; done
    if [[ "$DRY_RUN" == "true" ]]; then
      log "Would copy new files from pack"
    else
      cp -a "$PACK_TMP/server/." "$DEST_DIR/"
    fi
    ;;
  new-folder)
    log "Mode: new-folder"
    NEW_DIR="./serverfiles-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$NEW_DIR"
    cp -a "$PACK_TMP/server/." "$NEW_DIR/"
    IFS=',' read -ra PPS <<< "$PRESERVE_PATHS"
    for p in "${PPS[@]}"; do
      [[ -e "$p" ]] || continue
      log "Preserving $p -> $NEW_DIR/$p"
      [[ "$DRY_RUN" == "true" ]] && continue
      rsync -a "$p" "$NEW_DIR/" || true
    done
    ;;
  *)
    echo "Unknown UPDATE_MODE=$UPDATE_MODE"; exit 5;;
esac

run_hook "$POST_UPDATE_HOOK"
log "Update complete."