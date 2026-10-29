; ============================================================================
; SERVEUR MCP - Free Pascal (PureBasic HTTP)
; Compilation Pascal confinee a MCP_FPC_ROOT, sans shell et sans execution
; du binaire produit.
; ============================================================================
; Configuration :
;   MCP_FPC_ROOT         racine des sources/artefacts (defaut: cwd)
;   MCP_FPC              compilateur general (defaut: fpc dans le PATH)
;   MCP_FPC_WIN32        compilateur dedie win32
;   MCP_FPC_WIN64        compilateur dedie win64
;   MCP_FPC_LINUX32      compilateur dedie linux32
;   MCP_FPC_LINUX64      compilateur dedie linux64
;   MCP_FPC_LINUX_AARCH64    compilateur dedie linux-aarch64
;   MCP_FPC_MACOS_AARCH64    compilateur dedie macos-aarch64
;   MCP_FPC_TIMEOUT_MS   timeout 60000 par defaut, borne 1000..300000
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

IncludeFile "fs_guard.pbi"
IncludeFile "fpc_core.pbi"

; ---------------------------------------------------------------------------
; Configuration
; ---------------------------------------------------------------------------

; La racine est absolue et non symbolique des le demarrage. Sinon toute la
; validation faite ensuite sous cette racine pourrait commencer deja hors zone.
Global FpcRoot.s = FSPrepareRoot(GetEnvironmentVariable("MCP_FPC_ROOT"))
If FpcRoot = ""
  LogError("MCP_FPC_ROOT invalide : repertoire introuvable ou lien symbolique/junction.")
  End 1
EndIf

; Laisser la chaine vide lorsque MCP_FPC est absent : le resolveur pourra
; alors signaler honnetement que l'origine est le PATH.
Global FpcCompiler.s = Trim(GetEnvironmentVariable("MCP_FPC"))

Global TimeoutText.s = Trim(GetEnvironmentVariable("MCP_FPC_TIMEOUT_MS"))
Global TimeoutMs.i = 60000
If TimeoutText <> ""
  TimeoutMs = Val(TimeoutText)
  If TimeoutMs < 1000 : TimeoutMs = 1000 : EndIf
  If TimeoutMs > 300000 : TimeoutMs = 300000 : EndIf
EndIf

FpcConfigure(FpcRoot, FpcCompiler, TimeoutMs)

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "FpcMCPServer-PureBasic"
G_ServerVersion = "2.0.0"
*G_ToolHandler = @FpcDispatch()
*G_CatalogBuilder = @FpcBuildCatalog()

If Not CheckRuntime()
  End 1
EndIf

LogDebug("Racine FPC : " + G_FpcRoot)
LogDebug("Compilateur FPC par defaut : " + G_FpcCompilerDefault)
LogDebug("Timeout FPC : " + Str(G_FpcTimeoutMs) + " ms")

; Port 8109 : 8108 est deja pris par githubMCP. Surcharge possible via
; MCP_HTTP_PORT.
If Not MCPHttpMainLoop(8109)
  End 1
EndIf

End
