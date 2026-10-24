; ============================================================================
;  http_sse.pbi - SSE optionnel pour le serveur HTTP MCP
;  Inclus automatiquement par http_server.pbi ; ne pas inclure seul.
;  MCP Streamable HTTP autorise une reponse JSON directe ou un flux
;  text/event-stream. Le client choisit via l'en-tete Accept.
; ============================================================================
Procedure.i HttpAcceptSse()
  ProcedureReturn Bool(FindString(LCase(G_HttpHeaders("accept")), "text/event-stream") > 0)
EndProcedure
Procedure.i HttpSendSseHeaders(Client.i, KeepAlive.i)
  Protected Conn.s = "close"
  If KeepAlive : Conn = "keep-alive" : EndIf
  Protected Head.s = "HTTP/1.1 200 OK" + #CRLF$
  Head + "Server: MCPserver-HTTPSuite" + #CRLF$
  Head + "Content-Type: text/event-stream" + #CRLF$
  Head + "Cache-Control: no-cache" + #CRLF$
  Head + "Connection: " + Conn + #CRLF$
  Head + "X-Accel-Buffering: no" + #CRLF$
  Head + "X-Content-Type-Options: nosniff" + #CRLF$
  Head + #CRLF$
  ProcedureReturn HttpSendText(Client, Head)
EndProcedure

; Ouvre un flux SSE persistant pour les messages serveur -> client.
Procedure HttpStartSse(Client.i)
  If MapSize(G_SseClients()) >= #HTTP_MAX_CONNS
    HttpSendError(Client, 503, "Trop de flux SSE simultanes.")
    ProcedureReturn
  EndIf
  If Not HttpSendSseHeaders(Client, #True)
    ProcedureReturn
  EndIf
  If Not HttpSendText(Client, ": connected" + #CRLF$ + #CRLF$)
    ProcedureReturn
  EndIf
  G_SseClients(Str(Client)) = "1"
  G_HttpSseStarted = #True
  G_HttpLastStatus = 200
EndProcedure

; Reponse SSE ponctuelle pour un POST JSON-RPC : un evenement puis fermeture.
Procedure HttpSendSseResponse(Client.i, Body.s)
  If Not HttpSendSseHeaders(Client, #False)
    ProcedureReturn
  EndIf
  G_HttpLastStatus = 200
  HttpSendText(Client, "event: message" + #CRLF$ + "data: " + Body + #CRLF$ + #CRLF$)
EndProcedure
Procedure HttpRemoveSse(Client.i)
  Protected Key.s = Str(Client)
  If FindMapElement(G_SseClients(), Key)
    DeleteMapElement(G_SseClients())
  EndIf
EndProcedure
Procedure HttpCheckSseKeepalive()
  Protected NewList Dead.s()
  ForEach G_SseClients()
    Protected Client.i = Val(MapKey(G_SseClients()))
    If Not HttpSendText(Client, ": keep-alive" + #CRLF$ + #CRLF$)
      AddElement(Dead())
      Dead() = MapKey(G_SseClients())
    EndIf
  Next
  ForEach Dead()
    Protected C.i = Val(Dead())
    HttpRemoveSse(C)
    CloseNetworkConnection(C)
  Next
EndProcedure
