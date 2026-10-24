@echo off
setlocal
rem ============================================================================
rem  stop_all.bat - Arrete les processus des 8 serveurs MCP HTTP
rem  Cible uniquement les executables du suite (noms uniques).
rem ============================================================================
cd /d "%~dp0"

for %%S in (fileMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP) do (
    taskkill /F /IM "%%S.exe" >nul 2>&1
)

echo Serveurs arretes.
