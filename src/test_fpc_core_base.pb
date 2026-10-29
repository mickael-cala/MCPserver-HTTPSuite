; ============================================================================
; test_fpc_core_base.pb - Tests table cibles, resolveur et validation FPC
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

Global Root.s = GetTemporaryDirectory() + "mcp_fpc_base_" + Str(Date()) + "_" + Str(Random(1000000))
CreateDirectory(Root)
FpcConfigure(Root, "fpc", 60000)
FpcInitTargets()

; PARANO PB : toute comparaison passee en argument doit etre enveloppee dans Bool().
Check(Bool(FpcTargetIndex("win32") = 0), "win32 present")
Check(Bool(FpcTargetIndex("WIN64") = 1), "win64 insensible a la casse")
Check(Bool(FpcTargetIndex("linux32") = 2), "linux32 present")
Check(Bool(FpcTargetIndex("linux64") = 3), "linux64 present")
Check(Bool(FpcTargetIndex("linux-aarch64") = 4), "linux-aarch64 present")
Check(Bool(FpcTargetIndex("macos-aarch64") = 5), "macos-aarch64 present")
Check(Bool(FpcTargetIndex("amiga-mos") = -1), "cible inconnue refusee")

Global Origin.i = 0
Global Compiler.s = FpcResolveCompiler(1, @Origin)
Check(Bool(Compiler = "fpc"), "compilateur general par defaut")
Check(Bool(Origin = 2), "origine configuration generale signalee")

SetEnvironmentVariable("MCP_FPC_WIN64", "C:\Tools\fpc-win64.exe")
Compiler = FpcResolveCompiler(1, @Origin)
Check(Bool(Compiler = "C:\Tools\fpc-win64.exe"), "variable dediee prioritaire")
Check(Bool(Origin = 1), "origine variable dediee signalee")
RemoveEnvironmentVariable("MCP_FPC_WIN64")

G_FpcCompilerDefault = "C:\Tools\fpc-custom.exe"
Compiler = FpcResolveCompiler(1, @Origin)
Check(Bool(Compiler = "C:\Tools\fpc-custom.exe"), "MCP_FPC general prioritaire sur PATH")
Check(Bool(Origin = 2), "origine MCP_FPC generale signalee")
G_FpcCompilerDefault = "fpc"

Check(FpcValidateOutputName("hello"), "nom simple accepte")
Check(FpcValidateOutputName("hello-1.2_x"), "nom avec tirets point underscore accepte")
Check(Bool(Not FpcValidateOutputName("")), "nom vide refuse")
Check(Bool(Not FpcValidateOutputName(".hidden")), "nom initial point refuse")
Check(Bool(Not FpcValidateOutputName("bad..name")), "double point refuse")
Check(Bool(Not FpcValidateOutputName("bad name")), "espace refuse")
Check(Bool(Not FpcValidateOutputName("bad/name")), "slash refuse")
Check(Bool(Not FpcValidateOutputName("bad\name")), "backslash refuse")
Check(Bool(Not FpcValidateOutputName("bad:name")), "deux-points refuse")

Global Source.s = Root + FSSeparator() + "hello world.pas"
Global F.i = CreateFile(#PB_Any, Source)
WriteString(F, "program hello;" + #LF$ + "begin end." + #LF$, #PB_UTF8)
CloseFile(F)

Global Safe.s = ""
Check(Bool(FpcValidateSource("hello world.pas") = ""), "source relative acceptee")
Safe = G_FpcSafeSource
Check(Bool(Safe = Source), "source normalisee absolue")
Check(Bool(FpcValidateSource(".."+FSSeparator()+"escape.pas") <> ""), "source hors racine refusee")
Check(Bool(FpcValidateSource("missing.pas") <> ""), "source absente refusee")

Check(FpcPrepareBuildDirs(3), "repertoires linux64 crees")
Check(Bool(FileSize(G_FpcExeDir) = -2), "repertoire executable cree")
Check(Bool(FileSize(G_FpcUnitDir) = -2), "repertoire unites cree")

DeleteDirectory(Root, "", #PB_FileSystem_Recursive)

SendStderrLine("---")
SendStderrLine("test_fpc_core_base : " + Str(G_Passed) + " reussis, " + Str(G_Failed) + " echoues")
If G_Failed > 0
  End 1
EndIf
