; ============================================================================
;  test_git.pb - Tests unitaires du serveur Git (Phase 4)
;  T4.1 - T4.18 : fixturation d'un depot reel dans un repertoire temporaire
;  (3 commits, 2 branches, fichier modifie, chemin avec espaces).
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../src/git_core.pbi"
IncludeFile "unit_test.pbi"

Global G_Repo.s

Procedure.s Sep()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ProcedureReturn "\\"
  CompilerElse
    ProcedureReturn "/"
  CompilerEndIf
EndProcedure

; Execute une commande de fixturation dans le depot (via GitRun)
Procedure.i Fix(Cmd.s)
  Protected Res.GitResult
  GitRun(G_Repo, Cmd, @Res)
  ProcedureReturn Res\ExitCode
EndProcedure

Procedure.i WriteTestFile(Name.s, Content.s)
  Protected F.i = CreateFile(#PB_Any, G_Repo + Sep() + Name)
  If F = 0 : ProcedureReturn #False : EndIf
  WriteString(F, Content, #PB_UTF8)
  CloseFile(F)
  ProcedureReturn #True
EndProcedure

; Sert a verifier qu'une injection n'a pas eu d'effet de bord
Procedure.i MarkerFileExists()
  ProcedureReturn Bool(FileSize(G_Repo + Sep() + "pwned.txt") >= 0)
EndProcedure

; ===========================================================================
; Fixture : main (3 commits) + branche feature
; ===========================================================================
Procedure.i BuildFixture()
  G_Repo = GetTemporaryDirectory() + "mcp_git_unittest_" + Str(Date()) + "_" + Str(Random(100000))
  CreateDirectory(G_Repo)
  If FileSize(G_Repo) <> -2 : ProcedureReturn #False : EndIf

  If Fix("init -q -b main") <> 0 : ProcedureReturn #False : EndIf
  Fix("config user.email test@example.com")
  Fix("config user.name Tester")
  Fix("config core.quotepath false")

  WriteTestFile("README.md", "ligne 1" + #LF$ + "ligne 2" + #LF$ + "ligne 3" + #LF$ + "ligne 4" + #LF$ + "ligne 5" + #LF$)
  Fix("add README.md")
  Fix("commit -q -m premier-commit")

  WriteTestFile("README.md", "ligne 1" + #LF$ + "ligne 2 modifiee" + #LF$ + "ligne 3" + #LF$ + "ligne 4" + #LF$ + "ligne 5" + #LF$)
  Fix("add README.md")
  Fix("commit -q -m deuxieme-commit")

  WriteTestFile("app.pb", "EnableExplicit" + #LF$)
  Fix("add app.pb")
  Fix("commit -q -m troisieme-commit")

  ; Branche feature avec un commit (les commits suivants restent sur main)
  Fix("checkout -q -b feature")
  WriteTestFile("feature.txt", "contenu feature" + #LF$)
  Fix("add feature.txt")
  Fix("commit -q -m commit-feature")
  Fix("checkout -q main")

  ; Fichier avec espaces (T4.16)
  WriteTestFile("fichier espaces.txt", "a" + #LF$ + "b" + #LF$ + "c" + #LF$ + "d" + #LF$ + "e" + #LF$)
  Fix("add " + Chr(34) + "fichier espaces.txt" + Chr(34))
  Fix("commit -q -m quatrieme-commit")

  ProcedureReturn #True
EndProcedure

; ===========================================================================
; T4.1 - T4.4 : is_repo / status
; ===========================================================================
Procedure Test_IsRepoAndStatus()
  SendStderrLine("--- T4.1-T4.4 is_repo / status ---")

  UTAssertStr("true", ToolGitIsRepo(G_Repo), "T4.1 depot reconnu")
  UTAssertStr("false", ToolGitIsRepo(GetTemporaryDirectory()), "T4.2 pas un depot -> false")

  Protected Out.s = ToolGitStatus(G_Repo)
  UTAssertContains(Out, "Working tree clean", "T4.3 working tree propre")

  WriteTestFile("README.md", "modifie non indexe" + #LF$)
  Out = ToolGitStatus(G_Repo)
  UTAssertContains(Out, "README.md", "T4.4 fichier modifie liste")
  Fix("checkout -- README.md")   ; restaurer
EndProcedure

; ===========================================================================
; T4.5 - T4.8 : log / diff
; ===========================================================================
Procedure Test_LogAndDiff()
  SendStderrLine("--- T4.5-T4.8 log / diff ---")

  Protected Out.s = ToolGitLog(G_Repo, 2)
  UTAssert(2, CountString(Trim(Out), #LF$) + 1, "T4.5 log count=2 -> 2 lignes")

  Out = ToolGitLog(G_Repo, 100)
  UTAssert(4, CountString(Trim(Out), #LF$) + 1, "T4.6 log count=100 -> 4 commits (toutes branches exclues)")

  Out = ToolGitDiff(G_Repo, "HEAD~1", "HEAD", "")
  UTAssert(1, Bool(FindString(Out, "modifie") > 0 Or FindString(Out, "diff") > 0), "T4.7 diff HEAD~1..HEAD non vide")

  Out = ToolGitDiff(G_Repo, "ref-inexistante", "HEAD", "")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T4.8 ref inexistante -> erreur claire")
EndProcedure

; ===========================================================================
; T4.9 - T4.10 : show
; ===========================================================================
Procedure Test_Show()
  SendStderrLine("--- T4.9-T4.10 show ---")

  Protected Out.s = ToolGitShow(G_Repo, "HEAD", "README.md")
  UTAssert(1, Bool(FindString(Out, "ligne 1") > 0), "T4.9 show HEAD:README.md")
  UTAssert(0, Bool(Left(Out, 6) = "Erreur"), "T4.9 pas d'erreur")

  Out = ToolGitShow(G_Repo, "HEAD", "nexiste-pas.txt")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T4.10 fichier inexistant -> erreur")
EndProcedure

; ===========================================================================
; T4.11 - T4.13 : branches / blame
; ===========================================================================
Procedure Test_BranchesAndBlame()
  SendStderrLine("--- T4.11-T4.13 branches / blame ---")

  Protected Out.s = ToolGitBranches(G_Repo, #False)
  UTAssertContains(Out, "main", "T4.11 branche main listee")
  UTAssertContains(Out, "feature", "T4.11 branche feature listee")
  UTAssert(0, Bool(FindString(Out, "* ") > 0), "T4.11 pas de marqueur * dans la sortie")

  Out = ToolGitBranches(G_Repo, #True)
  UTAssertStr("", Out, "T4.12 aucune branche distante")

  Out = ToolGitBlame(G_Repo, "README.md", 1, 5)
  UTAssert(5, CountString(Trim(Out), #LF$) + 1, "T4.13 blame lignes 1-5 -> 5 lignes")
EndProcedure

; ===========================================================================
; T4.14 - T4.18 : securite et cas limites
; ===========================================================================
Procedure Test_SecurityAndLimits()
  SendStderrLine("--- T4.14-T4.18 securite ---")

  ; T4.14 : injection via ref
  Protected Out.s = ToolGitDiff(G_Repo, "HEAD; touch pwned.txt", "HEAD", "")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T4.14 ref injectee rejetee")
  UTAssert(0, MarkerFileExists(), "T4.14 aucune commande executee")

  ; T4.14bis : injection via path
  Out = ToolGitBlame(G_Repo, "README.md; touch pwned.txt", 1, 2)
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T4.14 path injecte rejete")

  ; T4.15 : repoPath hostile
  Out = ToolGitLog("C:\; calc.exe", 1)
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T4.15 repoPath hostile rejete")

  ; T4.16 : chemin avec espaces
  Out = ToolGitShow(G_Repo, "HEAD", "fichier espaces.txt")
  UTAssert(1, Bool(FindString(Out, "e") > 0 And Left(Out, 6) <> "Erreur"), "T4.16 chemin avec espaces OK")

  ; T4.17 : depot inexistant
  Out = ToolGitLog(G_Repo + "_nexiste_pas", 2)
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T4.17 depot inexistant -> erreur")

  ; T4.18 : git absent (executable bidon)
  Protected SavedExe.s = G_GitExe
  G_GitExe = "git_executable_inexistant_xyz"
  UTAssert(0, GitCheckAvailable(), "T4.18 git absent -> indisponible")
  Protected Res.GitResult
  GitRun(G_Repo, "status", @Res)
  UTAssert(1, Bool(Res\ExitCode <> 0), "T4.18 GitRun echoue proprement sans git")
  G_GitExe = SavedExe
EndProcedure

; ===========================================================================
; Programme principal
; ===========================================================================
If Not CheckRuntime()
  End 1
EndIf

If Not GitCheckAvailable()
  SendStderrLine("[ERREUR] git introuvable dans le PATH")
  End 2
EndIf

If Not BuildFixture()
  SendStderrLine("[ERREUR] construction de la fixture impossible")
  End 2
EndIf

Test_IsRepoAndStatus()
Test_LogAndDiff()
Test_Show()
Test_BranchesAndBlame()
Test_SecurityAndLimits()

; Nettoyage
Fix("checkout -q main")
DeleteDirectory(G_Repo, "", #PB_FileSystem_Recursive)

UTFinalize()

End
