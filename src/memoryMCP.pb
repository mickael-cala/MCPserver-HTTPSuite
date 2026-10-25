; ============================================================================
;  SERVEUR MCP - Memory (PureBasic HTTP)
;  Graphe d'entites persistant en SQLite (bibliotheque integree, 0 dependance)
; ============================================================================
;  Compilation : build.bat / build.sh
;  Transport   : JSON-RPC 2.0 sur HTTP (POST /mcp, JSON par defaut, SSE optionnel)
;  Config      : MCP_MEMORY_DB = chemin du fichier SQLite (defaut: memory.db)
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

IncludeFile "memory_core.pbi"

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "MemoryMCPServer-PureBasic"
G_ServerVersion = "2.0.0"

If Not CheckRuntime()
  End 1
EndIf

Global G_MemDBPath.s = GetEnvironmentVariable("MCP_MEMORY_DB")
If G_MemDBPath = ""
  G_MemDBPath = "memory.db"
EndIf

If Not MemoryOpen(G_MemDBPath)
  LogError("Impossible d'ouvrir la base SQLite : " + G_MemDBPath)
  End 1
EndIf
If Not MemoryInitSchema()
  LogError("Impossible de creer le schema : " + DatabaseError())
  MemoryClose()
  End 1
EndIf

LogDebug("Base SQLite ouverte : " + G_MemDBPath)

*G_ToolHandler = @MemoryDispatch()
*G_CatalogBuilder = @MemoryBuildCatalog()

If Not MCPHttpMainLoop(8104)
  End 1
EndIf

MemoryClose()

End
