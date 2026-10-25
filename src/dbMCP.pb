; ============================================================================
;  SERVEUR MCP - Database (PureBasic HTTP)
;  Exploration SQL en lecture seule : SQLite (integre) + PostgreSQL (optionnel)
; ============================================================================
;  Compilation : build.bat / build.sh
;  Transport   : JSON-RPC 2.0 sur HTTP (POST /mcp, JSON par defaut, SSE optionnel)
;  Config      : MCP_DB_PATH           = fichier SQLite (defaut: database.db)
;                MCP_DB_POSTGRES_DSN   = chaine de connexion PostgreSQL
;                MCP_DB_ALLOW_WRITE=1  = autorise INSERT/UPDATE/DELETE/DDL
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

IncludeFile "db_core.pbi"

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "DatabaseMCPServer-PureBasic"
G_ServerVersion = "2.0.0"

If Not CheckRuntime()
  End 1
EndIf

Global G_DBPath.s = GetEnvironmentVariable("MCP_DB_PATH")
If G_DBPath = ""
  G_DBPath = "database.db"
EndIf

If Not DbOpenSQLite(G_DBPath)
  LogError("Impossible d'ouvrir la base SQLite : " + G_DBPath + " (" + DatabaseError() + ")")
  End 1
EndIf
LogDebug("SQLite ouverte : " + G_DBPath)

Global G_PGEnv.s = GetEnvironmentVariable("MCP_DB_POSTGRES_DSN")
If G_PGEnv <> ""
  If DbOpenPostgres(G_PGEnv)
    LogDebug("PostgreSQL connecte : " + G_PGEnv)
  Else
    LogError("Connexion PostgreSQL impossible : " + DatabaseError() + " (le serveur continue en SQLite)")
  EndIf
EndIf

If GetEnvironmentVariable("MCP_DB_ALLOW_WRITE") = "1"
  G_DBAllowWrite = #True
  LogDebug("Mode ecriture active (MCP_DB_ALLOW_WRITE=1)")
EndIf

*G_ToolHandler = @DbDispatch()
*G_CatalogBuilder = @DbBuildCatalog()

If Not MCPHttpMainLoop(8105)
  End 1
EndIf

DbClose()

End
