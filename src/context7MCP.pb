; ============================================================================
;  SERVEUR MCP - Context7 (PureBasic HTTP)
;  Resolution de bibliotheques + documentation via context7.com
; ============================================================================
;  Compilation : build.bat / build.sh
;  Transport   : JSON-RPC 2.0 sur HTTP (POST /mcp, JSON uniquement, sans SSE)
;  Config      : MCP_CONTEXT7_API_KEY = cle API (prefixe ctx7sk) ;
;                query_docs l'exige, resolve_library_id fonctionne sans.
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/http.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

IncludeFile "context7_core.pbi"

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "Context7MCPServer-PureBasic"
G_ServerVersion = "2.0.0"

If Not CheckRuntime()
  End 1
EndIf

Global G_C7BaseEnv.s = GetEnvironmentVariable("MCP_CONTEXT7_API_BASE")
If G_C7BaseEnv <> ""
  G_C7ApiBase = G_C7BaseEnv
EndIf
LogDebug("API Context7 : " + G_C7ApiBase)

G_C7ApiKey = GetEnvironmentVariable("MCP_CONTEXT7_API_KEY")
If G_C7ApiKey = ""
  LogDebug("MCP_CONTEXT7_API_KEY absente : resolve_library_id disponible, query_docs retournera une erreur 401 explicite.")
Else
  LogDebug("Cle Context7 chargee (longueur " + Str(Len(G_C7ApiKey)) + ").")
EndIf

*G_ToolHandler = @C7Dispatch()
*G_CatalogBuilder = @C7BuildCatalog()

If Not MCPHttpMainLoop(8106)
  End 1
EndIf

End
