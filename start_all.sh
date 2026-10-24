#!/usr/bin/env bash
# ============================================================================
#  start_all.sh - Lance les 8 serveurs MCP HTTP en arriere-plan
#  Ports par defaut : 8101-8108. Logs dans build/logs/.
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build/logs

# Les ports par defaut sont distincts : ne pas imposer MCP_HTTP_PORT ici.
unset MCP_HTTP_PORT

for S in fileMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP; do
    if [ ! -x "build/$S" ]; then
        echo "[ERREUR] build/$S introuvable : lancez ./build.sh" >&2
        exit 1
    fi
    ./build/$S >"build/logs/$S.log" 2>&1 &
    echo $! >"build/logs/$S.pid"
    echo "Demarrage de $S (PID $!)"
done

echo "Serveurs lances. Sante : http://127.0.0.1:8101/health ... http://127.0.0.1:8108/health"
