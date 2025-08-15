#!/usr/bin/env bash
set -euo pipefail

JAVA="${JAVA_PATH:-java}"
XMS="${Xms:-4G}"
XMX="${Xmx:-8G}"
ARGS="${JAVA_ARGS:-"-XX:+UseG1GC -Dfile.encoding=UTF-8"}"

SERVER_JAR="${SERVER_JAR:-}"
JAR_GLOB="${JAR_GLOB:-}"
JAR_PRIORITY="${JAR_PRIORITY:-libraries-first}"

log(){ printf "[start] %s\n" "$*"; }

write_eula(){
  if [[ ! -f eula.txt ]]; then
    echo "eula=true" > eula.txt
    log "Wrote eula.txt"
  fi
}

pick_jar(){
  # 1) explicit file
  if [[ -n "$SERVER_JAR" && -f "$SERVER_JAR" ]]; then
    echo "$SERVER_JAR"; return
  fi
  # 2) glob
  if [[ -n "$JAR_GLOB" ]]; then
    mapfile -t matches < <(ls -1t $JAR_GLOB 2>/dev/null || true)
    if (( ${#matches[@]} )); then echo "${matches[0]}"; return; fi
  fi
  # 3) priority
  case "$JAR_PRIORITY" in
    libraries-first)
      # NeoForge/Forge usually place launcher in libraries/<...>.jar
      mapfile -t libs < <(find libraries -maxdepth 3 -type f -name "*.jar" -printf "%T@ %p\n" 2>/dev/null | sort -nr | awk '{print $2}')
      if (( ${#libs[@]} )); then echo "${libs[0]}"; return; fi
      ;;
    root-first)
      mapfile -t roots < <(ls -1t *.jar 2>/dev/null || true)
      if (( ${#roots[@]} )); then echo "${roots[0]}"; return; fi
      ;;
    newest-anywhere)
      mapfile -t any < <(find . -type f -name "*.jar" -printf "%T@ %p\n" 2>/dev/null | sort -nr | awk '{print $2}')
      if (( ${#any[@]} )); then echo "${any[0]}"; return; fi
      ;;
  esac
  # 4) last resort
  mapfile -t roots < <(ls -1t *.jar 2>/dev/null || true)
  if (( ${#roots[@]} )); then echo "${roots[0]}"; return; fi
  return 1
}

write_eula
JAR="$(pick_jar || true)"
if [[ -z "${JAR:-}" ]]; then
  echo "[start] Could not locate a server jar. Set SERVER_JAR or JAR_GLOB, or check your pack."
  exit 10
fi

log "Using JAR: $JAR"
exec "$JAVA" -Xms"$XMS" -Xmx"$XMX" $ARGS -jar "$JAR" nogui