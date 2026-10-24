; ============================================================================
;  json_helpers.pbi - Helpers JSON partages (arguments d'outils, schémas)
;  Partage par tous les serveurs MCP du depot.
; ============================================================================
;  A inclure apres runtime.pbi :
;    IncludeFile "../mcp_common/json_helpers.pbi"
; ============================================================================

; ---------------------------------------------------------------------------
; Lecture d'arguments (objet "arguments" d'un tools/call)
; ---------------------------------------------------------------------------
Procedure.s GetArgString(ArgsObj.i, Key.s)
  If ArgsObj And JSONType(ArgsObj) = #PB_JSON_Object
    Protected Member.i = GetJSONMember(ArgsObj, Key)
    If Member And JSONType(Member) = #PB_JSON_String
      ProcedureReturn GetJSONString(Member)
    EndIf
  EndIf
  ProcedureReturn ""
EndProcedure

Procedure.i GetArgInt(ArgsObj.i, Key.s, DefaultVal.i)
  If ArgsObj And JSONType(ArgsObj) = #PB_JSON_Object
    Protected Member.i = GetJSONMember(ArgsObj, Key)
    If Member And JSONType(Member) = #PB_JSON_Number
      ProcedureReturn GetJSONInteger(Member)
    EndIf
  EndIf
  ProcedureReturn DefaultVal
EndProcedure

Procedure.i GetArgBool(ArgsObj.i, Key.s, DefaultVal.i)
  If ArgsObj And JSONType(ArgsObj) = #PB_JSON_Object
    Protected Member.i = GetJSONMember(ArgsObj, Key)
    If Member
      Protected T.i = JSONType(Member)
      If T = #PB_JSON_Boolean
        ProcedureReturn Bool(GetJSONBoolean(Member))
      ElseIf T = #PB_JSON_Number
        ProcedureReturn Bool(GetJSONInteger(Member) <> 0)
      EndIf
    EndIf
  EndIf
  ProcedureReturn DefaultVal
EndProcedure

; Retourne le membre tableau d'un objet d'arguments, ou #Null s'il est
; absent ou n'est pas un tableau. Iterer ensuite avec JSONArraySize() /
; GetJSONElement().
Procedure.i GetArgArray(ArgsObj.i, Key.s)
  If ArgsObj And JSONType(ArgsObj) = #PB_JSON_Object
    Protected Member.i = GetJSONMember(ArgsObj, Key)
    If Member And JSONType(Member) = #PB_JSON_Array
      ProcedureReturn Member
    EndIf
  EndIf
  ProcedureReturn #Null
EndProcedure

; ---------------------------------------------------------------------------
; Construction de proprietes de schéma d'outil
; ---------------------------------------------------------------------------
Procedure AddPropString(Obj.i, Key.s, Descr.s)
  Protected P.i = AddJSONMember(Obj, Key)
  SetJSONObject(P)
  SetJSONString(AddJSONMember(P, "type"), "string")
  SetJSONString(AddJSONMember(P, "description"), Descr)
EndProcedure

Procedure AddPropInteger(Obj.i, Key.s, Descr.s, DefVal.i)
  Protected P.i = AddJSONMember(Obj, Key)
  SetJSONObject(P)
  SetJSONString(AddJSONMember(P, "type"), "integer")
  SetJSONString(AddJSONMember(P, "description"), Descr)
  SetJSONInteger(AddJSONMember(P, "default"), DefVal)
EndProcedure

Procedure AddPropBoolean(Obj.i, Key.s, Descr.s, DefVal.i)
  Protected P.i = AddJSONMember(Obj, Key)
  SetJSONObject(P)
  SetJSONString(AddJSONMember(P, "type"), "boolean")
  SetJSONString(AddJSONMember(P, "description"), Descr)
  SetJSONBoolean(AddJSONMember(P, "default"), DefVal)
EndProcedure

; ---------------------------------------------------------------------------
; Variante generique (type passe en parametre) + definition complete d'outil
; ---------------------------------------------------------------------------
Procedure AddProp(Obj.i, Key.s, Type.s, Descr.s)
  Protected P.i = AddJSONMember(Obj, Key)
  SetJSONObject(P)
  SetJSONString(AddJSONMember(P, "type"), Type)
  SetJSONString(AddJSONMember(P, "description"), Descr)
EndProcedure

Procedure AddReq(Arr.i, Key.s)
  SetJSONString(AddJSONElement(Arr), Key)
EndProcedure

; Construit la definition d'un outil MCP. PropsSpec = proprietes separees par
; des ';', chaque entree etant 'cle|type|description'. ReqSpec = cles
; requises separees par des ';'. Tout est cree nativement dans le document
; cible (pas de valeurs partagees -> pas de segfault).
Procedure ToolDef(ToolsArr.i, Name.s, Descr.s, PropsSpec.s, ReqSpec.s)
  Protected ToolObj.i = AddJSONElement(ToolsArr)
  SetJSONObject(ToolObj)
  SetJSONString(AddJSONMember(ToolObj, "name"), Name)
  SetJSONString(AddJSONMember(ToolObj, "description"), Descr)
  Protected SchemaObj.i = AddJSONMember(ToolObj, "inputSchema")
  SetJSONObject(SchemaObj)
  SetJSONString(AddJSONMember(SchemaObj, "type"), "object")
  Protected PropsObj.i = AddJSONMember(SchemaObj, "properties")
  SetJSONObject(PropsObj)
  Protected ReqArr.i = AddJSONMember(SchemaObj, "required")
  SetJSONArray(ReqArr)

  Protected i.i, n.i = CountString(PropsSpec, ";") + 1, Entry.s, K.s, T.s, D.s
  For i = 1 To n
    Entry = Trim(StringField(PropsSpec, i, ";"))
    If Entry <> ""
      K = Trim(StringField(Entry, 1, "|"))
      T = Trim(StringField(Entry, 2, "|"))
      D = Trim(StringField(Entry, 3, "|"))
      AddProp(PropsObj, K, T, D)
    EndIf
  Next
  n = CountString(ReqSpec, ";") + 1
  For i = 1 To n
    Entry = Trim(StringField(ReqSpec, i, ";"))
    If Entry <> "" : AddReq(ReqArr, Entry) : EndIf
  Next
EndProcedure
