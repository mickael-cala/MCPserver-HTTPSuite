; ============================================================================
;  SERVEUR MCP MINIMAL (DEMO) - PureBasic HTTP
;  Sert de validation pour la Phase 0 du plan : un serveur "vide" repondant
;  correctement a initialize et tools/list (catalogue factice) en moins de
;  200 lignes de code metier, grace aux modules mcp_common/.
; ============================================================================
;  Compilation : pbcompiler examples/minimal_server.pb /EXE build/minimal_server /CONSOLE
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

; ---------------------------------------------------------------------------
; Outil factice "ping"
; ---------------------------------------------------------------------------
Procedure.s ToolPing(ArgsObj.i)
  Protected Message.s = GetArgString(ArgsObj, "message")
  If Message = ""
    ProcedureReturn "pong"
  EndIf
  ProcedureReturn "pong: " + Message
EndProcedure

; ---------------------------------------------------------------------------
; Dispatch des outils (hook *G_ToolHandler)
; ---------------------------------------------------------------------------
Procedure.s ToolDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Select ToolName
    Case "ping"
      ProcedureReturn ToolPing(ArgsObj)
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure

; ---------------------------------------------------------------------------
; Catalogue MCP (hook *G_CatalogBuilder)
; ---------------------------------------------------------------------------
Procedure.i BuildToolsCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "ping", "Repond pong au message recu (outil de demo).",
          "message|string|Message a renvoyer (optionnel)", "")

  ProcedureReturn RootJSON
EndProcedure

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "MinimalMCPServer-PureBasic"
G_ServerVersion = "2.0.0"
*G_ToolHandler = @ToolDispatch()
*G_CatalogBuilder = @BuildToolsCatalog()

LogDebug("Demarrage du serveur minimal de demo")

If Not CheckRuntime()
  End 1
EndIf

If Not MCPHttpMainLoop(8090)
  End 1
EndIf

End
