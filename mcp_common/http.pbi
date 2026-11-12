; ============================================================================
;  http.pbi - Couche HTTP GET/POST avec en-tetes (Windows : WinHTTP)
;  Partagee par les serveurs qui appellent des API web authentifiees.
; ============================================================================
;  Windows  : WinHTTP (winhttp.dll) -> en-tetes personnalises, HTTPS/HTTP.
;  Linux/macOS : curl (config file) -> en-tetes supportees ; Status = -1
;                si curl est absent.
;
;  A inclure apres runtime.pbi (SendStderrLine) :
;    IncludeFile "../mcp_common/runtime.pbi"
;    IncludeFile "../mcp_common/logging.pbi"
;    IncludeFile "../mcp_common/http.pbi"
;
;  En-tetes : chaine "Nom: valeur" separees par CRLF, ex.
;    "Authorization: Bearer xxx" + #CRLF$ + "Accept: application/json"
; ============================================================================

; Limite optionnelle de la taille de reponse (0 = illimitee).
; Utilisee par HttpGetLimited() ; le serveur est mono-thread.
Global G_HttpMaxResponseBytes.i = 0

; En-tetes de reponse de la derniere requete (bruts, ligne de statut
; incluse). Les redirections automatiques sont desactivees dans les deux
; transports : MCP-Fetch-PB les suit a la main et revalide chaque saut
; (anti-SSRF) ; voir G_HttpResponseHeaders dans HttpWinRequest/HttpCurl.
Global G_HttpResponseHeaders.s = ""

; I3 — anti DNS rebinding (fixes par MCP-Fetch-PB autour de chaque requete,
; videes apres ; serveur mono-thread) :
;   - chemin curl : G_HttpConnectToHost/Ip epinglent la connexion sur l'IP
;     validee (connect-to), court-circuitant la resolution DNS de curl ;
;   - chemin WinHTTP : G_HttpVerifyRemoteIp declenche la verification de
;     l'IP reellement connectee apres la reponse (WINHTTP_OPTION_CONNECTION_INFO)
;     — une IP privee jette la reponse (-5) au lieu de la retourner.
Global G_HttpConnectToHost.s = ""
Global G_HttpConnectToIp.s = ""
Global G_HttpVerifyRemoteIp.i = #False

; ---------------------------------------------------------------------------
; Encodage URL d'un composant de requete (alphanum + -._~ conserves)
; ---------------------------------------------------------------------------
Procedure.s UrlEncodeComponent(S.s)
  Protected i.i, c.i, Out.s = "", Hex.s
  For i = 1 To Len(S)
    c = Asc(Mid(S, i, 1))
    If (c >= 48 And c <= 57) Or (c >= 65 And c <= 90) Or (c >= 97 And c <= 122) Or c = 45 Or c = 46 Or c = 95 Or c = 126
      Out + Chr(c)
    Else
      Hex = Hex(c)
      If Len(Hex) < 2 : Hex = "0" + Hex : EndIf
      Out + "%" + Hex
    EndIf
  Next
  ProcedureReturn Out
EndProcedure

CompilerIf #PB_Compiler_OS = #PB_OS_Windows

#WINHTTP_FLAG_SECURE = $00800000
#WINHTTP_QUERY_STATUS_CODE = 19
#WINHTTP_QUERY_FLAG_NUMBER = $20000000
#WINHTTP_QUERY_RAW_HEADERS_CRLF = 22
; Redirections automatiques desactivees : suivies a la main par le serveur
; fetch avec re-validation de chaque saut (anti-SSRF).
#WINHTTP_OPTION_DISABLE_FEATURE = 82
#WINHTTP_DISABLE_REDIRECTS = 1
; IP distante reellement connectee (anti DNS rebinding, I3).
#WINHTTP_OPTION_CONNECTION_INFO = 93

PrototypeC whttpOpen(lpszAgent.s, dwAccessType.i, lpszProxyName.i, lpszProxyBypass.i, dwFlags.i)
PrototypeC whttpConnect(hSession.i, pswzServerName.s, nServerPort.i, dwReserved.i)
PrototypeC whttpOpenRequest(hConnect.i, pwszVerb.s, pwszObjectName.s, pwszVersion.i, pwszReferrer.i, plpszAcceptTypes.i, dwFlagsAndAttributes.i)
PrototypeC whttpAddRequestHeaders(hRequest.i, pwszHeaders.s, dwHeadersLength.i, dwModifiers.i)
PrototypeC whttpSendRequest(hRequest.i, pwszHeaders.i, dwHeadersLength.i, lpOptional.i, dwOptionalLength.i, dwTotalLength.i, dwContext.i)
PrototypeC whttpReceiveResponse(hRequest.i, lpReserved.i)
PrototypeC whttpQueryHeaders(hRequest.i, dwInfoLevel.i, pwszName.i, lpBuffer.i, lpdwBufferLength.i, lpdwIndex.i)
PrototypeC whttpQueryDataAvailable(hRequest.i, lpdwNumberOfBytesAvailable.i)
PrototypeC whttpReadData(hRequest.i, lpBuffer.i, dwNumberOfBytesToRead.i, lpdwNumberOfBytesRead.i)
PrototypeC whttpCloseHandle(hInternet.i)
PrototypeC whttpSetTimeouts(hInternet.i, dwResolveTimeout.i, dwConnectTimeout.i, dwSendTimeout.i, dwReceiveTimeout.i)
PrototypeC whttpSetOption(hInternet.i, dwOption.i, lpBuffer.i, dwBufferLength.i)
PrototypeC whttpQueryOption(hInternet.i, dwOption.i, lpBuffer.i, lpdwBufferLength.i)

Global hWinHTTP.i = 0
Global whttp_WinHttpOpen.whttpOpen
Global whttp_WinHttpConnect.whttpConnect
Global whttp_WinHttpOpenRequest.whttpOpenRequest
Global whttp_WinHttpAddRequestHeaders.whttpAddRequestHeaders
Global whttp_WinHttpSendRequest.whttpSendRequest
Global whttp_WinHttpReceiveResponse.whttpReceiveResponse
Global whttp_WinHttpQueryHeaders.whttpQueryHeaders
Global whttp_WinHttpQueryDataAvailable.whttpQueryDataAvailable
Global whttp_WinHttpReadData.whttpReadData
Global whttp_WinHttpCloseHandle.whttpCloseHandle
Global whttp_WinHttpSetTimeouts.whttpSetTimeouts
Global whttp_WinHttpSetOption.whttpSetOption
Global whttp_WinHttpQueryOption.whttpQueryOption

Procedure.i HttpInit()
  If hWinHTTP : ProcedureReturn #True : EndIf
  hWinHTTP = OpenLibrary(#PB_Any, "winhttp.dll")
  If hWinHTTP = 0 : ProcedureReturn #False : EndIf
  whttp_WinHttpOpen              = GetFunction(hWinHTTP, "WinHttpOpen")
  whttp_WinHttpConnect           = GetFunction(hWinHTTP, "WinHttpConnect")
  whttp_WinHttpOpenRequest       = GetFunction(hWinHTTP, "WinHttpOpenRequest")
  whttp_WinHttpAddRequestHeaders = GetFunction(hWinHTTP, "WinHttpAddRequestHeaders")
  whttp_WinHttpSendRequest       = GetFunction(hWinHTTP, "WinHttpSendRequest")
  whttp_WinHttpReceiveResponse   = GetFunction(hWinHTTP, "WinHttpReceiveResponse")
  whttp_WinHttpQueryHeaders      = GetFunction(hWinHTTP, "WinHttpQueryHeaders")
  whttp_WinHttpQueryDataAvailable= GetFunction(hWinHTTP, "WinHttpQueryDataAvailable")
  whttp_WinHttpReadData          = GetFunction(hWinHTTP, "WinHttpReadData")
  whttp_WinHttpCloseHandle       = GetFunction(hWinHTTP, "WinHttpCloseHandle")
  whttp_WinHttpSetTimeouts       = GetFunction(hWinHTTP, "WinHttpSetTimeouts")
  whttp_WinHttpSetOption         = GetFunction(hWinHTTP, "WinHttpSetOption")
  whttp_WinHttpQueryOption       = GetFunction(hWinHTTP, "WinHttpQueryOption")
  If whttp_WinHttpOpen = 0 Or whttp_WinHttpSendRequest = 0 Or whttp_WinHttpReadData = 0
    ProcedureReturn #False
  EndIf
  ProcedureReturn #True
EndProcedure

; Requete HTTP generique (Windows/WinHTTP).
; Method.s = "GET" ou "POST" ; Body.s utilise pour POST.
; Adresse IPv4 privee/loopback (octets bruts) ? Meme politique que
; IsPrivateIPv4 de MCP-Fetch-PB.pb (a maintenir ensemble).
Procedure.i HttpIPv4Private(a.i, b.i, c.i, d.i)
  If a = 0 Or a = 10 Or a = 127 : ProcedureReturn #True : EndIf
  If a = 172 And b >= 16 And b <= 31 : ProcedureReturn #True : EndIf
  If a = 192 And b = 168 : ProcedureReturn #True : EndIf
  If a = 169 And b = 254 : ProcedureReturn #True : EndIf
  If a = 100 And b >= 64 And b <= 127 : ProcedureReturn #True : EndIf
  If a = 192 And b = 0 And (c = 0 Or c = 2) : ProcedureReturn #True : EndIf
  If a = 198 And (b = 18 Or b = 19) : ProcedureReturn #True : EndIf
  If a = 198 And b = 51 And c = 100 : ProcedureReturn #True : EndIf
  If a = 203 And b = 0 And c = 113 : ProcedureReturn #True : EndIf
  If a >= 224 : ProcedureReturn #True : EndIf
  ProcedureReturn #False
EndProcedure

; SOCKADDR_STORAGE privee/loopback ? Verification sur octets bruts : la
; conversion en chaine perdrait les prefixes compreses (::1, 2001:db8).
Procedure.i HttpSockaddrPrivate(*SS)
  Protected Fam.i = PeekW(*SS)
  If Fam = 2   ; AF_INET : famille(2), port(2), adresse(4) a l'offset 4
    ProcedureReturn HttpIPv4Private(PeekB(*SS + 4) & $FF, PeekB(*SS + 5) & $FF, PeekB(*SS + 6) & $FF, PeekB(*SS + 7) & $FF)
  EndIf
  If Fam = 23  ; AF_INET6 : adresse 16 octets a l'offset 8
    Protected b0.i = PeekB(*SS + 8) & $FF, b1.i = PeekB(*SS + 9) & $FF
    Protected b2.i = PeekB(*SS + 10) & $FF, b3.i = PeekB(*SS + 11) & $FF
    Protected i.i, AllZero.i = #True
    For i = 0 To 14
      If PeekB(*SS + 8 + i) <> 0 : AllZero = #False : Break : EndIf
    Next
    ; :: et ::1 (non specifiee/boucle locale)
    If AllZero : ProcedureReturn #True : EndIf
    If b0 = $FC Or b0 = $FD : ProcedureReturn #True : EndIf      ; ULA fc00::/7
    If b0 = $FE And b1 >= $80 And b1 <= $BF : ProcedureReturn #True : EndIf  ; link-local
    If b0 = $FF : ProcedureReturn #True : EndIf                  ; multicast
    If b0 = $20 And b1 = $01 And b2 = $0D And b3 = $B8 : ProcedureReturn #True : EndIf  ; doc 2001:db8
    If b0 = $00 And b1 = $64 And b2 = $FF And b3 = $9B : ProcedureReturn #True : EndIf  ; NAT64 64:ff9b
    ; ::ffff:x.y.z.w (IPv4-mapped) : b0..b9 nuls, b10 = b11 = $FF
    Protected Mapped.i = #True
    For i = 0 To 9
      If PeekB(*SS + 8 + i) <> 0 : Mapped = #False : Break : EndIf
    Next
    If Mapped And PeekB(*SS + 18) = $FF And PeekB(*SS + 19) = $FF
      ; regles IPv4 sur les 4 derniers octets
      ProcedureReturn HttpIPv4Private(PeekB(*SS + 20) & $FF, PeekB(*SS + 21) & $FF, PeekB(*SS + 22) & $FF, PeekB(*SS + 23) & $FF)
    EndIf
    ProcedureReturn #False
  EndIf
  ; Famille inconnue : fail-closed.
  ProcedureReturn #True
EndProcedure

; Requete HTTP generique (Windows/WinHTTP).
; Method.s = "GET" ou "POST" ; Body.s utilise pour POST.
Procedure.s HttpWinRequest(Url.s, Method.s, Headers.s, Body.s, TimeoutSec.i, *Status.Integer)
  *Status\i = -1
  If Not HttpInit() : ProcedureReturn "" : EndIf

  Protected Server.s = GetURLPart(Url, #PB_URL_Site)
  If Server = "" : ProcedureReturn "" : EndIf
  Protected IsHttps.i = Bool(LCase(Left(Url, 6)) = "https:")
  Protected Port.i = Val(GetURLPart(Url, #PB_URL_Port))
  If Port = 0
    If IsHttps : Port = 443 : Else : Port = 80 : EndIf
  EndIf
  Protected Path.s = GetURLPart(Url, #PB_URL_Path)
  Protected Params.s = GetURLPart(Url, #PB_URL_Parameters)
  If Params <> "" : Path + "?" + Params : EndIf
  If Path = "" : Path = "/" : EndIf

  Protected Flags.i = 0
  If IsHttps : Flags = #WINHTTP_FLAG_SECURE : EndIf

  Protected hSession.i = whttp_WinHttpOpen("MCP-PureBasic/1.0", 0, 0, 0, 0)
  If hSession = 0 : ProcedureReturn "" : EndIf
  If whttp_WinHttpSetTimeouts
    whttp_WinHttpSetTimeouts(hSession, TimeoutSec * 1000, TimeoutSec * 1000, TimeoutSec * 1000, TimeoutSec * 1000)
  EndIf
  Protected hConnect.i = whttp_WinHttpConnect(hSession, Server, Port, 0)
  If hConnect = 0 : whttp_WinHttpCloseHandle(hSession) : ProcedureReturn "" : EndIf
  Protected hRequest.i = whttp_WinHttpOpenRequest(hConnect, Method, Path, 0, 0, 0, Flags)
  If hRequest = 0
    whttp_WinHttpCloseHandle(hConnect) : whttp_WinHttpCloseHandle(hSession)
    ProcedureReturn ""
  EndIf

  ; Redirections automatiques desactivees : un 302 vers une IP privee ne
  ; doit JAMAIS etre suivi sans re-validation (anti-SSRF). Le serveur fetch
  ; suit les redirections a la main, en revalidant chaque cible.
  G_HttpResponseHeaders = ""
  If whttp_WinHttpSetOption
    Protected NoRedirect.i = #WINHTTP_DISABLE_REDIRECTS
    whttp_WinHttpSetOption(hRequest, #WINHTTP_OPTION_DISABLE_FEATURE, @NoRedirect, 4)
  EndIf

  If Headers <> ""
    If whttp_WinHttpAddRequestHeaders(hRequest, Headers, -1, 0) = 0
      LogError("WinHttpAddRequestHeaders a echoue")
    EndIf
  EndIf

  Protected BodySize.i = StringByteLength(Body, #PB_UTF8)
  Protected *BodyMem = 0
  If Method = "POST" And BodySize > 0
    *BodyMem = AllocateMemory(BodySize)
    If *BodyMem = 0
      whttp_WinHttpCloseHandle(hRequest) : whttp_WinHttpCloseHandle(hConnect) : whttp_WinHttpCloseHandle(hSession)
      ProcedureReturn ""
    EndIf
    PokeS(*BodyMem, Body, -1, #PB_UTF8 | #PB_String_NoZero)
  EndIf

  Protected SendOK.i
  If Method = "POST"
    SendOK = whttp_WinHttpSendRequest(hRequest, 0, 0, *BodyMem, BodySize, BodySize, 0)
  Else
    SendOK = whttp_WinHttpSendRequest(hRequest, 0, 0, 0, 0, 0, 0)
  EndIf
  If *BodyMem : FreeMemory(*BodyMem) : EndIf
  If SendOK = 0
    whttp_WinHttpCloseHandle(hRequest) : whttp_WinHttpCloseHandle(hConnect) : whttp_WinHttpCloseHandle(hSession)
    ProcedureReturn ""
  EndIf
  If whttp_WinHttpReceiveResponse(hRequest, 0) = 0
    whttp_WinHttpCloseHandle(hRequest) : whttp_WinHttpCloseHandle(hConnect) : whttp_WinHttpCloseHandle(hSession)
    ProcedureReturn ""
  EndIf

  Protected Code.i = 0, CodeLen.i = 4
  If whttp_WinHttpQueryHeaders(hRequest, #WINHTTP_QUERY_STATUS_CODE | #WINHTTP_QUERY_FLAG_NUMBER, 0, @Code, @CodeLen, 0)
    *Status\i = Code
  EndIf

  ; Capture des en-tetes de reponse (lignes CRLF, ligne de statut incluse)
  ; pour le suivi manuel des redirections. Si la lecture echoue (en-tetes
  ; > 16 Kio), G_HttpResponseHeaders reste vide : un 3xx sans Location
  ; lisible ne sera pas suivi (fail-closed).
  Protected HdrLen.i = 16384
  Protected *Hdr = AllocateMemory(HdrLen)
  If *Hdr
    If whttp_WinHttpQueryHeaders(hRequest, #WINHTTP_QUERY_RAW_HEADERS_CRLF, 0, *Hdr, @HdrLen, 0)
      G_HttpResponseHeaders = PeekS(*Hdr, HdrLen, #PB_Unicode | #PB_ByteLength)
    EndIf
    FreeMemory(*Hdr)
  EndIf

  ; I3 — anti DNS rebinding : la resolution DNS de la validation et celle
  ; de WinHttpConnect sont deux operations distinctes (TOCTOU). Si demande,
  ; verifier l'IP reellement connectee : une IP privee jette la reponse
  ; (-5) au lieu de la retourner. Si la requete d'information echoue, on
  ; continue (fail-open) : le controle initial a deja valide le hostname.
  If G_HttpVerifyRemoteIp And whttp_WinHttpQueryOption
    Protected *Conn = AllocateMemory(512)
    If *Conn
      PokeL(*Conn, 264)   ; WINHTTP_CONNECTION_INFO.cbSize
      Protected ConnLen.i = 512
      If whttp_WinHttpQueryOption(hRequest, #WINHTTP_OPTION_CONNECTION_INFO, *Conn, @ConnLen)
        If HttpSockaddrPrivate(*Conn + 136)   ; RemoteAddress
          *Status\i = -5
          FreeMemory(*Conn)
          whttp_WinHttpCloseHandle(hRequest) : whttp_WinHttpCloseHandle(hConnect) : whttp_WinHttpCloseHandle(hSession)
          ProcedureReturn ""
        EndIf
      EndIf
      FreeMemory(*Conn)
    EndIf
  EndIf

  Protected *Buf = AllocateMemory(65536)
  Protected RespBody.s = "", Avail.i = 0, ReadLow.i = 0, TotalRead.i = 0
  If *Buf
    While whttp_WinHttpQueryDataAvailable(hRequest, @Avail)
      If Avail <= 0 : Break : EndIf
      If Avail > 65536 : Avail = 65536 : EndIf
      ReadLow = 0
      If whttp_WinHttpReadData(hRequest, *Buf, Avail, @ReadLow) = 0 Or ReadLow <= 0
        Break
      EndIf
      If G_HttpMaxResponseBytes > 0 And TotalRead + ReadLow > G_HttpMaxResponseBytes
        *Status\i = -4   ; reponse trop volumineuse (-3 reste reserve aux pre-checks appelants)
        Break
      EndIf
      TotalRead + ReadLow
      RespBody + PeekS(*Buf, ReadLow, #PB_UTF8 | #PB_ByteLength)
    Wend
    FreeMemory(*Buf)
  EndIf

  If *Status\i = -3 : RespBody = "" : EndIf

  whttp_WinHttpCloseHandle(hRequest)
  whttp_WinHttpCloseHandle(hConnect)
  whttp_WinHttpCloseHandle(hSession)
  ProcedureReturn RespBody
EndProcedure

Procedure.s HttpGetHeaders(Url.s, Headers.s, TimeoutSec.i, *Status.Integer)
  ProcedureReturn HttpWinRequest(Url, "GET", Headers, "", TimeoutSec, *Status)
EndProcedure

Procedure.s HttpPostHeaders(Url.s, Headers.s, Body.s, TimeoutSec.i, *Status.Integer)
  ProcedureReturn HttpWinRequest(Url, "POST", Headers, Body, TimeoutSec, *Status)
EndProcedure

CompilerElse

; ---------------------------------------------------------------------------
; Fallback Linux/macOS : curl (config file -> pas de probleme de quoting)
; ---------------------------------------------------------------------------

; Les fichiers temporaires de cette couche contiennent des secrets
; (Authorization...) : crees avec umask 077 (0600) pour ne pas etre
; lisibles par les autres comptes locaux d'un hot multi-utilisateur.
ImportC ""
  http_umask(Mode.i) As "umask"
EndImport

#HTTP_TEMP_UMASK = $077

Procedure.s CurlEsc(S.s)
  ; LF/CR neutralises : ils couperaient la ligne du fichier de config et
  ; permettraient d'injecter des directives curl arbitraires (contourner
  ; max-time, ajouter des options).
  S = ReplaceString(S, #CRLF$, " ")
  S = ReplaceString(S, #LF$, " ")
  S = ReplaceString(S, #CR$, " ")
  S = ReplaceString(S, Chr(92), Chr(92) + Chr(92))
  S = ReplaceString(S, Chr(34), Chr(92) + Chr(34))
  ProcedureReturn S
EndProcedure

Procedure.s HttpCurl(Url.s, Method.s, Headers.s, Body.s, TimeoutSec.i, *Status.Integer)
  *Status\i = -1
  G_HttpResponseHeaders = ""

  ; Nom de base unique : verifier qu'aucun fichier ne preexiste (symlink
  ; preplante sur un nom predit). L'umask reste actif pendant la creation
  ; de la config ET pendant l'execution de curl (qui cree la sortie et le
  ; dump d'en-tetes) ; restaure apres.
  Protected OldMask.i = http_umask(#HTTP_TEMP_UMASK)
  Protected Base.s = ""
  Protected Tries.i
  For Tries = 1 To 5
    Base = GetTemporaryDirectory() + "mcp_http_" + Str(Date()) + "_" + Str(Random(999999))
    If FileSize(Base + ".cfg") = -1 And FileSize(Base + ".out") = -1
      Break
    EndIf
    Base = ""
    Delay(2)
  Next
  If Base = ""
    http_umask(OldMask)
    ProcedureReturn ""
  EndIf
  Protected CfgFile.s = Base + ".cfg"
  Protected OutFile.s = Base + ".out"
  Protected BodyFile.s = Base + ".body"
  Protected HdrFile.s = Base + ".hdr"

  Protected F.i = CreateFile(#PB_Any, CfgFile)
  If F = 0 : ProcedureReturn "" : EndIf
  WriteString(F, "silent" + #LF$, #PB_UTF8)
  WriteString(F, "show-error" + #LF$, #PB_UTF8)
  WriteString(F, "max-time = " + Str(TimeoutSec) + #LF$, #PB_UTF8)
  If G_HttpMaxResponseBytes > 0
    WriteString(F, "max-filesize = " + Str(G_HttpMaxResponseBytes) + #LF$, #PB_UTF8)
  EndIf
  WriteString(F, "request = " + #DQUOTE$ + Method + #DQUOTE$ + #LF$, #PB_UTF8)
  WriteString(F, "url = " + #DQUOTE$ + CurlEsc(Url) + #DQUOTE$ + #LF$, #PB_UTF8)
  ; I3 — anti DNS rebinding : IP validee epinglee si fournie. curl ne
  ; consulte plus le DNS pour ce host ; SNI et en-tete Host restent ceux
  ; du hostname d'origine (certificats et serveurs virtuels preserves).
  If G_HttpConnectToHost <> "" And G_HttpConnectToIp <> ""
    Protected PinPort.i = 80
    If LCase(Left(Url, 8)) = "https://" : PinPort = 443 : EndIf
    WriteString(F, "connect-to = " + #DQUOTE$ + CurlEsc(G_HttpConnectToHost) + "::" + CurlEsc(G_HttpConnectToIp) + ":" + Str(PinPort) + #DQUOTE$ + #LF$, #PB_UTF8)
  EndIf
  WriteString(F, "output = " + #DQUOTE$ + CurlEsc(OutFile) + #DQUOTE$ + #LF$, #PB_UTF8)
  WriteString(F, "write-out = " + #DQUOTE$ + "%{http_code}" + #DQUOTE$ + #LF$, #PB_UTF8)
  ; En-tetes de reponse captures pour le suivi manuel des redirections
  ; (MCP-Fetch-PB revalide chaque cible 3xx avant la requete suivante).
  WriteString(F, "dump-header = " + #DQUOTE$ + CurlEsc(HdrFile) + #DQUOTE$ + #LF$, #PB_UTF8)

  ; En-tetes (separees par CRLF dans le parametre Headers)
  If Headers <> ""
    Protected HCount.i = CountString(Headers, #CRLF$) + 1, Hi.i, HLine.s
    For Hi = 1 To HCount
      HLine = Trim(StringField(Headers, Hi, #CRLF$))
      If HLine <> ""
        WriteString(F, "header = " + #DQUOTE$ + CurlEsc(HLine) + #DQUOTE$ + #LF$, #PB_UTF8)
      EndIf
    Next
  EndIf

  If Method = "POST" And Body <> ""
    Protected BF.i = CreateFile(#PB_Any, BodyFile)
    If BF
      WriteString(BF, Body, #PB_UTF8)
      CloseFile(BF)
    EndIf
    WriteString(F, "data-binary = " + #DQUOTE$ + "@" + CurlEsc(BodyFile) + #DQUOTE$ + #LF$, #PB_UTF8)
  EndIf
  CloseFile(F)

  Protected Prog.i = RunProgram("curl", "-K " + CfgFile, "", #PB_Program_Open | #PB_Program_Read | #PB_Program_Hide)
  If Prog = 0
    DeleteFile(CfgFile)
    ProcedureReturn ""
  EndIf
  Protected Out.s = ""
  Repeat
    If AvailableProgramOutput(Prog)
      Out + ReadProgramString(Prog, #PB_UTF8)
    Else
      Delay(5)
    EndIf
  Until ProgramRunning(Prog) = 0 And AvailableProgramOutput(Prog) = 0
  WaitProgram(Prog)
  Protected ExitCode.i = ProgramExitCode(Prog)
  CloseProgram(Prog)
  http_umask(OldMask)   ; tous les fichiers temporaires sont crees a ce stade

  ; En-tetes de reponse (pour le suivi manuel des redirections) ; absent
  ; si curl a echoue avant la reponse -> G_HttpResponseHeaders reste vide.
  Protected H.i = ReadFile(#PB_Any, HdrFile)
  If H
    G_HttpResponseHeaders = ReadString(H, #PB_UTF8, Lof(H))
    CloseFile(H)
  EndIf

  Protected Result.s = ""
  If ExitCode = 0
    *Status\i = Val(Trim(Out))
    Protected R.i = ReadFile(#PB_Any, OutFile)
    If R
      Result = ReadString(R, #PB_UTF8, Lof(R))
      CloseFile(R)
    EndIf
    If *Status\i = 0 : *Status\i = 200 : EndIf   ; write-out vide : succes
  EndIf

  If ExitCode = 63
    *Status\i = -4   ; reponse trop volumineuse
    Result = ""
  EndIf

  DeleteFile(CfgFile)
  DeleteFile(OutFile)
  DeleteFile(HdrFile)
  If Method = "POST" And Body <> "" : DeleteFile(BodyFile) : EndIf
  ProcedureReturn Result
EndProcedure

Procedure.s HttpGetHeaders(Url.s, Headers.s, TimeoutSec.i, *Status.Integer)
  ProcedureReturn HttpCurl(Url, "GET", Headers, "", TimeoutSec, *Status)
EndProcedure

Procedure.s HttpPostHeaders(Url.s, Headers.s, Body.s, TimeoutSec.i, *Status.Integer)
  ProcedureReturn HttpCurl(Url, "POST", Headers, Body, TimeoutSec, *Status)
EndProcedure

CompilerEndIf

; ---------------------------------------------------------------------------
; GET avec limite de taille de reponse (MaxBytes <= 0 : illimite)
; ---------------------------------------------------------------------------
Procedure.s HttpGetLimited(Url.s, Headers.s, TimeoutSec.i, MaxBytes.i, *Status.Integer)
  G_HttpMaxResponseBytes = MaxBytes
  Protected Res.s = HttpGetHeaders(Url, Headers, TimeoutSec, *Status)
  G_HttpMaxResponseBytes = 0
  ProcedureReturn Res
EndProcedure

Procedure.s HttpPostLimited(Url.s, Headers.s, Body.s, TimeoutSec.i, MaxBytes.i, *Status.Integer)
  G_HttpMaxResponseBytes = MaxBytes
  Protected Res.s = HttpPostHeaders(Url, Headers, Body, TimeoutSec, *Status)
  G_HttpMaxResponseBytes = 0
  ProcedureReturn Res
EndProcedure

; ---------------------------------------------------------------------------
; Validation d'une base d'API configurable (MCP_GITHUB_API_BASE,
; MCP_CONTEXT7_API_BASE) : http/https uniquement (curl accepterait file://) ;
; avertissement explicite si un secret Authorization partirait en HTTP hors
; loopback. Retourne #False pour les schemas invalides (arret du serveur).
; ---------------------------------------------------------------------------
Procedure.i HttpCheckApiBase(Base.s)
  Protected U.s = LCase(Trim(Base))
  If Left(U, 8) = "https://"
    ProcedureReturn #True
  EndIf
  If Left(U, 7) = "http://"
    Protected Site.s = GetURLPart(Base, #PB_URL_Site)   ; hote[:port]
    Protected Bare.s = Site
    If Left(Site, 1) = "["
      Protected CloseB.i = FindString(Site, "]")
      If CloseB > 0 : Bare = Left(Site, CloseB - 1) : EndIf  ; [::1] -> ::1
    Else
      Protected Colon.i = FindString(Site, ":")
      If Colon > 0 : Bare = Left(Site, Colon - 1) : EndIf
    EndIf
    If Bare = "127.0.0.1" Or Bare = "localhost" Or Bare = "::1" Or Bare = "[::1]"
      ProcedureReturn #True   ; mock local / tests
    EndIf
    LogError("ATTENTION : " + Base + " est en HTTP hors loopback — le secret (Authorization) circulera en clair. Preferer HTTPS.")
    ProcedureReturn #True
  EndIf
  LogError("Base d'API invalide : " + Base + " (http:// ou https:// attendu).")
  ProcedureReturn #False
EndProcedure
