#!/usr/bin/env bash
set -euo pipefail

JAVA="${JAVA_PATH:-java}"
XMS="${Xms:-4G}"
XMX="${Xmx:-8G}"
ARGS="${JAVA_ARGS:-}"

SERVER_JAR="${SERVER_JAR:-}"   # exact filename override
JAR_GLOB="${JAR_GLOB:-}"       # glob pattern — pick newest match
JAR_PRIORITY="${JAR_PRIORITY:-libraries-first}"  # libraries-first | root-first | newest-anywhere

log(){ echo "[start] $*"; }
die(){ echo "[start] ERROR: $*" >&2; exit 1; }

ensure_eula(){
  if [[ ! -f eula.txt ]]; then
    log "No eula.txt found — creating with eula=true"
    echo "eula=true" > eula.txt
  fi
}

# Return newest match (mtime) among args/patterns
pick_newest(){
  local newest="" f
  for pat in "$@"; do
    # shellcheck disable=SC2086
    for f in $pat; do
      [[ -f "$f" ]] || continue
      if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
        newest="$f"
      fi
    done
  done
  [[ -n "$newest" ]] && printf '%s\n' "$newest" || true
}

auto_detect(){
  case "$JAR_PRIORITY" in
    libraries-first)
      pick_newest \
        "libraries/*/*/*/*/neoforge-*-server.jar" \
        "libraries/*/*/*/*/forge-*-server.jar" \
        "*.jar"
      ;;
    root-first)
      pick_newest \
        "*.jar" \
        "libraries/*/*/*/*/neoforge-*-server.jar" \
        "libraries/*/*/*/*/forge-*-server.jar"
      ;;
    newest-anywhere)
      pick_newest \
        "libraries/*/*/*/*/*.jar" \
        "*.jar"
      ;;
    *)
      pick_newest \
        "libraries/*/*/*/*/neoforge-*-server.jar" \
        "libraries/*/*/*/*/forge-*-server.jar" \
        "*.jar"
      ;;
  esac
}

select_jar(){
  # 1) exact filename override
  if [[ -n "$SERVER_JAR" ]]; then
    [[ -f "$SERVER_JAR" ]] || die "SERVER_JAR set but not found: $SERVER_JAR"
    echo "$SERVER_JAR"; return 0
  fi

  # 2) glob pattern — pick newest match
  if [[ -n "$JAR_GLOB" ]]; then
    local m=""
    # shellcheck disable=SC2086
    m=$(pick_newest $JAR_GLOB) || true
    [[ -n "$m" ]] || die "JAR_GLOB set but no matches found: $JAR_GLOB"
    echo "$m"; return 0
  fi

  # 3) fallback: auto-detect
  local auto=""
  auto="$(auto_detect || true)"
  [[ -n "$auto" ]] && { echo "$auto"; return 0; }

  return 1
}

ensure_eula

JAR="$(select_jar || true)"
[[ -n "${JAR:-}" ]] || die "Could not locate a server jar (set SERVER_JAR or JAR_GLOB)."

log "Launching: $JAR with -Xms$XMS -Xmx$XMX"
exec "$JAVA" -Xms"$XMS" -Xmx"$XMX" $ARGS -jar "$JAR" nogui
