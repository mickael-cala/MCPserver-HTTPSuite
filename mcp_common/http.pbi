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
  If whttp_WinHttpOpen = 0 Or whttp_WinHttpSendRequest = 0 Or whttp_WinHttpReadData = 0
    ProcedureReturn #False
  EndIf
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

  Protected *Buf = AllocateMemory(65536)
  Protected RespBody.s = "", Avail.i = 0, ReadLow.i = 0
  If *Buf
    While whttp_WinHttpQueryDataAvailable(hRequest, @Avail)
      If Avail <= 0 : Break : EndIf
      If Avail > 65536 : Avail = 65536 : EndIf
      ReadLow = 0
      If whttp_WinHttpReadData(hRequest, *Buf, Avail, @ReadLow) = 0 Or ReadLow <= 0
        Break
      EndIf
      RespBody + PeekS(*Buf, ReadLow, #PB_UTF8 | #PB_ByteLength)
    Wend
    FreeMemory(*Buf)
  EndIf

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

Procedure.s CurlEsc(S.s)
  S = ReplaceString(S, Chr(92), Chr(92) + Chr(92))
  S = ReplaceString(S, Chr(34), Chr(92) + Chr(34))
  ProcedureReturn S
EndProcedure

Procedure.s HttpCurl(Url.s, Method.s, Headers.s, Body.s, TimeoutSec.i, *Status.Integer)
  *Status\i = -1
  Protected Base.s = GetTemporaryDirectory() + "mcp_http_" + Str(Date()) + "_" + Str(Random(999999))
  Protected CfgFile.s = Base + ".cfg"
  Protected OutFile.s = Base + ".out"
  Protected BodyFile.s = Base + ".body"

  Protected F.i = CreateFile(#PB_Any, CfgFile)
  If F = 0 : ProcedureReturn "" : EndIf
  WriteString(F, "silent" + #LF$, #PB_UTF8)
  WriteString(F, "show-error" + #LF$, #PB_UTF8)
  WriteString(F, "max-time = " + Str(TimeoutSec) + #LF$, #PB_UTF8)
  WriteString(F, "request = " + #DQUOTE$ + Method + #DQUOTE$ + #LF$, #PB_UTF8)
  WriteString(F, "url = " + #DQUOTE$ + CurlEsc(Url) + #DQUOTE$ + #LF$, #PB_UTF8)
  WriteString(F, "output = " + #DQUOTE$ + CurlEsc(OutFile) + #DQUOTE$ + #LF$, #PB_UTF8)
  WriteString(F, "write-out = " + #DQUOTE$ + "%{http_code}" + #DQUOTE$ + #LF$, #PB_UTF8)

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

  DeleteFile(CfgFile)
  DeleteFile(OutFile)
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
