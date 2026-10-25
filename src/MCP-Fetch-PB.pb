; ============================================================================
;  SERVEUR MCP - Fetch (PureBasic HTTP)
;  Recuperation de pages web + conversion HTML -> Markdown
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
IncludeFile "../mcp_common/http.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

#FETCH_MAX_BYTES = 2 * 1024 * 1024

; ---------------------------------------------------------------------------
; Validation d'URL et garde-fous de securite (SSRF)
; ---------------------------------------------------------------------------
Procedure.i LooksLikeIP(Tok.s)
  Tok = Trim(Tok)
  If Tok = "" : ProcedureReturn #False : EndIf
  If FindString(Tok, ":") > 0 : ProcedureReturn #True : EndIf
  If CountString(Tok, ".") = 3
    Protected i.i, j.i, Part.s, c.i
    For i = 1 To 4
      Part = StringField(Tok, i, ".")
      If Part = "" : ProcedureReturn #False : EndIf
      For j = 1 To Len(Part)
        c = Asc(Mid(Part, j, 1))
        If c < 48 Or c > 57 : ProcedureReturn #False : EndIf
      Next
      If Val(Part) > 255 : ProcedureReturn #False : EndIf
    Next
    ProcedureReturn #True
  EndIf
  ProcedureReturn #False
EndProcedure

Procedure.i IsPrivateIPv4(IP.s)
  If CountString(IP, ".") <> 3 : ProcedureReturn #True : EndIf
  Protected P1.s = StringField(IP, 1, ".")
  Protected P2.s = StringField(IP, 2, ".")
  Protected P3.s = StringField(IP, 3, ".")
  Protected P4.s = StringField(IP, 4, ".")
  ; Refuser les zeros de tete (ambiguite octale : 0177.0.0.1).
  If (Len(P1) > 1 And Left(P1, 1) = "0") Or (Len(P2) > 1 And Left(P2, 1) = "0") Or (Len(P3) > 1 And Left(P3, 1) = "0") Or (Len(P4) > 1 And Left(P4, 1) = "0")
    ProcedureReturn #True
  EndIf
  Protected A.i = Val(P1)
  Protected B.i = Val(P2)
  Protected C.i = Val(P3)
  If A = 0 Or A = 10 Or A = 127 : ProcedureReturn #True : EndIf
  If A = 172 And B >= 16 And B <= 31 : ProcedureReturn #True : EndIf
  If A = 192 And B = 168 : ProcedureReturn #True : EndIf
  If A = 169 And B = 254 : ProcedureReturn #True : EndIf
  If A = 100 And B >= 64 And B <= 127 : ProcedureReturn #True : EndIf
  If A = 192 And B = 0 And (C = 0 Or C = 2) : ProcedureReturn #True : EndIf
  If A = 198 And (B = 18 Or B = 19) : ProcedureReturn #True : EndIf
  If A = 198 And B = 51 And C = 100 : ProcedureReturn #True : EndIf
  If A = 203 And B = 0 And C = 113 : ProcedureReturn #True : EndIf
  If A >= 224 : ProcedureReturn #True : EndIf
  ProcedureReturn #False
EndProcedure

Procedure.i IsPrivateIPv6(IP.s)
  IP = LCase(Trim(IP))
  If IP = "::" Or IP = "::1" : ProcedureReturn #True : EndIf
  If Left(IP, 2) = "fc" Or Left(IP, 2) = "fd" : ProcedureReturn #True : EndIf
  If Left(IP, 3) = "fe8" Or Left(IP, 3) = "fe9" Or Left(IP, 3) = "fea" Or Left(IP, 3) = "feb"
    ProcedureReturn #True
  EndIf
  If Left(IP, 2) = "ff" : ProcedureReturn #True : EndIf
  If Left(IP, 7) = "2001:db" : ProcedureReturn #True : EndIf
  If Left(IP, 7) = "64:ff9b" : ProcedureReturn #True : EndIf
  If Left(IP, 7) = "::ffff:" : ProcedureReturn #True : EndIf
  ProcedureReturn #False
EndProcedure

Procedure.i IsPrivateIP(IP.s)
  If FindString(IP, ":") > 0 : ProcedureReturn IsPrivateIPv6(IP) : EndIf
  ProcedureReturn IsPrivateIPv4(IP)
EndProcedure

Procedure.i IsIPLiteral(Host.s)
  If FindString(Host, ":") > 0 : ProcedureReturn #True : EndIf
  ProcedureReturn LooksLikeIP(Host)
EndProcedure

Procedure.i IsPrivateHost(Host.s)
  Host = LCase(Trim(Host))
  If Host = "localhost" : ProcedureReturn #True : EndIf
  If IsIPLiteral(Host) : ProcedureReturn IsPrivateIP(Host) : EndIf
  ProcedureReturn #False
EndProcedure

Procedure.s RunCapture(Program.s, CmdArgs.s)
  Protected Prog.i = RunProgram(Program, CmdArgs, "", #PB_Program_Open | #PB_Program_Read | #PB_Program_Hide)
  If Prog = 0 : ProcedureReturn "" : EndIf
  Protected Out.s = ""
  Protected Deadline.i = ElapsedMilliseconds() + 5000
  While (ProgramRunning(Prog) Or AvailableProgramOutput(Prog)) And ElapsedMilliseconds() < Deadline
    If AvailableProgramOutput(Prog)
      Out + ReadProgramString(Prog, #PB_UTF8) + #LF$
    Else
      Delay(5)
    EndIf
  Wend
  If ProgramRunning(Prog) : KillProgram(Prog) : EndIf
  CloseProgram(Prog)
  ProcedureReturn Out
EndProcedure

; Resout le hostname et collecte les IP. Retourne #False si aucune IP.
Procedure.i ResolveHost(Host.s, List IPs.s())
  If IsIPLiteral(Host)
    AddElement(IPs())
    IPs() = Host
    ProcedureReturn #True
  EndIf

  Protected Out.s = "", Line.s, Tok.s, i.i, j.i
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Out = RunCapture("nslookup", Host)
    ; Parser independant de la langue : ignorer l'en-tete (serveur DNS)
    ; et ne collecter les IP qu'a partir de la ligne contenant le hostname.
    Protected SeenHost.i = #False
    Protected LCount.i = CountString(Out, #LF$) + 1
    For i = 1 To LCount
      Line = ReplaceString(StringField(Out, i, #LF$), #CR$, "")
      If FindString(LCase(Line), LCase(Host)) > 0 : SeenHost = #True : EndIf
      If SeenHost
        For j = 1 To CountString(Line, " ") + 1
          Tok = Trim(StringField(Line, j, " "))
          If LooksLikeIP(Tok) : AddElement(IPs()) : IPs() = Tok : EndIf
        Next
      EndIf
    Next
  CompilerElse
    CompilerIf #PB_Compiler_OS = #PB_OS_Linux
      Out = RunCapture("getent", "hosts " + Host)
      Protected LCount2.i = CountString(Out, #LF$) + 1
      For i = 1 To LCount2
        Line = ReplaceString(StringField(Out, i, #LF$), #TAB$, " ")
        Line = Trim(ReplaceString(Line, #CR$, ""))
        Tok = Trim(StringField(Line, 1, " "))
        If LooksLikeIP(Tok) : AddElement(IPs()) : IPs() = Tok : EndIf
      Next
    CompilerElse
      Out = RunCapture("dscacheutil", "-q host -a name " + Host)
      Protected LCount3.i = CountString(Out, #LF$) + 1
      For i = 1 To LCount3
        Line = ReplaceString(StringField(Out, i, #LF$), #CR$, "")
        If FindString(LCase(Line), "ip_address:") > 0
          Tok = Trim(Mid(Line, FindString(Line, ":") + 1))
          If LooksLikeIP(Tok) : AddElement(IPs()) : IPs() = Tok : EndIf
        EndIf
      Next
    CompilerEndIf
  CompilerEndIf

  ProcedureReturn Bool(ListSize(IPs()) > 0)
EndProcedure

Procedure.i HostResolvesToPrivate(Host.s)
  NewList IPs.s()
  ; Fail closed : si la resolution echoue, on refuse.
  If Not ResolveHost(Host, IPs()) : ProcedureReturn #True : EndIf
  If ListSize(IPs()) = 0 : ProcedureReturn #True : EndIf
  ForEach IPs()
    If IsPrivateIP(IPs()) : ProcedureReturn #True : EndIf
  Next
  ProcedureReturn #False
EndProcedure

Procedure.i IsValidHost(Host.s)
  If Host = "" Or Len(Host) > 253 : ProcedureReturn #False : EndIf
  Protected i.i, c.i
  For i = 1 To Len(Host)
    c = Asc(Mid(Host, i, 1))
    If Not ((c >= 48 And c <= 57) Or (c >= 65 And c <= 90) Or (c >= 97 And c <= 122) Or c = 45 Or c = 46 Or c = 58)
      ProcedureReturn #False
    EndIf
  Next
  ProcedureReturn #True
EndProcedure

Procedure.s ValidateFetchUrl(Url.s)
  Url = Trim(Url)
  If Url = "" : ProcedureReturn "" : EndIf
  Protected Scheme.s = LCase(GetURLPart(Url, #PB_URL_Protocol))
  If Scheme <> "http" And Scheme <> "https"
    ProcedureReturn ""
  EndIf
  Protected Host.s = GetURLPart(Url, #PB_URL_Site)
  If Left(Host, 1) = "[" And Right(Host, 1) = "]"
    Host = Mid(Host, 2, Len(Host) - 2)
  EndIf
  If Host = "" Or Not IsValidHost(Host) Or IsPrivateHost(Host)
    ProcedureReturn ""
  EndIf
  ; Pour un hostname, resoudre et refuser toute IP privee (anti-SSRF).
  If Not IsIPLiteral(Host)
    If HostResolvesToPrivate(Host)
      ProcedureReturn ""
    EndIf
  EndIf
  ProcedureReturn Url
EndProcedure

; ---------------------------------------------------------------------------
; Recuperation HTTP en memoire
; ---------------------------------------------------------------------------
Procedure.s HttpGetMemory(Url.s, *OutStatus.Integer)
  ; Plafond de 2 Mio : evite qu'un serveur distant epuise la memoire.
  ProcedureReturn HttpGetLimited(Url, "", 15, #FETCH_MAX_BYTES, *OutStatus)
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
  If Status = -3
    ProcedureReturn "ERREUR: reponse trop volumineuse (max " + Str(#FETCH_MAX_BYTES / 1024 / 1024) + " Mo)."
  EndIf
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
