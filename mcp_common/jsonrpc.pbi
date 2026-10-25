; ============================================================================
;  jsonrpc.pbi - Noyau JSON-RPC 2.0 / MCP, independant du transport
;  Depend de json_helpers.pbi et protocol.pbi.
; ============================================================================
;  Chaque serveur configure les globals ci-dessous, puis http_server.pbi
;  appelle ProcessRequestToJSON(Line, @Status) pour chaque corps HTTP.
;  Status recoit 200 (requete), 202 (notification) ou 400 (entree invalide).
;
;    G_ServerName    = "MonServeurMCP-PureBasic"
;    G_ServerVersion = "2.0.0"
;    *G_ToolHandler    = @MonDispatch()       ; Prototype MCPToolHandler
;    *G_CatalogBuilder = @MonBuildCatalog()   ; Prototype MCPCatalogBuilder
; ============================================================================

; ---------------------------------------------------------------------------
; Hooks configures par le serveur
; ---------------------------------------------------------------------------
; Dispatch d'un outil : retourne le texte de resultat ; *IsError\i = #True
; si l'appel doit etre marque isError dans la reponse MCP.
Prototype.s MCPToolHandler(ToolName.s, ArgsObj.i, *IsError.Integer)
; Construit et retourne un handle JSON du catalogue : {"tools": [...]}
Prototype.i MCPCatalogBuilder()

Global *G_ToolHandler.MCPToolHandler = #Null
Global *G_CatalogBuilder.MCPCatalogBuilder = #Null

; ---------------------------------------------------------------------------
; Serialisation d'un id JSON-RPC (string, nombre ou null)
; ---------------------------------------------------------------------------
Procedure.s JSONIdFragment(IdMember.i)
  If IdMember = 0
    ProcedureReturn "null"
  EndIf
  Select JSONType(IdMember)
    Case #PB_JSON_String
      ProcedureReturn Chr(34) + EscapeString(GetJSONString(IdMember), #PB_String_EscapeJSON) + Chr(34)
    Case #PB_JSON_Number
      Protected D.d = GetJSONDouble(IdMember)
      If D = Int(D)
        ProcedureReturn Str(Int(D))
      EndIf
      ProcedureReturn ReplaceString(StrD(D), ",", ".")
    Default
      ProcedureReturn "null"
  EndSelect
EndProcedure

; ---------------------------------------------------------------------------
; Reponse d'erreur JSON-RPC
; ---------------------------------------------------------------------------
Procedure.s BuildErrorResponse(IdMember.i, Code.i, Msg.s)
  Protected J.i = CreateJSON(#PB_Any)
  If J = 0 : ProcedureReturn "" : EndIf
  Protected Root.i = SetJSONObject(JSONValue(J))
  SetJSONString(AddJSONMember(Root, "jsonrpc"), "2.0")
  Protected IdVal.i = AddJSONMember(Root, "id")
  If IdMember
    Select JSONType(IdMember)
      Case #PB_JSON_String
        SetJSONString(IdVal, GetJSONString(IdMember))
      Case #PB_JSON_Number
        SetJSONDouble(IdVal, GetJSONDouble(IdMember))
      Default
        SetJSONNull(IdVal)
    EndSelect
  Else
    SetJSONNull(IdVal)
  EndIf
  Protected ErrObj.i = AddJSONMember(Root, "error")
  SetJSONObject(ErrObj)
  SetJSONInteger(AddJSONMember(ErrObj, "code"), Code)
  SetJSONString(AddJSONMember(ErrObj, "message"), Msg)
  Protected Out.s = ComposeJSON(J)
  FreeJSON(J)
  ProcedureReturn Out
EndProcedure

Procedure AttachResultPayload(ResultObj.i, ContentText.s, IsError.i)
  Protected ContentArr.i = AddJSONMember(ResultObj, "content")
  SetJSONArray(ContentArr)
  Protected ItemObj.i = AddJSONElement(ContentArr)
  SetJSONObject(ItemObj)
  SetJSONString(AddJSONMember(ItemObj, "type"), "text")
  SetJSONString(AddJSONMember(ItemObj, "text"), ContentText)
  SetJSONBoolean(AddJSONMember(ResultObj, "isError"), IsError)
EndProcedure

; ---------------------------------------------------------------------------
; Heuristique d'erreur : un message d'echec d'outil doit commencer par (ou
; contenir) un de ces marqueurs pour que isError soit positionne. Les outils
; peuvent aussi lever *IsError\i directement dans le dispatch.
; ---------------------------------------------------------------------------
Procedure.i DetectIsError(OutputStr.s)
  If OutputStr = "ACCES_REFUSE"
    ProcedureReturn #True
  EndIf
  If FindString(OutputStr, "Erreur") = 1 Or FindString(OutputStr, "ERREUR") = 1 Or FindString(OutputStr, "Impossible") = 1 Or FindString(OutputStr, "Echec") = 1
    ProcedureReturn #True
  EndIf
  If FindString(OutputStr, "introuvable") > 0 Or FindString(OutputStr, "refusee") > 0 Or FindString(OutputStr, "depasse") > 0
    ProcedureReturn #True
  EndIf
  ProcedureReturn #False
EndProcedure

; ---------------------------------------------------------------------------
; Traitement d'une requete JSON-RPC.
; Retourne la reponse JSON complete, ou "" pour une notification.
; *HttpStatus recoit 200 (requete valide), 202 (notification) ou 400
; (entree invalide : JSON invalide, lot, reponse client, methode absente).
; ---------------------------------------------------------------------------
Procedure.s ProcessRequestToJSON(Line.s, *HttpStatus.Integer)
  *HttpStatus\i = 200
  Protected ReqJSON.i = ParseJSON(#PB_Any, Line)
  If Not ReqJSON
    *HttpStatus\i = 400
    ProcedureReturn BuildErrorResponse(0, -32700, "Parse error: invalid JSON")
  EndIf

  Protected RootVal.i = JSONValue(ReqJSON)
  If JSONType(RootVal) <> #PB_JSON_Object
    *HttpStatus\i = 400
    FreeJSON(ReqJSON)
    ProcedureReturn BuildErrorResponse(0, -32600, "Invalid Request: Root must be an object")
  EndIf

  Protected MethodMember.i = GetJSONMember(RootVal, "method")
  If Not MethodMember
    ; Objet sans methode : reponse JSON-RPC envoyee par le client, ou invalide.
    *HttpStatus\i = 400
    Protected NoMethodMsg.s = "Invalid Request: method must be a string"
    If GetJSONMember(RootVal, "result") Or GetJSONMember(RootVal, "error")
      NoMethodMsg = "Invalid Request: client responses are not supported"
    EndIf
    Protected NoMethod.s = BuildErrorResponse(0, -32600, NoMethodMsg)
    FreeJSON(ReqJSON)
    ProcedureReturn NoMethod
  EndIf

  If JSONType(MethodMember) <> #PB_JSON_String
    *HttpStatus\i = 400
    Protected BadMethodType.s = BuildErrorResponse(GetJSONMember(RootVal, "id"), -32600, "Invalid Request: method must be a string")
    FreeJSON(ReqJSON)
    ProcedureReturn BadMethodType
  EndIf

  Protected Method.s = GetJSONString(MethodMember)
  Protected IdMember.i = GetJSONMember(RootVal, "id")

  If Method = ""
    *HttpStatus\i = 400
    Protected BadMethod.s = BuildErrorResponse(IdMember, -32600, "Invalid Request: method must be a string")
    FreeJSON(ReqJSON)
    ProcedureReturn BadMethod
  EndIf

  ; Notifications : pas de reponse attendue (JSON-RPC 2.0 / MCP).
  If Left(Method, 14) = "notifications/" Or IdMember = 0
    *HttpStatus\i = 202
    FreeJSON(ReqJSON)
    ProcedureReturn ""
  EndIf

  ; Cas particulier tools/list : le catalogue est deja un objet JSON.
  If Method = "tools/list"
    Protected CatalogJSON.i = #Null
    If *G_CatalogBuilder
      CatalogJSON = *G_CatalogBuilder()
    EndIf

    If CatalogJSON
      Protected CatalogBody.s = ComposeJSON(CatalogJSON)
      Protected IdFrag.s = JSONIdFragment(IdMember)
      FreeJSON(CatalogJSON)
      FreeJSON(ReqJSON)
      ProcedureReturn "{" + Chr(34) + "jsonrpc" + Chr(34) + ":" + Chr(34) + "2.0" + Chr(34) + "," + Chr(34) + "id" + Chr(34) + ":" + IdFrag + "," + Chr(34) + "result" + Chr(34) + ":" + CatalogBody + "}"
    EndIf

    Protected NoCatalog.s = BuildErrorResponse(IdMember, -32603, "Erreur : catalogue d'outils non configure")
    FreeJSON(ReqJSON)
    ProcedureReturn NoCatalog
  EndIf

  ; Methodes inconnues : erreur JSON-RPC explicite.
  If Method <> "initialize" And Method <> "tools/call" And Method <> "ping"
    Protected UnknownMethod.s = BuildErrorResponse(IdMember, -32601, "Method not found: " + Method)
    FreeJSON(ReqJSON)
    ProcedureReturn UnknownMethod
  EndIf

  ; Creation de la reponse JSON-RPC standard.
  Protected RespJSON.i = CreateJSON(#PB_Any)
  If RespJSON = 0
    Protected NoMemory.s = BuildErrorResponse(IdMember, -32603, "Erreur interne : memoire JSON insuffisante")
    FreeJSON(ReqJSON)
    ProcedureReturn NoMemory
  EndIf
  Protected RespRoot.i = SetJSONObject(JSONValue(RespJSON))
  SetJSONString(AddJSONMember(RespRoot, "jsonrpc"), "2.0")

  Protected ResId.i = AddJSONMember(RespRoot, "id")
  Select JSONType(IdMember)
    Case #PB_JSON_String
      SetJSONString(ResId, GetJSONString(IdMember))
    Case #PB_JSON_Number
      SetJSONDouble(ResId, GetJSONDouble(IdMember))
    Default
      SetJSONNull(ResId)
  EndSelect

  Protected ResultObj.i = AddJSONMember(RespRoot, "result")
  SetJSONObject(ResultObj)

  Select Method
    Case "initialize"
      Protected ParamsMember.i = GetJSONMember(RootVal, "params")
      Protected RequestedVersion.s = ""
      If ParamsMember And JSONType(ParamsMember) = #PB_JSON_Object
        RequestedVersion = GetArgString(ParamsMember, "protocolVersion")
      EndIf
      BuildInitializeResponse(ResultObj, RequestedVersion)

    Case "tools/call"
      Protected CallParams.i = GetJSONMember(RootVal, "params")
      Protected ToolName.s = ""
      Protected ArgsMember.i = #Null
      If CallParams And JSONType(CallParams) = #PB_JSON_Object
        ToolName = GetArgString(CallParams, "name")
        ArgsMember = GetJSONMember(CallParams, "arguments")
      EndIf

      Protected OutputStr.s = ""
      Protected IsErr.i = #False
      If *G_ToolHandler
        OutputStr = *G_ToolHandler(ToolName, ArgsMember, @IsErr)
      Else
        OutputStr = "Erreur : aucun gestionnaire d'outils configure."
        IsErr = #True
      EndIf

      If OutputStr = "ACCES_REFUSE"
        OutputStr = "Erreur : Acces refuse en dehors de la zone autorisee."
      EndIf
      If DetectIsError(OutputStr)
        IsErr = #True
      EndIf

      AttachResultPayload(ResultObj, OutputStr, IsErr)

    Case "ping"
      ; Resultat vide : objet {} deja cree.
  EndSelect

  Protected RespOut.s = ComposeJSON(RespJSON)
  FreeJSON(RespJSON)
  FreeJSON(ReqJSON)
  ProcedureReturn RespOut
EndProcedure
