; ============================================================================
;  protocol.pbi - Reponses MCP standardisees (initialize)
;  Declare l'identite du serveur : chaque serveur renseigne ces globals
;  avant d'appeler MCPHttpMainLoop() (voir http_server.pbi).
; ============================================================================
;  A inclure avant jsonrpc.pbi :
;    IncludeFile "../mcp_common/protocol.pbi"
; ============================================================================

Global G_ServerName.s = "MCP-PB-Server"
Global G_ServerVersion.s = "2.0.0"

; Version MCP annoncee par defaut. Le transport est Streamable HTTP
; (JSON direct par defaut, SSE optionnel), disponible a partir de 2025-03-26.
Global G_McpProtocolVersion.s = "2025-06-18"
; Si le client n'envoie pas MCP-Protocol-Version, la spec suggere 2025-03-26.
Global G_McpFallbackProtocolVersion.s = "2025-03-26"

Procedure.i IsSupportedProtocolVersion(V.s)
  Select V
    Case "2025-03-26", "2025-06-18"
      ProcedureReturn #True
  EndSelect
  ProcedureReturn #False
EndProcedure

; Remplit l'objet "result" d'une reponse "initialize", conforme au
; protocole MCP (version negociee, capacites, serverInfo).
Procedure BuildInitializeResponse(ResultObj.i, RequestedVersion.s)
  Protected Version.s = G_McpProtocolVersion
  If IsSupportedProtocolVersion(RequestedVersion)
    Version = RequestedVersion
  EndIf

  SetJSONString(AddJSONMember(ResultObj, "protocolVersion"), Version)
  Protected Caps.i = AddJSONMember(ResultObj, "capabilities")
  SetJSONObject(Caps)
  SetJSONObject(AddJSONMember(Caps, "tools"))
  Protected ServerInfo.i = AddJSONMember(ResultObj, "serverInfo")
  SetJSONObject(ServerInfo)
  SetJSONString(AddJSONMember(ServerInfo, "name"), G_ServerName)
  SetJSONString(AddJSONMember(ServerInfo, "version"), G_ServerVersion)
EndProcedure
