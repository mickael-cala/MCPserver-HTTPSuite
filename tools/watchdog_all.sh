#!/usr/bin/env bash
# ============================================================================
#  watchdog_all.sh - Surveille les 8 serveurs MCP et relance ceux qui meurent
#  (niveau 3 I8-lite, SECURITY-AUDIT.md : une erreur runtime ne devient plus
#  un arret silencieux).
#
#  Usage    : bash tools/watchdog_all.sh [intervalle_secondes]   (defaut : 10)
#  A lancer depuis le MEME environnement que start_all.sh (MCP_ROOT,
#  MCP_DB_PATH... sont herites par les relances). Arret : Ctrl+C.
# ============================================================================
set -u

cd "$(dirname "$0")/.."
mkdir -p build/logs

# Les ports par defaut sont distincts : ne pas imposer MCP_HTTP_PORT ici.
unset MCP_HTTP_PORT
INTERVAL="${1:-10}"

while true; do
    for S in fileMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP; do
        if [ -x "build/$S" ] && ! pgrep -x "$S" >/dev/null 2>&1; then
            echo "[$(date '+%F %T')] $S absent : relance"
            ./build/$S >"build/logs/$S.log" 2>&1 &
            echo $! >"build/logs/$S.pid"
        fi
    done
    sleep "$INTERVAL"
done
