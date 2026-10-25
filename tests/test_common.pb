; ============================================================================
;  test_common.pb - Tests unitaires des modules communs mcp_common/
;  Couvre : json_helpers (arguments, proprietes), DetectIsError,
;  protocole MCP et noyau JSON-RPC transport-agnostique.
; ============================================================================
;  Compilation : lance par run_all.bat / run_all.sh (ou manuellement)
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../tests/unit_test.pbi"

; ---------------------------------------------------------------------------
; GetArgString / GetArgInt / GetArgBool
; ---------------------------------------------------------------------------
Procedure TestGetArgs()
  Protected J.i = ParseJSON(#PB_Any, ~"{\"s\":\"bonjour\",\"n\":42,\"b\":true,\"bn\":1}")
  Protected Args.i = JSONValue(J)

  UTAssertStr("bonjour", GetArgString(Args, "s"), "GetArgString lit une chaine")
  UTAssertStr("", GetArgString(Args, "absent"), "GetArgString cle absente -> vide")
  UTAssertStr("", GetArgString(#Null, "s"), "GetArgString objet nul -> vide")

  UTAssert(42, GetArgInt(Args, "n", -1), "GetArgInt lit un entier")
  UTAssert(-1, GetArgInt(Args, "absent", -1), "GetArgInt cle absente -> defaut")
  UTAssert(-1, GetArgInt(#Null, "n", -1), "GetArgInt objet nul -> defaut")

  UTAssert(1, GetArgBool(Args, "b", 0), "GetArgBool lit un booleen vrai")
  UTAssert(1, GetArgBool(Args, "bn", 0), "GetArgBool accepte un nombre non nul")
  UTAssert(0, GetArgBool(Args, "absent", 0), "GetArgBool cle absente -> defaut")

  FreeJSON(J)
EndProcedure

; ---------------------------------------------------------------------------
; DetectIsError
; ---------------------------------------------------------------------------
Procedure TestDetectIsError()
  UTAssert(1, DetectIsError("ACCES_REFUSE"), "ACCES_REFUSE est une erreur")
  UTAssert(1, DetectIsError("Erreur : fichier illisible"), "prefixe Erreur detecte")
  UTAssert(1, DetectIsError("ERREUR: URL invalide"), "prefixe ERREUR detecte")
  UTAssert(1, DetectIsError("Impossible d'ouvrir le fichier"), "prefixe Impossible detecte")
  UTAssert(1, DetectIsError("Echec du deplacement"), "prefixe Echec detecte")
  UTAssert(1, DetectIsError("Fichier introuvable : x"), "introuvable detecte")
  UTAssert(1, DetectIsError("Modification refusee : secret invalide"), "refusee detecte")
  UTAssert(1, DetectIsError("Fichier depasse la limite de 5 Mo."), "depasse detecte")

  UTAssert(0, DetectIsError("Fichier ecrit avec succes (12 octets)"), "succes non detecte")
  UTAssert(0, DetectIsError("Repertoire cree : /tmp/x"), "creation non detectee")
  UTAssert(0, DetectIsError("pong"), "reponse neutre non detectee")
EndProcedure

; ---------------------------------------------------------------------------
; AddProp* / ToolDef : construction de schéma
; ---------------------------------------------------------------------------
Procedure TestSchemaBuilders()
  Protected J.i = CreateJSON(#PB_Any)
  Protected Root.i = SetJSONObject(JSONValue(J))
  Protected ToolsArr.i = AddJSONMember(Root, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "demo", "Outil de demo.", "a|string|Parametre A;b|integer|Parametre B", "a")

  Protected Out.s = ComposeJSON(J)
  UTAssertContains(Out, "demo", "ToolDef: nom present")
  UTAssertContains(Out, "Parametre A", "ToolDef: description presente")
  UTAssertContains(Out, "integer", "ToolDef: type integer present")
  UTAssertContains(Out, "required", "ToolDef: bloc required present")

  FreeJSON(J)
EndProcedure

; ---------------------------------------------------------------------------
; Catalogue et dispatch factices pour tester le noyau JSON-RPC
; ---------------------------------------------------------------------------
Procedure.i TestCatalogBuilder()
  Protected J.i = CreateJSON(#PB_Any)
  Protected Root.i = SetJSONObject(JSONValue(J))
  Protected ToolsArr.i = AddJSONMember(Root, "tools")
  SetJSONArray(ToolsArr)
  ToolDef(ToolsArr, "echo", "Repete le texte recu.", "text|string|Texte a repeter", "text")
  ProcedureReturn J
EndProcedure

Procedure.s TestToolHandler(ToolName.s, ArgsObj.i, *IsError.Integer)
  Select ToolName
    Case "echo"
      ProcedureReturn GetArgString(ArgsObj, "text")
    Case "fail"
      *IsError\i = #True
      ProcedureReturn "Erreur : echec de test"
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure

; ---------------------------------------------------------------------------
; Helpers de lecture des reponses JSON-RPC
; ---------------------------------------------------------------------------
Procedure.i RespErrorCode(Json.s)
  Protected J.i = ParseJSON(#PB_Any, Json)
  If J = 0 : ProcedureReturn -9999 : EndIf
  Protected ErrObj.i = GetJSONMember(JSONValue(J), "error")
  Protected Code.i = -8888
  If ErrObj And JSONType(ErrObj) = #PB_JSON_Object
    Code = GetJSONInteger(GetJSONMember(ErrObj, "code"))
  EndIf
  FreeJSON(J)
  ProcedureReturn Code
EndProcedure

Procedure.s RespToolText(Json.s)
  Protected J.i = ParseJSON(#PB_Any, Json)
  If J = 0 : ProcedureReturn "" : EndIf
  Protected Result.i = GetJSONMember(JSONValue(J), "result")
  Protected Text.s = ""
  If Result And JSONType(Result) = #PB_JSON_Object
    Protected Content.i = GetJSONMember(Result, "content")
    If Content And JSONType(Content) = #PB_JSON_Array And JSONArraySize(Content) > 0
      Protected Item.i = GetJSONElement(Content, 0)
      Text = GetJSONString(GetJSONMember(Item, "text"))
    EndIf
  EndIf
  FreeJSON(J)
  ProcedureReturn Text
EndProcedure

; ---------------------------------------------------------------------------
; Protocole MCP : versions supportees (HTTP JSON, sans SSE)
; ---------------------------------------------------------------------------
Procedure TestProtocolVersions()
  UTAssert(1, IsSupportedProtocolVersion("2025-06-18"), "version 2025-06-18 supportee")
  UTAssert(1, IsSupportedProtocolVersion("2025-03-26"), "version 2025-03-26 supportee")
  UTAssert(0, IsSupportedProtocolVersion("2024-11-05"), "version 2024-11-05 refusee (pas de SSE)")
  UTAssert(0, IsSupportedProtocolVersion(""), "version vide refusee")
EndProcedure

; ---------------------------------------------------------------------------
; Noyau JSON-RPC
; ---------------------------------------------------------------------------
Procedure TestJsonRpc()
  Protected R.s, J.i, Root.i, Res.i, Arr.i, Status.i

  R = ProcessRequestToJSON(~"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}", @Status)
  J = ParseJSON(#PB_Any, R)
  UTAssert(1, Bool(J <> 0), "JSON-RPC initialize : reponse JSON")
  Root = JSONValue(J)
  Res = GetJSONMember(Root, "result")
  UTAssertStr("2025-06-18", GetJSONString(GetJSONMember(Res, "protocolVersion")), "JSON-RPC initialize : version")
  UTAssert(1, Bool(GetJSONMember(Res, "serverInfo") <> 0), "JSON-RPC initialize : serverInfo")
  FreeJSON(J)

  R = ProcessRequestToJSON(~"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", @Status)
  J = ParseJSON(#PB_Any, R)
  Root = JSONValue(J)
  Res = GetJSONMember(Root, "result")
  Arr = GetJSONMember(Res, "tools")
  UTAssert(1, JSONArraySize(Arr), "JSON-RPC tools/list : 1 outil")
  UTAssertStr("echo", GetJSONString(GetJSONMember(GetJSONElement(Arr, 0), "name")), "JSON-RPC tools/list : nom echo")
  FreeJSON(J)

  R = ProcessRequestToJSON(~"{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"ping\"}", @Status)
  J = ParseJSON(#PB_Any, R)
  UTAssertStr("abc", GetJSONString(GetJSONMember(JSONValue(J), "id")), "JSON-RPC : id string preserve")
  FreeJSON(J)

  R = ProcessRequestToJSON(~"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"bonjour\"}}}", @Status)
  UTAssertStr("bonjour", RespToolText(R), "JSON-RPC tools/call : texte")
  J = ParseJSON(#PB_Any, R)
  Res = GetJSONMember(JSONValue(J), "result")
  UTAssert(0, GetJSONBoolean(GetJSONMember(Res, "isError")), "JSON-RPC tools/call : isError false")
  FreeJSON(J)

  R = ProcessRequestToJSON(~"{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"fail\",\"arguments\":{}}}", @Status)
  J = ParseJSON(#PB_Any, R)
  Res = GetJSONMember(JSONValue(J), "result")
  UTAssert(1, GetJSONBoolean(GetJSONMember(Res, "isError")), "JSON-RPC tools/call : isError true")
  FreeJSON(J)

  R = ProcessRequestToJSON(~"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", @Status)
  UTAssertStr("", R, "JSON-RPC notification : pas de reponse")
  UTAssert(202, Status, "JSON-RPC notification : HTTP 202")

  R = ProcessRequestToJSON(~"{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"inconnue\"}", @Status)
  UTAssert(-32601, RespErrorCode(R), "JSON-RPC methode inconnue : -32601")

  R = ProcessRequestToJSON("{", @Status)
  UTAssert(-32700, RespErrorCode(R), "JSON-RPC JSON invalide : -32700")
  UTAssert(400, Status, "JSON-RPC JSON invalide : HTTP 400")

  R = ProcessRequestToJSON("[]", @Status)
  UTAssert(-32600, RespErrorCode(R), "JSON-RPC lot : -32600")
  UTAssert(400, Status, "JSON-RPC lot : HTTP 400")

  R = ProcessRequestToJSON(~"{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}", @Status)
  UTAssert(-32600, RespErrorCode(R), "JSON-RPC reponse client refusee : -32600")
  UTAssert(400, Status, "JSON-RPC reponse client : HTTP 400")
EndProcedure

; ---------------------------------------------------------------------------
; Programme principal
; -------------------------------------------------------------------
G_ServerName = "TestMCPServer-PureBasic"
G_ServerVersion = "2.0.0"
*G_ToolHandler = @TestToolHandler()
*G_CatalogBuilder = @TestCatalogBuilder()

If Not CheckRuntime()
  End 1
EndIf

TestGetArgs()
TestDetectIsError()
TestSchemaBuilders()
TestProtocolVersions()
TestJsonRpc()

UTFinalize()

End
