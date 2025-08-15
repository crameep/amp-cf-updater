#!/usr/bin/env bash
set -euo pipefail
# cf-sync.sh — Pack-agnostic CurseForge updater for AMP Generic Module
# Requires: curl, jq, unzip, rsync, zip

need() { command -v "$1" >/dev/null || { echo "[cf-sync] Missing $1"; exit 1; }; }
for b in curl jq unzip rsync zip; do need "$b"; done

# ===== Vars from template =====
UPDATE_MODE="${UPDATE_MODE:-safe-sync}"  # safe-sync | clean-replace | new-folder
DRY_RUN="${DRY_RUN:-false}"

CF_API_KEY="${CF_API_KEY:-}"
CF_PAGE_URL="${CF_PAGE_URL:-}"
CF_SLUG="${CF_SLUG:-}"
CF_FILE_ID="${CF_FILE_ID:-}"

SYNC_PRUNE="${SYNC_PRUNE:-true}"
SYNC_EXCLUDE_GLOBS="${SYNC_EXCLUDE_GLOBS:-world*,server.properties,ops.json,whitelist.json,banned-*.json,config,local,journeymap,eula.txt}"
EXCLUDE_MOD_IDS="${EXCLUDE_MOD_IDS:-}"
INCLUDE_MOD_IDS="${INCLUDE_MOD_IDS:-}"

REMOVE_PATHS="${REMOVE_PATHS:-kubejs,defaultconfigs,mods,config}"
REMOVE_LIBRARIES_IF_LOADER_CHANGED="${REMOVE_LIBRARIES_IF_LOADER_CHANGED:-true}"

PRESERVE_PATHS="${PRESERVE_PATHS:-world,world_nether,world_the_end,server.properties,ops.json,whitelist.json,banned-players.json,banned-ips.json,config,local,journeymap,eula.txt}"

RULES_JSON="${RULES_JSON:-{\"delete_when\":[],\"delete_always\":[],\"transform\":[]}}"

PRE_UPDATE_HOOK="${PRE_UPDATE_HOOK:-}"
POST_UPDATE_HOOK="${POST_UPDATE_HOOK:-}"

SNAPSHOT_ENABLED="${SNAPSHOT_ENABLED:-true}"

HDR=(-H "x-api-key: ${CF_API_KEY}")
API="https://api.curseforge.com/v1"
STATE=".cf_state.json"
LOADER_STATE=".cf_loader.json"

CURL="curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120"

say(){ echo -e "$*"; }
run(){ [[ "${DRY_RUN,,}" == "true" ]] && say "[dry-run] $*" || eval "$@"; }
fail(){ echo "[cf-sync] ERROR: $*" >&2; exit 1; }

[[ -n "$CF_API_KEY" ]] || fail "CF_API_KEY required"

# Resolve slug (accept raw slug or any CF URL; drop ?query/#fragment; ignore trailing /files)
if [[ -n "$CF_PAGE_URL" ]]; then
  clean="${CF_PAGE_URL%%[\?#]*}"
  slug="$(awk -F'/' '{ for(i=NF;i>0;i--) if($i!="" && $i!="files"){print $i; break} }' <<< "$clean")"
elif [[ -n "$CF_SLUG" ]]; then
  slug="$CF_SLUG"
else
  fail "Provide CF_PAGE_URL or CF_SLUG"
fi
[[ -n "$slug" ]] || fail "Could not parse slug from: ${CF_PAGE_URL:-$CF_SLUG}"

# ===== Find project and server file =====
say "[cf-sync] Resolving project for slug=${slug}…"
modId="$($CURL "${HDR[@]}" "$API/mods/search?gameId=432&slug=${slug}" | jq -r '.data[0].id')"
[[ "$modId" != "null" && -n "$modId" ]] || fail "Project not found"

if [[ -z "$CF_FILE_ID" ]]; then
  say "[cf-sync] Selecting latest server file…"
  fileId="$($CURL "${HDR[@]}" "$API/mods/${modId}/files" \
    | jq -r '[.data[] | select((.displayName + .fileName | ascii_downcase) | contains("server"))] | max_by(.fileDate).id')"
else
  fileId="$CF_FILE_ID"
fi

# Fallback: if none matched "server" naming, pick newest file
if [[ -z "${fileId:-}" || "$fileId" == "null" ]]; then
  files_json="$($CURL "${HDR[@]}" "$API/mods/${modId}/files")"
  fileId="$(echo "$files_json" | jq -r '.data | max_by(.fileDate).id')"
  say "[cf-sync] WARNING: No explicit 'server' file match; falling back to newest fileId=${fileId}"
fi
[[ -n "$fileId" && "$fileId" != "null" ]] || fail "No suitable server file ID"

currentId="$(jq -r '.fileId // empty' "$STATE" 2>/dev/null || true)"
if [[ "$fileId" == "$currentId" ]]; then
  say "[cf-sync] Already up-to-date (fileId=${fileId})"; exit 0
fi

# ===== Download and unpack =====
say "[cf-sync] Downloading server pack fileId=${fileId}…"
dl="$($CURL "${HDR[@]}" "$API/mods/${modId}/files/${fileId}/download-url" | jq -r '.data')"
tmpzip="$(mktemp --suffix=.zip)"
run "$CURL \"$dl\" -o \"$tmpzip\""

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$tmpzip"' EXIT
run "unzip -q \"$tmpzip\" -d \"$tmpdir\""

# Normalize source root: if single top-level directory and no files at root, use that dir
src="$tmpdir"
top="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | wc -l)"
files="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type f | wc -l)"
if [[ "$top" -eq 1 && "$files" -eq 0 ]]; then
  src="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
fi

# ===== Detect loader/version in new pack =====
detect_loader(){
  local t="unknown" v="unknown"
  if compgen -G "$src/libraries/*/*/*/*/neoforge-*-server.jar" >/dev/null; then
    t="neoforge"; v="$(basename "$(ls -1 $src/libraries/*/*/*/*/neoforge-*-server.jar | head -n1)" | sed -E 's/.*neoforge-([0-9\.\-]+)-server\.jar/\1/')"
  elif compgen -G "$src/libraries/*/*/*/*/forge-*-server.jar" >/dev/null; then
    t="forge"; v="$(basename "$(ls -1 $src/libraries/*/*/*/*/forge-*-server.jar | head -n1)" | sed -E 's/.*forge-([0-9\.\-]+)-server\.jar/\1/')"
  elif compgen -G "$src/*fabric*.jar" >/dev/null || compgen -G "$src/libraries/*/*/*/*/*fabric*.jar" >/dev/null; then
    t="fabric"; v="unknown"
  fi
  jq -n --arg type "$t" --arg ver "$v" '{type:$type,version:$ver}'
}
new_loader="$(detect_loader)"
old_loader="$(cat "$LOADER_STATE" 2>/dev/null || echo '{"type":"unknown","version":"unknown"}')"

say "[cf-sync] New loader: $(echo "$new_loader" | jq -r '.type') $(echo "$new_loader" | jq -r '.version')"
say "[cf-sync] Old loader: $(echo "$old_loader" | jq -r '.type') $(echo "$old_loader" | jq -r '.version')"

loader_changed="false"
if [[ "$(echo "$new_loader" | jq -r '.type')" != "$(echo "$old_loader" | jq -r '.type')" ]] || \
   [[ "$(echo "$new_loader" | jq -r '.version')" != "$(echo "$old_loader" | jq -r '.version')" ]]; then
  loader_changed="true"
fi

# ===== Hooks: pre =====
if [[ -n "$PRE_UPDATE_HOOK" ]]; then
  say "[cf-sync] PRE_UPDATE_HOOK…"
  [[ "${DRY_RUN,,}" == "true" ]] && say "[dry-run] $PRE_UPDATE_HOOK" || bash -lc "$PRE_UPDATE_HOOK"
fi

# ===== Snapshot of preserved items =====
if [[ "${SNAPSHOT_ENABLED,,}" == "true" ]]; then
  say "[cf-sync] Snapshotting preserves…"
  backup="backup-preupdate-$(date +%s).zip"
  run "zip -qry \"$backup\" world* server.properties ops.json whitelist.json banned*.json config local journeymap eula.txt 2>/dev/null || true"
else
  say "[cf-sync] Snapshot disabled (SNAPSHOT_ENABLED=false)"
fi

# ===== Advanced rules =====
apply_rules(){
  local predicate paths
  local x

  # unconditional deletes
  while read -r x; do
    [[ -z "$x" ]] && continue
    while read -r p; do [[ -n "$p" ]] && { [[ -e "$p" ]] && run "rm -rf \"$p\"" || true; }; done < <(jq -r '.paths[]?' <<<"$x")
  done < <(jq -c '.delete_always[]?' <<<"$RULES_JSON" 2>/dev/null || true)

  # conditional deletes
  while read -r x; do
    [[ -z "$x" ]]    && continue
    predicate="$(jq -r '.predicate' <<<"$x")"
    case "$predicate" in
      loader_changed) [[ "$loader_changed" == "true" ]] || continue ;;
      always) ;;
      *) continue ;;
    esac
    while read -r p; do [[ -n "$p" ]] && { [[ -e "$p" ]] && run "rm -rf \"$p\"" || true; }; done < <(jq -r '.paths[]?' <<<"$x")
  done < <(jq -c '.delete_when[]?' <<<"$RULES_JSON" 2>/dev/null || true)

  # transforms
  while read -r x; do
    [[ -z "$x" ]] && continue
    srcp="$(jq -r '.src // empty' <<<"$x")"
    dstp="$(jq -r '.dst // empty' <<<"$x")"
    act="$(jq -r '.action // \"move\"' <<<"$x")"
    [[ -z "$srcp" || -z "$dstp" ]] && continue
    case "$act" in
      move) [[ -e "$srcp" ]] && run "mkdir -p \"$(dirname "$dstp")\" && mv \"$srcp\" \"$dstp\"" || true ;;
      copy) [[ -e "$srcp" ]] && run "mkdir -p \"$(dirname "$dstp")\" && cp -rf \"$srcp\" \"$dstp\"" || true ;;
      delete) [[ -e "$srcp" ]] && run "rm -rf \"$srcp\"" || true ;;
    esac
  done < <(jq -c '.transform[]?' <<<"$RULES_JSON" 2>/dev/null || true)
}

rules_ok(){ jq -e . >/dev/null 2>&1 <<<"$RULES_JSON"; }

# ===== Execute mode =====
case "$UPDATE_MODE" in
  safe-sync)
    say "[cf-sync] Mode: safe-sync"
    : > .cf-exclude
    IFS=',' read -ra GLOBARR <<< "$SYNC_EXCLUDE_GLOBS"
    for g in "${GLOBARR[@]}"; do echo "$g" >> .cf-exclude; done
    IFS=',' read -ra EXIDS <<< "$EXCLUDE_MOD_IDS"
    for id in "${EXIDS[@]}"; do [[ -n "$id" ]] && echo "mods/*${id}*.jar" >> .cf-exclude; done
    rules_ok && apply_rules || say "[cf-sync] WARNING: RULES_JSON invalid; skipping rules"
    dflag=""; [[ "${SYNC_PRUNE,,}" == "true" ]] && dflag="--delete"
    run "rsync -a $dflag --exclude-from=.cf-exclude \"$src\"/ ./"
    ;;

  clean-replace)
    say "[cf-sync] Mode: clean-replace"
    IFS=',' read -ra RM <<< "$REMOVE_PATHS"
    for p in "${RM[@]}"; do p="$(echo "$p" | xargs)"; [[ -n "$p" && -e "$p" ]] && run "rm -rf \"$p\"" || true; done
    if [[ "${REMOVE_LIBRARIES_IF_LOADER_CHANGED,,}" == "true" && "$loader_changed" == "true" ]]; then
      [[ -d "libraries" ]] && run "rm -rf libraries" || true
    fi
    rules_ok && apply_rules || say "[cf-sync] WARNING: RULES_JSON invalid; skipping rules"
    run "rsync -a \"$src\"/ ./"
    ;;

  new-folder)
    say "[cf-sync] Mode: new-folder"
    newroot="$(mktemp -d)"
    run "rsync -a \"$src\"/ \"$newroot\"/"
    IFS=',' read -ra KEEP <<< "$PRESERVE_PATHS"
    for k in "${KEEP[@]}"; do k="$(echo "$k" | xargs)"; [[ -e "$k" ]] && run "rsync -a \"$k\" \"$newroot\"/" || true; done
    ( cd "$newroot" && { rules_ok && apply_rules || echo "[cf-sync] WARNING: RULES_JSON invalid; skipping rules"; } )
    stamp="$(date +%s)"; olddir=".old-$stamp"; run "mkdir -p \"$olddir\""
    for f in .* *; do
      [[ "$f" == "." || "$f" == ".." || "$f" == "$(basename "$newroot")" || "$f" == "$olddir" ]] && continue
      [[ "$f" == "$(basename "$backup")" || "$f" == ".cf-exclude" || "$f" == ".cf_state.json" || "$f" == ".cf_loader.json" ]] && continue
      run "mv \"$f\" \"$olddir\"/" || true
    done
    run "rsync -a \"$newroot\"/ ./"
    ;;

  *) fail "Unknown UPDATE_MODE: $UPDATE_MODE" ;;
esac

IFS=',' read -ra INIDS <<< "$INCLUDE_MOD_IDS"
for id in "${INIDS[@]}"; do
  cand="$(find \"$src\"/mods -maxdepth 1 -type f -iname \"*${id}*.jar\" 2>/dev/null | head -n1 || true)"
  if [[ -n "$cand" ]]; then run "mkdir -p ./mods && cp -f \"$cand\" ./mods/"; fi
done

# ===== Hooks: post =====
if [[ -n "$POST_UPDATE_HOOK" ]]; then
  say "[cf-sync] POST_UPDATE_HOOK…"
  [[ "${DRY_RUN,,}" == "true" ]] && say "[dry-run] $POST_UPDATE_HOOK" || bash -lc "$POST_UPDATE_HOOK"
fi

# ===== Save state =====
[[ "${DRY_RUN,,}" == "true" ]] || {
  echo "{\"fileId\":$fileId}" > "$STATE"
  echo "$new_loader" > "$LOADER_STATE"
}

say "[cf-sync] Update complete → fileId=${fileId}"
