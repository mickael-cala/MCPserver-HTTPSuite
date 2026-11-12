; ============================================================================
;  context7_core.pbi - Coeur metier du serveur MCP Context7
;  Resolution de bibliotheques + documentation via l'API context7.com.
;  Inclus par src/context7MCP.pb et tests/test_context7.pb.
; ============================================================================
;  API reelle (verifiee) :
;    GET https://context7.com/api/v1/search?query=X&libraryType=oss
;        -> {"results":[{"id":"/owner/repo","title":...,"description":...}]}
;    GET https://context7.com/api/v1/docs?libraryId=X&query=Y&tokens=N&topic=T
;        -> {"content":"..."}   (exige une cle : Authorization: Bearer ctx7sk...)
;  Codes : 401 cle manquante/invalide, 429 quota, 5xx indisponible.
; ============================================================================

Global G_C7ApiKey.s = ""
Global G_C7ApiBase.s = "https://context7.com/api/v1"

; Plafond de taille des reponses API (audit I5) : la documentation
; retournee reste bien en dessous de 8 Mio.
#C7_MAX_RESPONSE_BYTES = 8 * 1024 * 1024

; ---------------------------------------------------------------------------
; Mapping des erreurs HTTP en message MCP
; ---------------------------------------------------------------------------
Procedure.s C7HttpErrorText(Status.i, Prefix.s)
  Select Status
    Case -2
      ProcedureReturn Prefix + " : curl est introuvable ou a echoue sur cet OS (necessaire pour les en-tetes HTTP)."
    Case -1
      ProcedureReturn Prefix + " : echec reseau (DNS, connexion ou timeout)."
    Case -4
      ProcedureReturn Prefix + " : reponse trop volumineuse (plafond interne)."
    Case 401
      ProcedureReturn Prefix + " : cle API invalide ou manquante (401). Verifier MCP_CONTEXT7_API_KEY (prefixe ctx7sk)."
    Case 403
      ProcedureReturn Prefix + " : acces refuse (403)."
    Case 404
      ProcedureReturn Prefix + " : introuvable (404)."
    Case 429
      ProcedureReturn Prefix + " : quota depasse (429), reessayer dans quelques instants."
    Default
      If Status >= 500
        ProcedureReturn Prefix + " : Context7 indisponible (" + Str(Status) + ")."
      ElseIf Status <> 200
        ProcedureReturn Prefix + " : erreur HTTP " + Str(Status) + "."
      EndIf
  EndSelect
  ProcedureReturn ""
EndProcedure

; ---------------------------------------------------------------------------
; Outils MCP
; ---------------------------------------------------------------------------

; resolve_library_id : recherche de bibliotheques (fonctionne sans cle)
Procedure.s ToolResolveLibraryId(Query.s, LibraryType.s)
  If Trim(Query) = ""
    ProcedureReturn "Erreur : 'query' ne peut pas etre vide."
  EndIf
  If LibraryType = "" : LibraryType = "oss" : EndIf

  Protected Url.s = G_C7ApiBase + "/search?query=" + UrlEncodeComponent(Query) + "&libraryType=" + UrlEncodeComponent(LibraryType)
  Protected Status.i
  Protected Body.s = HttpGetLimited(Url, "", 15, #C7_MAX_RESPONSE_BYTES, @Status)
  If Status <> 200
    Protected Err.s = C7HttpErrorText(Status, "Erreur recherche")
    If Err <> "" : ProcedureReturn Err : EndIf
    ProcedureReturn "Erreur recherche : reponse vide (statut " + Str(Status) + ")."
  EndIf

  Protected J.i = ParseJSON(#PB_Any, Body)
  If J = 0
    ProcedureReturn "Erreur : reponse Context7 invalide (JSON illisible)."
  EndIf
  Protected Root.i = JSONValue(J)
  Protected Results.i = GetJSONMember(Root, "results")
  If Results = 0 Or JSONType(Results) <> #PB_JSON_Array
    FreeJSON(J)
    ProcedureReturn "Erreur : reponse Context7 invalide (pas de tableau 'results')."
  EndIf

  Protected n.i = JSONArraySize(Results)
  If n = 0
    FreeJSON(J)
    ProcedureReturn "Aucune bibliotheque trouvee pour '" + Query + "'."
  EndIf

  Protected Res.s = Str(n) + " bibliotheque(s) pour '" + Query + "' :" + #LF$
  Protected i.i
  For i = 0 To n - 1
    Protected Item.i = GetJSONElement(Results, i)
    Protected Id.s = GetArgString(Item, "id")
    Protected Title.s = GetArgString(Item, "title")
    Protected Descr.s = GetArgString(Item, "description")
    Res + Id + "  --  " + Title
    If Descr <> ""
      Res + "  --  " + Left(Descr, 120)
    EndIf
    Res + #LF$
  Next
  Res + "Utilisez query_docs avec l'id choisi (ex. /owner/repo)."
  FreeJSON(J)
  ProcedureReturn Res
EndProcedure

; query_docs : documentation d'une bibliotheque (cle API requise)
Procedure.s ToolQueryDocs(LibraryId.s, Query.s, Tokens.i, Topic.s, MaxLen.i)
  If Trim(LibraryId) = ""
    ProcedureReturn "Erreur : 'libraryId' est requis (ex. /reactjs/react.dev/latest)."
  EndIf
  If Tokens <= 0 : Tokens = 5000 : EndIf
  If MaxLen <= 0 : MaxLen = 10000 : EndIf

  ; Cle API requise : l'API renvoie un 400 trompeur ("invalid_format") sans
  ; en-tete Authorization -> on intercepte avant l'appel pour un message clair.
  If G_C7ApiKey = ""
    ProcedureReturn "Erreur : MCP_CONTEXT7_API_KEY non configure. Obtenez une cle sur https://context7.com (prefixe ctx7sk) puis relancez le serveur."
  EndIf

  Protected Auth.s = "Authorization: Bearer " + G_C7ApiKey

  Protected Url.s = G_C7ApiBase + "/docs?libraryId=" + UrlEncodeComponent(LibraryId) +
                    "&query=" + UrlEncodeComponent(Query) +
                    "&tokens=" + Str(Tokens)
  If Topic <> ""
    Url + "&topic=" + UrlEncodeComponent(Topic)
  EndIf

  Protected Status.i
  Protected Body.s = HttpGetLimited(Url, Auth, 20, #C7_MAX_RESPONSE_BYTES, @Status)
  If Status <> 200
    Protected Err.s = C7HttpErrorText(Status, "Erreur docs")
    If Err <> "" : ProcedureReturn Err : EndIf
    ProcedureReturn "Erreur docs : reponse vide (statut " + Str(Status) + ")."
  EndIf

  Protected J.i = ParseJSON(#PB_Any, Body)
  If J = 0
    ProcedureReturn "Erreur : reponse Context7 invalide (JSON illisible)."
  EndIf
  Protected Root.i = JSONValue(J)
  Protected Content.i = GetJSONMember(Root, "content")
  If Content = 0 Or JSONType(Content) <> #PB_JSON_String
    ; Erreur applicative JSON {"error":..., "message":...}
    Protected Msg.i = GetJSONMember(Root, "message")
    If Msg And JSONType(Msg) = #PB_JSON_String
      Protected AppMsg.s = GetJSONString(Msg)
      FreeJSON(J)
      ProcedureReturn "Erreur Context7 : " + AppMsg
    EndIf
    FreeJSON(J)
    ProcedureReturn "Erreur : reponse Context7 invalide (pas de 'content')."
  EndIf

  Protected Text.s = GetJSONString(Content)
  FreeJSON(J)

  ; Troncature locale max_length
  Protected TotalLen.i = Len(Text)
  Protected Out.s = Left(Text, MaxLen)
  If TotalLen > MaxLen
    Out + #LF$ + "[Contenu : " + Str(TotalLen) + " caracteres au total ; tronque a " + Str(MaxLen) + " ; augmentez 'tokens' ou affinez 'query']"
  EndIf
  ProcedureReturn Out
EndProcedure

; ---------------------------------------------------------------------------
; Catalogue MCP
; ---------------------------------------------------------------------------
Procedure.i C7BuildCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "resolve_library_id", "Recherche une bibliotheque sur Context7 et retourne la liste des identifiants (/owner/repo).", "query|string|Nom ou description de la bibliotheque;libraryType|string|Filtre (defaut: oss)", "query")
  ToolDef(ToolsArr, "query_docs", "Retourne la documentation d'une bibliotheque Context7 (cle API MCP_CONTEXT7_API_KEY requise).", "libraryId|string|Identifiant /owner/repo[/tag];query|string|Sujet recherche;tokens|integer|Budget de tokens (defaut: 5000);topic|string|Filtre de topic (optionnel);max_length|integer|Troncature locale du texte retourne (defaut: 10000)", "libraryId;query")

  ProcedureReturn RootJSON
EndProcedure

; ---------------------------------------------------------------------------
; Dispatch des outils (hook *G_ToolHandler)
; ---------------------------------------------------------------------------
Procedure.s C7Dispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Select ToolName
    Case "resolve_library_id"
      ProcedureReturn ToolResolveLibraryId(GetArgString(ArgsObj, "query"), GetArgString(ArgsObj, "libraryType"))
    Case "query_docs"
      ProcedureReturn ToolQueryDocs(GetArgString(ArgsObj, "libraryId"), GetArgString(ArgsObj, "query"), GetArgInt(ArgsObj, "tokens", 5000), GetArgString(ArgsObj, "topic"), GetArgInt(ArgsObj, "max_length", 10000))
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure
