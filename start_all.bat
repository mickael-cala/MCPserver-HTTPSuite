@echo off
setlocal
rem ============================================================================
rem  start_all.bat - Lance les 8 serveurs MCP HTTP en arriere-plan
rem  Ports par defaut : 8101-8108. Logs dans build\logs\.
rem ============================================================================
cd /d "%~dp0"
if not exist "build\logs" mkdir "build\logs"

rem Les ports par defaut sont distincts : ne pas imposer MCP_HTTP_PORT ici.
set "MCP_HTTP_PORT="

for %%S in (fileMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP) do (
    if not exist "build\%%S.exe" (
        echo [ERREUR] build\%%S.exe introuvable : lancez build.bat
        exit /b 1
    )
    echo Demarrage de %%S ...
    powershell -NoProfile -Command "Start-Process -FilePath 'build\%%S.exe' -RedirectStandardOutput 'build\logs\%%S.out.log' -RedirectStandardError 'build\logs\%%S.log' -WindowStyle Hidden"
)

echo Serveurs lances. Sante : http://127.0.0.1:8101/health ... http://127.0.0.1:8108/health
