; ============================================================================
;  http_server.pbi - Serveur HTTP/1.1 MCP (JSON direct + SSE optionnel)
;  Depend de runtime.pbi, logging.pbi, protocol.pbi et jsonrpc.pbi.
;  Config : MCP_HTTP_HOST, MCP_HTTP_PORT, MCP_HTTP_TOKEN, MCP_HTTP_MAX_BODY,
;           MCP_HTTP_ALLOWED_ORIGINS, MCP_HTTP_LOG_REQUESTS.
;  A inclure apres jsonrpc.pbi :
;    IncludeFile "../mcp_common/http_server.pbi"
; ============================================================================

#HTTP_HEADER_LIMIT    = 16384
#HTTP_TIMEOUT_MS      = 10000
#HTTP_SEND_TIMEOUT_MS = 10000
#HTTP_DEFAULT_MAX_BODY = 1048576
#HTTP_MAX_CONNS       = 64
#HTTP_DISCARD_SLACK   = 1048576

Global G_HttpServer.i = 0
Global G_HttpHost.s = "127.0.0.1"
Global G_HttpPort.i = 0
Global G_HttpToken.s = ""
Global G_HttpMaxBody.i = #HTTP_DEFAULT_MAX_BODY
Global G_HttpAllowedOrigins.s = ""
Global G_HttpLogRequests.i = #False
Global G_HttpLastStatus.i = 0
Global G_HttpNextTimeoutCheck.i = 0
Global G_HttpSseStarted.i = #False
Global G_HttpNextSseCheck.i = 0
Global NewMap G_HttpHeaders.s()
Global NewMap G_SseClients.s()

; Etat d'une connexion en cours de lecture (requete partielle).
Structure HttpConnState
  *Buf
  Cap.i
  Len.i
  HeaderEnd.i
  HeaderParsed.i
  BodyStart.i
  ContentLen.i
  Deadline.i
  Method.s
  Path.s
EndStructure

Global NewMap G_HttpConns.HttpConnState()

; Procedures SSE definies dans http_sse.pbi (inclus en fin de fichier).
Declare.i HttpAcceptSse()
Declare HttpStartSse(Client.i)
Declare HttpSendSseResponse(Client.i, Body.s)
Declare HttpRemoveSse(Client.i)
Declare HttpCheckSseKeepalive()

; ---------------------------------------------------------------------------
; Configuration
; ---------------------------------------------------------------------------
Procedure.i HttpLoadConfig(DefaultPort.i)
  G_HttpHost = Trim(GetEnvironmentVariable("MCP_HTTP_HOST"))
  If G_HttpHost = ""
    G_HttpHost = "127.0.0.1"
  ElseIf LCase(G_HttpHost) = "localhost"
    G_HttpHost = "127.0.0.1"
  EndIf
  If Left(G_HttpHost, 1) = "[" And Right(G_HttpHost, 1) = "]"
    G_HttpHost = Mid(G_HttpHost, 2, Len(G_HttpHost) - 2)
  EndIf

  G_HttpPort = DefaultPort
  Protected PortEnv.s = Trim(GetEnvironmentVariable("MCP_HTTP_PORT"))
  If PortEnv <> ""
    G_HttpPort = Val(PortEnv)
  EndIf
  If G_HttpPort < 1 Or G_HttpPort > 65535
    LogError("MCP_HTTP_PORT invalide : " + PortEnv)
    ProcedureReturn #False
  EndIf

  G_HttpToken = GetEnvironmentVariable("MCP_HTTP_TOKEN")

  Protected MaxEnv.s = Trim(GetEnvironmentVariable("MCP_HTTP_MAX_BODY"))
  If MaxEnv <> ""
    G_HttpMaxBody = Val(MaxEnv)
    If G_HttpMaxBody < 1024 : G_HttpMaxBody = 1024 : EndIf
    If G_HttpMaxBody > 16777216 : G_HttpMaxBody = 16777216 : EndIf
  Else
    G_HttpMaxBody = #HTTP_DEFAULT_MAX_BODY
  EndIf

  G_HttpAllowedOrigins = GetEnvironmentVariable("MCP_HTTP_ALLOWED_ORIGINS")
  G_HttpLogRequests = Bool(GetEnvironmentVariable("MCP_HTTP_LOG_REQUESTS") = "1")
  ProcedureReturn #True
EndProcedure
Procedure.i HttpIsLoopbackHost(Host.s)
  Host = LCase(Trim(Host))
  ProcedureReturn Bool(Host = "127.0.0.1" Or Host = "::1" Or Host = "localhost")
EndProcedure

; ---------------------------------------------------------------------------
; Statuts et envoi bas niveau
; ---------------------------------------------------------------------------
Procedure.s HttpStatusText(Status.i)
  Select Status
    Case 200 : ProcedureReturn "OK"
    Case 202 : ProcedureReturn "Accepted"
    Case 204 : ProcedureReturn "No Content"
    Case 400 : ProcedureReturn "Bad Request"
    Case 401 : ProcedureReturn "Unauthorized"
    Case 403 : ProcedureReturn "Forbidden"
    Case 404 : ProcedureReturn "Not Found"
    Case 405 : ProcedureReturn "Method Not Allowed"
    Case 408 : ProcedureReturn "Request Timeout"
    Case 411 : ProcedureReturn "Length Required"
    Case 413 : ProcedureReturn "Payload Too Large"
    Case 415 : ProcedureReturn "Unsupported Media Type"
    Case 431 : ProcedureReturn "Request Header Fields Too Large"
    Case 500 : ProcedureReturn "Internal Server Error"
    Case 501 : ProcedureReturn "Not Implemented"
    Case 503 : ProcedureReturn "Service Unavailable"
    Case 505 : ProcedureReturn "HTTP Version Not Supported"
    Default   : ProcedureReturn "Error"
  EndSelect
EndProcedure
Procedure.i HttpSendBytes(Client.i, *Mem, Size.i)
  If Size <= 0 : ProcedureReturn #True : EndIf
  Protected SentTotal.i = 0
  Protected Deadline.i = ElapsedMilliseconds() + #HTTP_SEND_TIMEOUT_MS
  While SentTotal < Size
    Protected N.i = SendNetworkData(Client, *Mem + SentTotal, Size - SentTotal)
    If N > 0
      SentTotal + N
    ElseIf N < 0
      ProcedureReturn #False
    Else
      If ElapsedMilliseconds() > Deadline : ProcedureReturn #False : EndIf
      Delay(1)
    EndIf
  Wend
  ProcedureReturn #True
EndProcedure
Procedure.i HttpSendText(Client.i, Text.s)
  Protected Size.i = StringByteLength(Text, #PB_UTF8)
  If Size = 0 : ProcedureReturn #True : EndIf
  Protected Ok.i = #False
  Protected *Mem = AllocateMemory(Size)
  If *Mem
    PokeS(*Mem, Text, -1, #PB_UTF8 | #PB_String_NoZero)
    Ok = HttpSendBytes(Client, *Mem, Size)
    FreeMemory(*Mem)
  EndIf
  ProcedureReturn Ok
EndProcedure
Procedure HttpSendResponse(Client.i, Status.i, ContentType.s, Body.s, ExtraHeaders.s = "")
  G_HttpLastStatus = Status
  Protected BodyLen.i = StringByteLength(Body, #PB_UTF8)
  Protected Head.s = "HTTP/1.1 " + Str(Status) + " " + HttpStatusText(Status) + #CRLF$
  Head + "Server: MCPserver-HTTPSuite" + #CRLF$
  If ContentType <> ""
    Head + "Content-Type: " + ContentType + #CRLF$
  EndIf
  If Status <> 204
    Head + "Content-Length: " + Str(BodyLen) + #CRLF$
  EndIf
  Head + "Connection: close" + #CRLF$
  Head + "Cache-Control: no-store" + #CRLF$
  Head + "X-Content-Type-Options: nosniff" + #CRLF$
  If ExtraHeaders <> ""
    Head + ExtraHeaders
    If Right(ExtraHeaders, 2) <> #CRLF$
      Head + #CRLF$
    EndIf
  EndIf
  Head + #CRLF$

  Protected HeadLen.i = StringByteLength(Head, #PB_UTF8)
  Protected TotalLen.i = HeadLen + BodyLen
  Protected *Mem = AllocateMemory(TotalLen)
  If *Mem = 0 : ProcedureReturn : EndIf
  PokeS(*Mem, Head, -1, #PB_UTF8 | #PB_String_NoZero)
  If BodyLen > 0
    PokeS(*Mem + HeadLen, Body, -1, #PB_UTF8 | #PB_String_NoZero)
  EndIf
  HttpSendBytes(Client, *Mem, TotalLen)
  FreeMemory(*Mem)
EndProcedure
Procedure HttpSendError(Client.i, Status.i, Message.s, ExtraHeaders.s = "")
  Protected J.i = CreateJSON(#PB_Any)
  If J = 0
    HttpSendResponse(Client, Status, "text/plain; charset=utf-8", Message, ExtraHeaders)
    ProcedureReturn
  EndIf
  Protected Root.i = SetJSONObject(JSONValue(J))
  SetJSONString(AddJSONMember(Root, "error"), Message)
  Protected Body.s = ComposeJSON(J)
  FreeJSON(J)
  HttpSendResponse(Client, Status, "application/json; charset=utf-8", Body, ExtraHeaders)
EndProcedure

; ---------------------------------------------------------------------------
; Gestion des connexions partielles
; ---------------------------------------------------------------------------
Procedure HttpConnFree(*C.HttpConnState)
  If *C\Buf
    FreeMemory(*C\Buf)
    *C\Buf = 0
  EndIf
  *C\Cap = 0
  *C\Len = 0
EndProcedure
Procedure HttpRemoveConn(Client.i)
  Protected Key.s = Str(Client)
  Protected *C.HttpConnState = FindMapElement(G_HttpConns(), Key)
  If *C
    HttpConnFree(*C)
    DeleteMapElement(G_HttpConns())
  EndIf
EndProcedure
Procedure HttpCloseConn(Client.i)
  HttpRemoveConn(Client)
  CloseNetworkConnection(Client)
EndProcedure
Procedure.i HttpConnEnsure(Client.i)
  Protected Key.s = Str(Client)
  Protected *C.HttpConnState = FindMapElement(G_HttpConns(), Key)
  If *C
    ProcedureReturn #True
  EndIf
  If MapSize(G_HttpConns()) >= #HTTP_MAX_CONNS
    ProcedureReturn #False
  EndIf
  *C = AddMapElement(G_HttpConns(), Key)
  If *C = 0 : ProcedureReturn #False : EndIf
  *C\Buf = AllocateMemory(#HTTP_HEADER_LIMIT)
  If *C\Buf = 0
    DeleteMapElement(G_HttpConns())
    ProcedureReturn #False
  EndIf
  *C\Cap = #HTTP_HEADER_LIMIT
  *C\Len = 0
  *C\HeaderEnd = -1
  *C\HeaderParsed = #False
  *C\BodyStart = 0
  *C\ContentLen = 0
  *C\Deadline = ElapsedMilliseconds() + #HTTP_TIMEOUT_MS
  *C\Method = ""
  *C\Path = ""
  ProcedureReturn #True
EndProcedure
Procedure.i HttpConnGrow(*C.HttpConnState, Needed.i)
  If Needed <= *C\Cap : ProcedureReturn #True : EndIf
  Protected *New = ReAllocateMemory(*C\Buf, Needed)
  If *New = 0 : ProcedureReturn #False : EndIf
  *C\Buf = *New
  *C\Cap = Needed
  ProcedureReturn #True
EndProcedure

; Lit tout ce qui est disponible ; retourne le nombre d'octets lus.
Procedure.i HttpConnRead(Client.i, *C.HttpConnState)
  Protected TotalRead.i = 0
  Protected N.i
  Repeat
    If *C\Len >= *C\Cap : Break : EndIf
    N = ReceiveNetworkData(Client, *C\Buf + *C\Len, *C\Cap - *C\Len)
    If N > 0
      *C\Len + N
      TotalRead + N
    Else
      Break
    EndIf
  Until N <= 0
  ProcedureReturn TotalRead
EndProcedure

; Lecture bloquante du corps d'une requete (une fois les en-tetes connus).
; ReceiveNetworkData peut retourner 0/-1 tant que le reste n'est pas arrive :
; on retente avec un delai d'inactivite, sans consommer les evenements reseau.
Procedure.i HttpReadBody(Client.i, *C.HttpConnState, Needed.i)
  Protected Deadline.i = ElapsedMilliseconds() + #HTTP_TIMEOUT_MS
  Protected N.i
  While *C\Len < Needed
    N = ReceiveNetworkData(Client, *C\Buf + *C\Len, Needed - *C\Len)
    If N > 0
      *C\Len + N
      Deadline = ElapsedMilliseconds() + #HTTP_TIMEOUT_MS
    Else
      If ElapsedMilliseconds() > Deadline : ProcedureReturn #False : EndIf
      Delay(1)
    EndIf
  Wend
  ProcedureReturn #True
EndProcedure

; Lit et jette un corps trop volumineux (pour laisser le client lire le 413).
Procedure HttpDiscardBody(Client.i, Remaining.i)
  If Remaining <= 0 : ProcedureReturn : EndIf
  Protected *Tmp = AllocateMemory(65536)
  If *Tmp = 0 : ProcedureReturn : EndIf
  Protected Deadline.i = ElapsedMilliseconds() + #HTTP_TIMEOUT_MS
  Protected N.i, Want.i
  While Remaining > 0
    Want = Remaining
    If Want > 65536 : Want = 65536 : EndIf
    N = ReceiveNetworkData(Client, *Tmp, Want)
    If N > 0
      Remaining - N
      Deadline = ElapsedMilliseconds() + #HTTP_TIMEOUT_MS
    Else
      If ElapsedMilliseconds() > Deadline : Break : EndIf
      Delay(1)
    EndIf
  Wend
  FreeMemory(*Tmp)
EndProcedure

; Retourne l'index du premier octet du terminateur (\r\n\r\n ou \n\n), ou -1.
Procedure.i HttpFindHeaderEnd(*Mem, Len.i)
  Protected i.i
  For i = 0 To Len - 1
    If PeekB(*Mem + i) = 10
      If i >= 3 And PeekB(*Mem + i - 1) = 13 And PeekB(*Mem + i - 2) = 10 And PeekB(*Mem + i - 3) = 13
        ProcedureReturn i - 3
      ElseIf i >= 1 And PeekB(*Mem + i - 1) = 10
        ProcedureReturn i - 1
      EndIf
    EndIf
  Next
  ProcedureReturn -1
EndProcedure

; ---------------------------------------------------------------------------
; Verifications de securite
; ---------------------------------------------------------------------------
Procedure.i HttpOriginAllowed(Origin.s)
  If Origin = "" : ProcedureReturn #True : EndIf
  Protected O.s = LCase(Trim(Origin))
  Protected P.s = Str(G_HttpPort)
  If O = "http://127.0.0.1:" + P Or O = "http://localhost:" + P Or O = "http://[::1]:" + P
    ProcedureReturn #True
  EndIf
  If G_HttpAllowedOrigins <> ""
    Protected i.i, n.i = CountString(G_HttpAllowedOrigins, ",") + 1, A.s
    For i = 1 To n
      A = LCase(Trim(StringField(G_HttpAllowedOrigins, i, ",")))
      If A <> "" And O = A : ProcedureReturn #True : EndIf
    Next
  EndIf
  ProcedureReturn #False
EndProcedure
Procedure.i HttpTokenAllowed(AuthHeader.s)
  If G_HttpToken = "" : ProcedureReturn #True : EndIf
  Protected A.s = Trim(AuthHeader)
  If Len(A) < 8 : ProcedureReturn #False : EndIf
  If LCase(Left(A, 7)) <> "bearer " : ProcedureReturn #False : EndIf
  ProcedureReturn Bool(Mid(A, 8) = G_HttpToken)
EndProcedure

; ---------------------------------------------------------------------------
; Reponses applicatives
; ---------------------------------------------------------------------------
Procedure HttpSendHealth(Client.i)
  Protected J.i = CreateJSON(#PB_Any)
  If J = 0
    HttpSendError(Client, 500, "Memoire JSON insuffisante.")
    ProcedureReturn
  EndIf
  Protected Root.i = SetJSONObject(JSONValue(J))
  SetJSONString(AddJSONMember(Root, "status"), "ok")
  SetJSONString(AddJSONMember(Root, "server"), G_ServerName)
  SetJSONString(AddJSONMember(Root, "version"), G_ServerVersion)
  SetJSONString(AddJSONMember(Root, "transport"), "http")
  SetJSONBoolean(AddJSONMember(Root, "sse"), #True)
  SetJSONString(AddJSONMember(Root, "protocol"), G_McpProtocolVersion)
  Protected Body.s = ComposeJSON(J)
  FreeJSON(J)
  HttpSendResponse(Client, 200, "application/json; charset=utf-8", Body)
EndProcedure
Procedure HttpHandleMcp(Client.i, Body.s)
  If Body = ""
    HttpSendError(Client, 400, "Corps JSON-RPC vide.")
    ProcedureReturn
  EndIf
  Protected Resp.s = ProcessRequestToJSON(Body)
  If Resp = ""
    ; Notification JSON-RPC : 202 sans corps.
    HttpSendResponse(Client, 202, "", "")
  ElseIf HttpAcceptSse()
    ; Le client accepte SSE : reponse en un evenement text/event-stream.
    HttpSendSseResponse(Client, Resp)
  Else
    HttpSendResponse(Client, 200, "application/json; charset=utf-8", Resp)
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; Routage
; ---------------------------------------------------------------------------
Procedure HttpRoute(Client.i, Method.s, Path.s, Body.s)
  Protected Origin.s = G_HttpHeaders("origin")

  Select Method
    Case "GET"
      If Path = "/health"
        HttpSendHealth(Client)
      ElseIf Path = "/mcp"
        If Not HttpOriginAllowed(Origin)
          HttpSendError(Client, 403, "Origine non autorisee : " + Origin)
        ElseIf Not HttpTokenAllowed(G_HttpHeaders("authorization"))
          HttpSendError(Client, 401, "Jeton Bearer requis ou invalide.", "WWW-Authenticate: Bearer" + #CRLF$)
        ElseIf FindMapElement(G_HttpHeaders(), "mcp-protocol-version") And Not IsSupportedProtocolVersion(Trim(G_HttpHeaders("mcp-protocol-version")))
          HttpSendError(Client, 400, "MCP-Protocol-Version non supportee : " + Trim(G_HttpHeaders("mcp-protocol-version")))
        ElseIf HttpAcceptSse()
          HttpStartSse(Client)
        Else
          HttpSendError(Client, 405, "SSE non demande : ajoutez Accept: text/event-stream.", "Allow: GET, POST" + #CRLF$)
        EndIf
      Else
        HttpSendError(Client, 404, "Chemin inconnu : " + Path)
      EndIf

    Case "POST"
      If Path = "/health"
        HttpSendError(Client, 405, "Utilisez GET /health.", "Allow: GET" + #CRLF$)
        ProcedureReturn
      EndIf
      If Path <> "/mcp"
        HttpSendError(Client, 404, "Chemin inconnu : " + Path)
        ProcedureReturn
      EndIf
      If Not HttpOriginAllowed(Origin)
        HttpSendError(Client, 403, "Origine non autorisee : " + Origin)
        ProcedureReturn
      EndIf
      If Not HttpTokenAllowed(G_HttpHeaders("authorization"))
        HttpSendError(Client, 401, "Jeton Bearer requis ou invalide.", "WWW-Authenticate: Bearer" + #CRLF$)
        ProcedureReturn
      EndIf
      Protected CT.s = LCase(Trim(G_HttpHeaders("content-type")))
      If CT <> "application/json" And Left(CT, 17) <> "application/json;"
        HttpSendError(Client, 415, "Content-Type application/json requis.")
        ProcedureReturn
      EndIf
      If FindMapElement(G_HttpHeaders(), "mcp-protocol-version")
        Protected PV.s = Trim(G_HttpHeaders("mcp-protocol-version"))
        If Not IsSupportedProtocolVersion(PV)
          HttpSendError(Client, 400, "MCP-Protocol-Version non supportee : " + PV)
          ProcedureReturn
        EndIf
      EndIf
      HttpHandleMcp(Client, Body)

    Case "DELETE"
      If Path = "/mcp"
        ; Serveur sans etat : accepte la fin de session sans effet.
        HttpSendResponse(Client, 204, "", "", "")
      Else
        HttpSendError(Client, 404, "Chemin inconnu : " + Path)
      EndIf

    Case "OPTIONS"
      If Not HttpOriginAllowed(Origin)
        HttpSendError(Client, 403, "Origine non autorisee : " + Origin)
      Else
        HttpSendResponse(Client, 204, "", "", "Allow: POST" + #CRLF$ + "Access-Control-Allow-Methods: POST" + #CRLF$)
      EndIf

    Default
      HttpSendResponse(Client, 405, "application/json; charset=utf-8", ~"{\"error\":\"Methode non supportee.\"}", "Allow: POST" + #CRLF$)
  EndSelect
EndProcedure

; ---------------------------------------------------------------------------
; Parsing des en-tetes (une seule fois par connexion)
; Retourne #True si la requete est valide, #False si une erreur a ete envoyee.
; ---------------------------------------------------------------------------
Procedure.i HttpParseHeaders(Client.i, *C.HttpConnState)
  Protected SepLen.i = 4
  If PeekB(*C\Buf + *C\HeaderEnd) <> 13 : SepLen = 2 : EndIf
  *C\BodyStart = *C\HeaderEnd + SepLen

  Protected HeaderText.s = PeekS(*C\Buf, *C\HeaderEnd, #PB_UTF8 | #PB_ByteLength)
  HeaderText = ReplaceString(HeaderText, #CRLF$, #LF$)

  Protected RequestLine.s = Trim(StringField(HeaderText, 1, #LF$))
  *C\Method = UCase(Trim(StringField(RequestLine, 1, " ")))
  Protected Target.s = Trim(StringField(RequestLine, 2, " "))
  Protected HttpVer.s = Trim(StringField(RequestLine, 3, " "))

  If *C\Method = "" Or Target = "" Or Left(HttpVer, 7) <> "HTTP/1."
    HttpSendError(Client, 400, "Ligne de requete HTTP invalide.")
    ProcedureReturn #False
  EndIf

  Protected Path.s = Target
  Protected QPos.i = FindString(Path, "?")
  If QPos > 0 : Path = Left(Path, QPos - 1) : EndIf
  If Len(Path) > 1 And Right(Path, 1) = "/"
    Path = Left(Path, Len(Path) - 1)
  EndIf
  *C\Path = Path

  ; En-tetes (noms insensibles a la casse)
  ClearMap(G_HttpHeaders())
  Protected HCount.i = CountString(HeaderText, #LF$) + 1
  Protected i.i, HLine.s, ColonPos.i, HName.s, HValue.s
  For i = 2 To HCount
    HLine = StringField(HeaderText, i, #LF$)
    If HLine <> ""
      ColonPos = FindString(HLine, ":")
      If ColonPos > 0
        HName = LCase(Trim(Left(HLine, ColonPos - 1)))
        HValue = Trim(Mid(HLine, ColonPos + 1))
        If HName <> "" : G_HttpHeaders(HName) = HValue : EndIf
      EndIf
    EndIf
  Next

  If FindMapElement(G_HttpHeaders(), "transfer-encoding")
    HttpSendError(Client, 501, "Transfer-Encoding non supporte (utilisez Content-Length).")
    ProcedureReturn #False
  EndIf

  Protected HasLen.i = #False
  *C\ContentLen = 0
  If FindMapElement(G_HttpHeaders(), "content-length")
    *C\ContentLen = Val(G_HttpHeaders("content-length"))
    HasLen = #True
  EndIf
  If *C\ContentLen < 0 : *C\ContentLen = 0 : EndIf

  If *C\Method = "POST" And Not HasLen
    HttpSendError(Client, 411, "Content-Length requis pour POST.")
    ProcedureReturn #False
  EndIf

  If FindMapElement(G_HttpHeaders(), "expect")
    If LCase(Trim(G_HttpHeaders("expect"))) = "100-continue"
      HttpSendText(Client, "HTTP/1.1 100 Continue" + #CRLF$ + #CRLF$)
    EndIf
  EndIf

  *C\HeaderParsed = #True
  ProcedureReturn #True
EndProcedure

; ---------------------------------------------------------------------------
; Evenement Data : accumule puis traite la requete quand elle est complete
; ---------------------------------------------------------------------------
Procedure HttpConnOnData(Client.i)
  Protected Key.s = Str(Client)
  ; Un flux SSE est mono-directionnel (serveur -> client) : ignorer les
  ; eventuelles donnees du client sur cette connexion.
  If FindMapElement(G_SseClients(), Key)
    ProcedureReturn
  EndIf
  Protected Existing.i = Bool(FindMapElement(G_HttpConns(), Key) <> 0)
  If Not Existing And MapSize(G_HttpConns()) >= #HTTP_MAX_CONNS
    HttpSendError(Client, 503, "Trop de connexions simultanees.")
    CloseNetworkConnection(Client)
    ProcedureReturn
  EndIf

  If Not HttpConnEnsure(Client)
    HttpSendError(Client, 500, "Memoire insuffisante.")
    CloseNetworkConnection(Client)
    ProcedureReturn
  EndIf

  Protected *C.HttpConnState = FindMapElement(G_HttpConns(), Key)
  Protected NewBytes.i = HttpConnRead(Client, *C)
  If NewBytes > 0
    ; Delai d'inactivite (et non delai total) : un gros corps peut arriver
    ; en plusieurs paquets sans etre interrompu.
    *C\Deadline = ElapsedMilliseconds() + #HTTP_TIMEOUT_MS
  EndIf

  If Not *C\HeaderParsed
    *C\HeaderEnd = HttpFindHeaderEnd(*C\Buf, *C\Len)
    If *C\HeaderEnd < 0
      If *C\Len >= *C\Cap
        HttpSendError(Client, 431, "En-tetes HTTP trop volumineux.")
        HttpCloseConn(Client)
      EndIf
      ProcedureReturn
    EndIf

    If Not HttpParseHeaders(Client, *C)
      HttpCloseConn(Client)
      ProcedureReturn
    EndIf

    ; Corps trop volumineux : drainer (borne) pour que le client puisse lire
    ; la reponse 413, puis fermer.
    If *C\ContentLen > G_HttpMaxBody
      Protected AlreadyBody.i = *C\Len - *C\BodyStart
      If AlreadyBody < 0 : AlreadyBody = 0 : EndIf
      If *C\ContentLen <= G_HttpMaxBody + #HTTP_DISCARD_SLACK
        HttpDiscardBody(Client, *C\ContentLen - AlreadyBody)
      EndIf
      HttpSendError(Client, 413, "Corps de requete trop volumineux (max " + Str(G_HttpMaxBody) + " octets).")
      HttpCloseConn(Client)
      ProcedureReturn
    EndIf

    Protected Needed.i = *C\BodyStart + *C\ContentLen
    If Not HttpConnGrow(*C, Needed)
      HttpSendError(Client, 500, "Memoire insuffisante pour le corps.")
      HttpCloseConn(Client)
      ProcedureReturn
    EndIf
  EndIf

  Protected NeededTotal.i = *C\BodyStart + *C\ContentLen
  If *C\Len < NeededTotal
    If Not HttpReadBody(Client, *C, NeededTotal)
      HttpSendError(Client, 408, "Corps de requete incomplet.")
      HttpCloseConn(Client)
      ProcedureReturn
    EndIf
  EndIf

  Protected Body.s = ""
  If *C\ContentLen > 0
    Body = PeekS(*C\Buf + *C\BodyStart, *C\ContentLen, #PB_UTF8 | #PB_ByteLength)
  EndIf

  G_HttpLastStatus = 0
  G_HttpSseStarted = #False
  Protected StartMs.i = ElapsedMilliseconds()
  HttpRoute(Client, *C\Method, *C\Path, Body)
  If G_HttpLogRequests
    LogDebug("HTTP " + *C\Method + " " + *C\Path + " -> " + Str(G_HttpLastStatus) + " (" + Str(ElapsedMilliseconds() - StartMs) + " ms)")
  EndIf

  If G_HttpSseStarted
    ; Le flux SSE reste ouvert : liberer seulement l'etat de requete HTTP.
    G_HttpSseStarted = #False
    HttpRemoveConn(Client)
  Else
    HttpCloseConn(Client)
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; Fermeture des connexions lentes (slowloris)
; ---------------------------------------------------------------------------
Procedure HttpCheckTimeouts()
  Protected Now.i = ElapsedMilliseconds()
  Protected NewList Expired.s()
  Protected Key.s
  ForEach G_HttpConns()
    If Now > G_HttpConns()\Deadline
      AddElement(Expired())
      Expired() = MapKey(G_HttpConns())
    EndIf
  Next
  ForEach Expired()
    Protected Client.i = Val(Expired())
    HttpSendError(Client, 408, "Delai de lecture de la requete depasse.")
    HttpCloseConn(Client)
  Next
EndProcedure

; ---------------------------------------------------------------------------
; Boucle principale
; ---------------------------------------------------------------------------
Procedure.i MCPHttpMainLoop(DefaultPort.i)
  If Not HttpLoadConfig(DefaultPort)
    ProcedureReturn #False
  EndIf

  Protected Flags.i = #PB_Network_TCP
  If FindString(G_HttpHost, ":") > 0
    Flags | #PB_Network_IPv6
  Else
    Flags | #PB_Network_IPv4
  EndIf

  G_HttpServer = CreateNetworkServer(#PB_Any, G_HttpPort, Flags, G_HttpHost)
  If G_HttpServer = 0
    LogError("Impossible d'ecouter sur " + G_HttpHost + ":" + Str(G_HttpPort) + " (port deja utilise ?).")
    ProcedureReturn #False
  EndIf

  If Not HttpIsLoopbackHost(G_HttpHost) And G_HttpToken = ""
    LogError("ATTENTION : ecoute sur " + G_HttpHost + " sans MCP_HTTP_TOKEN. Definissez un jeton ou utilisez 127.0.0.1.")
  EndIf

  LogDebug("Serveur MCP HTTP a l'ecoute sur http://" + G_HttpHost + ":" + Str(G_HttpPort) + "/mcp (JSON, SSE optionnel)")
  LogDebug("Sante : http://" + G_HttpHost + ":" + Str(G_HttpPort) + "/health")

  ClearMap(G_HttpConns())
  ClearMap(G_HttpHeaders())
  ClearMap(G_SseClients())
  G_HttpNextTimeoutCheck = ElapsedMilliseconds() + 500
  G_HttpNextSseCheck = ElapsedMilliseconds() + 15000

  Protected Event.i, Client.i
  Repeat
    Event = NetworkServerEvent()
    If Event
      Client = EventClient()
      Select Event
        Case #PB_NetworkEvent_Data
          HttpConnOnData(Client)
        Case #PB_NetworkEvent_Disconnect
          HttpRemoveConn(Client)
          HttpRemoveSse(Client)
      EndSelect
    Else
      If MapSize(G_HttpConns()) > 0
        Delay(1)
      ElseIf MapSize(G_SseClients()) > 0
        Delay(50)
      Else
        Delay(10)
      EndIf
    EndIf

    If ElapsedMilliseconds() >= G_HttpNextTimeoutCheck
      HttpCheckTimeouts()
      G_HttpNextTimeoutCheck = ElapsedMilliseconds() + 500
    EndIf

    If ElapsedMilliseconds() >= G_HttpNextSseCheck
      HttpCheckSseKeepalive()
      G_HttpNextSseCheck = ElapsedMilliseconds() + 15000
    EndIf
  ForEver

  ProcedureReturn #True
EndProcedure

; SSE optionnel (procedures declares ci-dessus, incluses apres le noyau HTTP).
IncludeFile "../mcp_common/http_sse.pbi"
