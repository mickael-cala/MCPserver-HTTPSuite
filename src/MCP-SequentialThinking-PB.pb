; ============================================================================
;  SERVEUR MCP - Sequential Thinking (PureBasic HTTP)
;  Raisonnement sequentiel structure : etapes, revisions, branches
; ============================================================================
;  Compilation : build.bat / build.sh (ou Options du compilateur -> Console)
;  Transport   : JSON-RPC 2.0 sur HTTP (POST /mcp, JSON par defaut, SSE optionnel)
;  Modules     : mcp_common/ (runtime, logging, json_helpers, protocol,
;                jsonrpc, http_server)
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

; ---------------------------------------------------------------------------
; Etat des sessions de raisonnement
; ---------------------------------------------------------------------------
Structure ThoughtData
  Thought.s
  ThoughtNumber.i
  TotalThoughts.i
  NextThoughtNeeded.i
  IsRevision.i
  RevisesThought.i
  BranchFromThought.i
  BranchId.s
EndStructure

Global NewList ThoughtHistory.ThoughtData()
Global NewMap Branches.i()   ; branchId -> nombre de pensees sur cette branche

; ---------------------------------------------------------------------------
; Outil principal
; ---------------------------------------------------------------------------
Procedure.s ToolSequentialThinking(ArgsObj.i)
  Protected Thought.s        = GetArgString(ArgsObj, "thought")
  Protected ThoughtNum.i     = GetArgInt(ArgsObj, "thoughtNumber", 0)
  Protected TotalThoughts.i  = GetArgInt(ArgsObj, "totalThoughts", 0)
  Protected NextNeeded.i     = GetArgBool(ArgsObj, "nextThoughtNeeded", 0)
  Protected IsRevision.i     = GetArgBool(ArgsObj, "isRevision", 0)
  Protected RevisesThought.i = GetArgInt(ArgsObj, "revisesThought", 0)
  Protected BranchFrom.i     = GetArgInt(ArgsObj, "branchFromThought", 0)
  Protected BranchId.s       = GetArgString(ArgsObj, "branchId")

  If Trim(Thought) = ""
    ProcedureReturn "ERREUR: le parametre 'thought' ne peut pas etre vide."
  EndIf
  If ThoughtNum < 1
    ProcedureReturn "ERREUR: 'thoughtNumber' doit etre un entier >= 1."
  EndIf
  If TotalThoughts < 1
    TotalThoughts = ThoughtNum
  EndIf
  If TotalThoughts < ThoughtNum
    TotalThoughts = ThoughtNum
  EndIf

  AddElement(ThoughtHistory())
  ThoughtHistory()\Thought           = Thought
  ThoughtHistory()\ThoughtNumber     = ThoughtNum
  ThoughtHistory()\TotalThoughts     = TotalThoughts
  ThoughtHistory()\NextThoughtNeeded = NextNeeded
  ThoughtHistory()\IsRevision        = IsRevision
  ThoughtHistory()\RevisesThought    = RevisesThought
  ThoughtHistory()\BranchFromThought = BranchFrom
  ThoughtHistory()\BranchId          = BranchId

  If BranchId <> ""
    If FindMapElement(Branches(), BranchId)
      Branches() = Branches() + 1
    Else
      AddMapElement(Branches(), BranchId)
      Branches() = 1
    EndIf
  EndIf

  ; Reponse structuree (meme forme que l'implementation de reference)
  Protected RespJSON.i = CreateJSON(#PB_Any)
  Protected Root.i = SetJSONObject(JSONValue(RespJSON))
  SetJSONInteger(AddJSONMember(Root, "thoughtNumber"), ThoughtNum)
  SetJSONInteger(AddJSONMember(Root, "totalThoughts"), TotalThoughts)
  SetJSONBoolean(AddJSONMember(Root, "nextThoughtNeeded"), Bool(NextNeeded))

  Protected BranchArr.i = AddJSONMember(Root, "branches")
  SetJSONArray(BranchArr)
  ForEach Branches()
    SetJSONString(AddJSONElement(BranchArr), MapKey(Branches()))
  Next

  SetJSONInteger(AddJSONMember(Root, "thoughtHistoryLength"), ListSize(ThoughtHistory()))

  Protected Out.s = ComposeJSON(RespJSON)
  FreeJSON(RespJSON)
  ProcedureReturn Out
EndProcedure

; ---------------------------------------------------------------------------
; Catalogue MCP (hook *G_CatalogBuilder)
; ---------------------------------------------------------------------------
Procedure.i BuildToolsCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  Protected ToolObj.i = AddJSONElement(ToolsArr)
  SetJSONObject(ToolObj)
  SetJSONString(AddJSONMember(ToolObj, "name"), "sequential_thinking")
  SetJSONString(AddJSONMember(ToolObj, "description"), "Enregistre une etape de raisonnement et retourne l'etat courant (numero, total, revisions, branches).")

  Protected SchemaObj.i = AddJSONMember(ToolObj, "inputSchema")
  SetJSONObject(SchemaObj)
  SetJSONString(AddJSONMember(SchemaObj, "type"), "object")

  Protected PropsObj.i = AddJSONMember(SchemaObj, "properties")
  SetJSONObject(PropsObj)

  AddPropString(PropsObj, "thought", "Le contenu de l'etape de raisonnement courante.")
  AddPropInteger(PropsObj, "thoughtNumber", "Numero de l'etape courante (commence a 1).", 1)
  AddPropInteger(PropsObj, "totalThoughts", "Nombre total d'etapes estimees.", 1)
  AddPropBoolean(PropsObj, "nextThoughtNeeded", "Indique si une autre etape est necessaire.", 0)
  AddPropBoolean(PropsObj, "isRevision", "Indique si cette etape revise une etape precedente.", 0)
  AddPropInteger(PropsObj, "revisesThought", "Numero de l'etape revisee (si isRevision).", 0)
  AddPropInteger(PropsObj, "branchFromThought", "Numero de l'etape d'ou diverge une branche.", 0)
  AddPropString(PropsObj, "branchId", "Identifiant de la branche de raisonnement.")

  Protected ReqArr.i = AddJSONMember(SchemaObj, "required")
  SetJSONArray(ReqArr)
  SetJSONString(AddJSONElement(ReqArr), "thought")
  SetJSONString(AddJSONElement(ReqArr), "thoughtNumber")
  SetJSONString(AddJSONElement(ReqArr), "totalThoughts")
  SetJSONString(AddJSONElement(ReqArr), "nextThoughtNeeded")

  ProcedureReturn RootJSON
EndProcedure

; ---------------------------------------------------------------------------
; Dispatch des outils (hook *G_ToolHandler)
; ---------------------------------------------------------------------------
Procedure.s ToolDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Select ToolName
    Case "sequential_thinking"
      ProcedureReturn ToolSequentialThinking(ArgsObj)
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "SequentialThinkingMCPServer-PureBasic"
G_ServerVersion = "2.0.0"
*G_ToolHandler = @ToolDispatch()
*G_CatalogBuilder = @BuildToolsCatalog()

If Not CheckRuntime()
  End 1
EndIf

If Not MCPHttpMainLoop(8103)
  End 1
EndIf

End
