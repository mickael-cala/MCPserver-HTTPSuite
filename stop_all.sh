#!/usr/bin/env bash
# ============================================================================
#  stop_all.sh - Arrete les serveurs lances par start_all.sh (PIDs)
# ============================================================================
set -u

cd "$(dirname "$0")"

for S in fileMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP; do
    PIDFILE="build/logs/$S.pid"
    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE")"
        if kill "$PID" 2>/dev/null; then
            echo "Arret de $S (PID $PID)"
        fi
        rm -f "$PIDFILE"
    fi
done
