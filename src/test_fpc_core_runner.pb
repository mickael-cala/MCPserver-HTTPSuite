; ============================================================================
; test_fpc_core_runner.pb - Tests capture stdout/stderr et borne de flux
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "fs_guard.pbi"
IncludeFile "fpc_core.pbi"

Global G_Passed.i = 0
Global G_Failed.i = 0

Procedure Check(Cond.i, Name.s)
  If Cond
    G_Passed + 1
    SendStderrLine("[OK]   " + Name)
  Else
    G_Failed + 1
    SendStderrLine("[FAIL] " + Name)
  EndIf
EndProcedure

If Not CheckRuntime()
  End 1
EndIf

; Borne de flux : on accumule dans un champ de structure FpcResult.
; PARANO PB : toute comparaison passee en argument doit etre enveloppee dans Bool().
Global R0.FpcResult
Global Big.s = ""
Global i.i
For i = 1 To 7000
  Big + "AAAAAAAAAA"
Next
FpcAppendLimited(@R0, Big, #False)
Check(Bool(Len(R0\StdOut) <= #FPC_STREAM_LIMIT + 64), "sortie bornee")
Check(Bool(FindString(R0\StdOut, "[... tronque ...]") > 0), "marqueur de tronquage present")

Global Root.s = GetTemporaryDirectory() + "mcp_fpc_runner_" + Str(Date()) + "_" + Str(Random(1000000))
CreateDirectory(Root)
FpcConfigure(Root, "fpc", 60000)
FpcInitTargets()

Global R.FpcResult

CompilerIf #PB_Compiler_OS = #PB_OS_Windows
  Global Fake.s = Root + "\fake-fpc.bat"
  Global F.i = CreateFile(#PB_Any, Fake)
  WriteString(F, "@echo off" + #CRLF$)
  WriteString(F, "echo FAKE-STDOUT" + #CRLF$)
  WriteString(F, "echo FAKE-STDERR 1>&2" + #CRLF$)
  WriteString(F, "exit /b 7" + #CRLF$)
  CloseFile(F)
  Check(Bool(FpcRunProgram("cmd.exe", "/c " + Chr(34) + Fake + Chr(34), "", 3000, @R) = 7), "fake compiler code 7")
CompilerElse
  Global Fake.s = Root + "/fake-fpc.sh"
  Global F.i = CreateFile(#PB_Any, Fake)
  WriteString(F, "#!/bin/sh" + #LF$)
  WriteString(F, "echo FAKE-STDOUT" + #LF$)
  WriteString(F, "echo FAKE-STDERR 1>&2" + #LF$)
  WriteString(F, "exit 7" + #LF$)
  CloseFile(F)
  Global OldCwd.s = GetCurrentDirectory()
  SetCurrentDirectory(Root)
  Check(Bool(FpcRunProgram("/bin/sh", "fake-fpc.sh", "", 3000, @R) = 7), "fake compiler code 7")
  SetCurrentDirectory(OldCwd)
CompilerEndIf

Check(Bool(R\TimedOut = #False), "pas de timeout")
Check(Bool(FindString(R\StdOut, "FAKE-STDOUT") > 0), "stdout capture")
Check(Bool(FindString(R\StdErr, "FAKE-STDERR") > 0), "stderr capture separee")
Check(Bool(R\ExitCode = 7), "ProgramExitCode conserve")

Global Targets.s = ToolFpcTargets()
Check(Bool(FindString(Targets, "win32") > 0), "targets contient win32")
Check(Bool(FindString(Targets, "macos-aarch64") > 0), "targets contient macos-aarch64")
Check(Bool(FindString(Targets, "MCP_FPC") > 0), "targets indique l'origine generale")

DeleteDirectory(Root, "", #PB_FileSystem_Recursive)

SendStderrLine("---")
SendStderrLine("test_fpc_core_runner : " + Str(G_Passed) + " reussis, " + Str(G_Failed) + " echoues")
If G_Failed > 0
  End 1
EndIf
