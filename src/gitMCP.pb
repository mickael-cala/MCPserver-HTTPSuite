; ============================================================================
;  SERVEUR MCP - Git (PureBasic HTTP)
;  Exploration de depots git locaux via git en sous-processus
; ============================================================================
;  Compilation : build.bat / build.sh
;  Transport   : JSON-RPC 2.0 sur HTTP (POST /mcp, JSON uniquement, sans SSE)
;  Config      : MCP_GIT_EXE = chemin de git (defaut: git dans le PATH)
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

IncludeFile "git_core.pbi"

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "GitMCPServer-PureBasic"
G_ServerVersion = "2.0.0"

If Not CheckRuntime()
  End 1
EndIf

Global G_GitExeEnv.s = GetEnvironmentVariable("MCP_GIT_EXE")
If G_GitExeEnv <> ""
  G_GitExe = G_GitExeEnv
EndIf

If Not GitCheckAvailable()
  LogError("git introuvable ou non executable (" + G_GitExe + "). Definissez MCP_GIT_EXE.")
  End 1
EndIf
LogDebug("git detecte : " + G_GitExe)

*G_ToolHandler = @GitDispatch()
*G_CatalogBuilder = @GitBuildCatalog()

If Not MCPHttpMainLoop(8107)
  End 1
EndIf

End
