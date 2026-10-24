; ============================================================================
;  SERVEUR MCP - Fetch (PureBasic HTTP)
;  Recuperation de pages web + conversion HTML -> Markdown
; ============================================================================
;  Compilation : build.bat / build.sh (ou Options du compilateur -> Console)
;  Transport   : JSON-RPC 2.0 sur HTTP (POST /mcp, JSON uniquement, sans SSE)
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
; Validation d'URL et garde-fous de securite
; ---------------------------------------------------------------------------
Procedure.i IsPrivateHost(Host.s)
  ; Refuse les adresses privees / loopback / link-local (comme la reference)
  Host = LCase(Trim(Host))
  If Host = "localhost" Or Host = "127.0.0.1" Or Host = "::1"
    ProcedureReturn #True
  EndIf
  ; Plages IPv4 privees courantes
  Protected Part1.i
  If FindString(Host, ".") > 0
    Part1 = Val(StringField(Host, 1, "."))
    If Part1 = 10 : ProcedureReturn #True : EndIf
    If Part1 = 172
      Protected Part2.i = Val(StringField(Host, 2, "."))
      If Part2 >= 16 And Part2 <= 31 : ProcedureReturn #True : EndIf
    EndIf
    If Part1 = 192
      Protected P2.i = Val(StringField(Host, 2, "."))
      If P2 = 168 : ProcedureReturn #True : EndIf
    EndIf
    If Part1 = 169
      Protected P2b.i = Val(StringField(Host, 2, "."))
      If P2b = 254 : ProcedureReturn #True : EndIf   ; link-local / metadata
    EndIf
  EndIf
  ProcedureReturn #False
EndProcedure

Procedure.s ValidateFetchUrl(Url.s)
  Url = Trim(Url)
  If Url = "" : ProcedureReturn "" : EndIf
  Protected Scheme.s = LCase(GetURLPart(Url, #PB_URL_Protocol))
  If Scheme <> "http" And Scheme <> "https"
    ProcedureReturn ""
  EndIf
  Protected Host.s = GetURLPart(Url, #PB_URL_Site)
  If Host = "" Or IsPrivateHost(Host)
    ProcedureReturn ""
  EndIf
  ProcedureReturn Url
EndProcedure

; ---------------------------------------------------------------------------
; Recuperation HTTP en memoire
; ---------------------------------------------------------------------------
Procedure.s HttpGetMemory(Url.s, *OutStatus.Integer)
  Protected Req.i = HTTPRequestMemory(#PB_HTTP_Get, Url)
  If Not Req
    *OutStatus\i = -1
    ProcedureReturn ""
  EndIf

  Protected Status.i = Val(HTTPInfo(Req, #PB_HTTP_StatusCode))
  *OutStatus\i = Status

  Protected Result.s = ""
  If Status >= 200 And Status < 300
    Protected *Buf = HTTPMemory(Req)
    If *Buf
      Protected Size.i = MemorySize(*Buf)
      If Size > 0
        Result = PeekS(*Buf, Size, #PB_UTF8 | #PB_ByteLength)
      EndIf
    EndIf
  EndIf

  FinishHTTP(Req)
  ProcedureReturn Result
EndProcedure

; ---------------------------------------------------------------------------
; Conversion HTML -> Markdown (basique mais fonctionnelle)
; ---------------------------------------------------------------------------
Procedure.s HtmlToMarkdown(Html.s)
  Protected Md.s = Html

  ; Supprimer les blocs non desires
  Md = ReplaceString(Md, Chr(13), " ")
  Md = ReplaceString(Md, Chr(10), " ")

  ; Supprimer script / style (approche par expressions simples)
  Protected i.i
  ; <script>...</script>
  Repeat
    i = FindString(LCase(Md), "<script")
    If i = 0 : Break : EndIf
    Protected EndScript.i = FindString(LCase(Md), "</script>", i)
    If EndScript = 0 : Break : EndIf
    Md = Left(Md, i - 1) + Mid(Md, EndScript + 9)
  ForEver
  ; <style>...</style>
  Repeat
    i = FindString(LCase(Md), "<style")
    If i = 0 : Break : EndIf
    Protected EndStyle.i = FindString(LCase(Md), "</style>", i)
    If EndStyle = 0 : Break : EndIf
    Md = Left(Md, i - 1) + Mid(Md, EndStyle + 8)
  ForEver

  ; Titres
  Protected h.i
  For h = 1 To 6
    Protected OpenTag.s = "<h" + Str(h) + ">"
    Protected CloseTag.s = "</h" + Str(h) + ">"
    Protected Prefix.s = StringField(" # ## ### #### ##### ######", h + 1, " ") + " "
    Repeat
      i = FindString(LCase(Md), OpenTag)
      If i = 0 : Break : EndIf
      Protected EndH.i = FindString(LCase(Md), CloseTag, i)
      If EndH = 0 : Break : EndIf
      Protected Inner.s = Mid(Md, i + Len(OpenTag), EndH - (i + Len(OpenTag)))
      Md = Left(Md, i - 1) + Prefix + Inner + Mid(Md, EndH + Len(CloseTag))
    ForEver
  Next

  ; Gras / italique (ordre important)
  Md = ReplaceString(Md, "<strong>", "**")
  Md = ReplaceString(Md, "</strong>", "**")
  Md = ReplaceString(Md, "<b>", "**")
  Md = ReplaceString(Md, "</b>", "**")
  Md = ReplaceString(Md, "<em>", "*")
  Md = ReplaceString(Md, "</em>", "*")
  Md = ReplaceString(Md, "<i>", "*")
  Md = ReplaceString(Md, "</i>", "*")

  ; Liens
  Repeat
    i = FindString(LCase(Md), "<a ")
    If i = 0 : Break : EndIf
    Protected EndA.i = FindString(LCase(Md), "</a>", i)
    If EndA = 0 : Break : EndIf
    Protected ATag.s = Mid(Md, i, EndA - i)
    Protected Href.s = ""
    Protected HrefPos.i = FindString(LCase(ATag), "href=")
    If HrefPos > 0
      Protected HrefStart.i = HrefPos + 5
      Protected Quote.s = Mid(ATag, HrefStart, 1)
      If Quote = Chr(34) Or Quote = "'"
        HrefStart + 1
        Protected HrefEnd.i = FindString(ATag, Quote, HrefStart)
        If HrefEnd > 0
          Href = Mid(ATag, HrefStart, HrefEnd - HrefStart)
        EndIf
      EndIf
    EndIf
    Protected LinkText.s = Mid(Md, i + Len(ATag), EndA - (i + Len(ATag)))
    Protected Replacement.s = "[" + Trim(LinkText) + "](" + Href + ")"
    Md = Left(Md, i - 1) + Replacement + Mid(Md, EndA + 4)
  ForEver

  ; Sauts de ligne
  Md = ReplaceString(Md, "<br>", #LF$)
  Md = ReplaceString(Md, "<br/>", #LF$)
  Md = ReplaceString(Md, "<br />", #LF$)
  Md = ReplaceString(Md, "<p>", #LF$ + #LF$)
  Md = ReplaceString(Md, "</p>", #LF$ + #LF$)

  ; Supprimer toutes les autres balises restantes
  Repeat
    i = FindString(Md, "<")
    If i = 0 : Break : EndIf
    Protected j.i = FindString(Md, ">", i)
    If j = 0 : Break : EndIf
    Md = Left(Md, i - 1) + Mid(Md, j + 1)
  ForEver

  ; Nettoyage des entites HTML basiques
  Md = ReplaceString(Md, "&nbsp;", " ")
  Md = ReplaceString(Md, "&amp;", "&")
  Md = ReplaceString(Md, "&lt;", "<")
  Md = ReplaceString(Md, "&gt;", ">")
  Md = ReplaceString(Md, "&quot;", Chr(34))

  ; Normaliser les espaces multiples
  While FindString(Md, "  ")
    Md = ReplaceString(Md, "  ", " ")
  Wend

  ProcedureReturn Trim(Md)
EndProcedure

; ---------------------------------------------------------------------------
; Outil fetch
; ---------------------------------------------------------------------------
Procedure.s ToolFetch(ArgsObj.i)
  Protected Url.s         = GetArgString(ArgsObj, "url")
  Protected MaxLength.i   = GetArgInt(ArgsObj, "max_length", 5000)
  Protected StartIndex.i  = GetArgInt(ArgsObj, "start_index", 0)
  Protected Raw.i         = GetArgBool(ArgsObj, "raw", 0)

  Protected SafeUrl.s = ValidateFetchUrl(Url)
  If SafeUrl = ""
    ProcedureReturn "ERREUR: URL invalide ou hote prive/loopback refuse."
  EndIf

  Protected Status.i
  Protected Html.s = HttpGetMemory(SafeUrl, @Status)
  If Status < 200 Or Status >= 300
    ProcedureReturn "ERREUR: echec HTTP (statut " + Str(Status) + ") pour " + SafeUrl
  EndIf
  If Html = ""
    ProcedureReturn "ERREUR: contenu vide ou illisible."
  EndIf

  Protected Content.s
  If Raw
    Content = Html
  Else
    Content = HtmlToMarkdown(Html)
  EndIf

  Protected TotalLen.i = Len(Content)
  If StartIndex >= TotalLen
    ProcedureReturn "ERREUR: start_index (" + Str(StartIndex) + ") depasse la taille du contenu (" + Str(TotalLen) + " caracteres)."
  EndIf

  Protected EndIndex.i = StartIndex + MaxLength
  If EndIndex > TotalLen : EndIndex = TotalLen : EndIf
  Protected Chunk.s = Mid(Content, StartIndex + 1, EndIndex - StartIndex)

  Protected Result.s = Chunk + #LF$ + "[Contenu: " + Str(TotalLen) + " caracteres au total"
  If EndIndex < TotalLen
    Result + " ; tronque a " + Str(EndIndex) + " ; utilisez start_index=" + Str(EndIndex) + " pour la suite"
  EndIf
  Result + "]"

  ProcedureReturn Result
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
  SetJSONString(AddJSONMember(ToolObj, "name"), "fetch")
  SetJSONString(AddJSONMember(ToolObj, "description"), "Recupere une URL et retourne son contenu en Markdown (ou HTML brut si raw=true).")

  Protected SchemaObj.i = AddJSONMember(ToolObj, "inputSchema")
  SetJSONObject(SchemaObj)
  SetJSONString(AddJSONMember(SchemaObj, "type"), "object")

  Protected PropsObj.i = AddJSONMember(SchemaObj, "properties")
  SetJSONObject(PropsObj)

  AddPropString(PropsObj, "url", "URL a recuperer (http/https).")
  AddPropInteger(PropsObj, "max_length", "Nombre maximum de caracteres a retourner.", 5000)
  AddPropInteger(PropsObj, "start_index", "Index de depart dans le contenu.", 0)
  AddPropBoolean(PropsObj, "raw", "Retourner le HTML brut sans conversion Markdown.", 0)

  Protected ReqArr.i = AddJSONMember(SchemaObj, "required")
  SetJSONArray(ReqArr)
  SetJSONString(AddJSONElement(ReqArr), "url")

  ProcedureReturn RootJSON
EndProcedure

; ---------------------------------------------------------------------------
; Dispatch des outils (hook *G_ToolHandler)
; ---------------------------------------------------------------------------
Procedure.s ToolDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Select ToolName
    Case "fetch"
      ProcedureReturn ToolFetch(ArgsObj)
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "FetchMCPServer-PureBasic"
G_ServerVersion = "2.0.0"
*G_ToolHandler = @ToolDispatch()
*G_CatalogBuilder = @BuildToolsCatalog()

If Not CheckRuntime()
  End 1
EndIf

If Not MCPHttpMainLoop(8102)
  End 1
EndIf

End
