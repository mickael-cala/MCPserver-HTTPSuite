@echo off
setlocal
rem ============================================================================
rem  watchdog_all.bat - Surveille les 8 serveurs MCP et relance ceux qui meurent
rem  (niveau 3 I8-lite, SECURITY-AUDIT.md : une erreur runtime ne devient plus
rem  un arret silencieux).
rem
rem  Usage    : tools\watchdog_all.bat [intervalle_secondes]   (defaut : 10)
rem  A lancer dans une fenetre dediee, depuis le MEME environnement que
rem  start_all (MCP_ROOT, MCP_DB_PATH... sont herites par les relances).
rem  Arret : Ctrl+C. Un serveur qui refuse de demarrer (port pris, env
rem  invalide) est relance a chaque cycle : verifier build\logs\<serveur>.log.
rem ============================================================================
cd /d "%~dp0.."
if not exist "build\logs" mkdir "build\logs"

rem Les ports par defaut sont distincts : ne pas imposer MCP_HTTP_PORT ici.
set "MCP_HTTP_PORT="
set "INTERVAL=10"
if not "%~1"=="" set "INTERVAL=%~1"

:loop
for %%S in (fileMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP) do (
    tasklist /FI "IMAGENAME eq %%S.exe" 2>nul | find /I "%%S.exe" >nul
    if errorlevel 1 (
        if exist "build\%%S.exe" (
            echo [%date% %time%] %%S absent : relance
            powershell -NoProfile -Command "Start-Process -FilePath 'build\%%S.exe' -RedirectStandardOutput 'build\logs\%%S.out.log' -RedirectStandardError 'build\logs\%%S.log' -WindowStyle Hidden"
        )
    )
)
timeout /t %INTERVAL% /nobreak >nul
goto loop
