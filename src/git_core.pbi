; ============================================================================
;  git_core.pbi - Coeur metier du serveur MCP Git (depots locaux)
;  Inclus par src/gitMCP.pb et tests/test_git.pb.
; ============================================================================
;  Toutes les commandes passent par GitRun() qui execute git en sous-
;  processus avec repertoire de travail controle. Les parametres issus de
;  l'appel (chemins, refs) sont valides par GitSafeParam() : tout caractere
;  dangereux (; & | < > ` $ ( ) % " ' retours ligne) provoque le rejet de
;  la requete AVANT execution.
; ============================================================================

Global G_GitExe.s = "git"

Structure GitResult
  ExitCode.i
  Output.s
  ErrText.s
EndStructure

#GIT_MAX_OUTPUT = 40000

; ---------------------------------------------------------------------------
; Validation et citation
; ---------------------------------------------------------------------------

; Parametre autorise ? (anti-injection : rejette les metacaracteres shell)
; Le % est interdit : cmd.exe developpe les variables d'environnement
; (%APPDATA%...) meme entre guillemets, et une valeur expandue peut
; transporter des metacaracteres absents de la saisie. ^ et ! restent
; autorises : inertes entre guillemets (le delayed expansion de cmd est
; desactive en cmd /c).
Procedure.i GitSafeParam(S.s)
  If S = "" : ProcedureReturn #True : EndIf   ; vide = parametre optionnel absent
  If FindString(S, ";") > 0 Or FindString(S, "&") > 0 Or FindString(S, "|") > 0
    ProcedureReturn #False
  EndIf
  If FindString(S, "<") > 0 Or FindString(S, ">") > 0 Or FindString(S, "`") > 0
    ProcedureReturn #False
  EndIf
  If FindString(S, "$") > 0 Or FindString(S, "%") > 0 Or FindString(S, "(") > 0 Or FindString(S, ")") > 0
    ProcedureReturn #False
  EndIf
  If FindString(S, Chr(34)) > 0 Or FindString(S, "'") > 0
    ProcedureReturn #False
  EndIf
  If FindString(S, #LF$) > 0 Or FindString(S, #CR$) > 0
    ProcedureReturn #False
  EndIf
  ProcedureReturn #True
EndProcedure

; Entoure de guillemets doubles — GitSafeParam a deja garanti l'absence de
; guillemet dans la valeur (valable sous cmd.exe comme sous sh).
Procedure.s GitQuote(S.s)
  ProcedureReturn Chr(34) + S + Chr(34)
EndProcedure

; ---------------------------------------------------------------------------
; Execution git
; ---------------------------------------------------------------------------

; Verifie que git est disponible (appele au demarrage du serveur).
Procedure.i GitCheckAvailable()
  Protected Prog.i = RunProgram(G_GitExe, "--version", "", #PB_Program_Open | #PB_Program_Read | #PB_Program_Hide)
  If Prog = 0 : ProcedureReturn #False : EndIf
  Protected Out.s = ""
  Repeat
    If AvailableProgramOutput(Prog)
      Out + ReadProgramString(Prog, #PB_UTF8) + #LF$
    Else
      Delay(5)
    EndIf
  Until ProgramRunning(Prog) = 0 And AvailableProgramOutput(Prog) = 0
  WaitProgram(Prog)
  CloseProgram(Prog)
  ProcedureReturn Bool(FindString(LCase(Out), "git version") > 0)
EndProcedure

; Execute git Args dans le repertoire RepoPath ("" = repertoire courant).
; La commande passe par le shell avec "2>&1" : stderr est capture avec
; stdout (l'API Process de PureBasic ne permet pas de lire stderr de facon
; fiable). Les parametres utilisateur sont deja valides par GitSafeParam
; (aucun metacaractere shell possible).
Procedure.i GitRun(RepoPath.s, GitArgs.s, *R.GitResult)
  *R\ExitCode = -1
  *R\Output = ""
  *R\ErrText = ""

  ; Sans ce garde-fou, un chemin inexistant ferait executer git dans le
  ; repertoire courant (RunProgram ignore un working dir invalide).
  If RepoPath <> "" And FileSize(RepoPath) <> -2
    *R\ExitCode = 1
    *R\ErrText = "Erreur : repertoire introuvable : " + RepoPath
    ProcedureReturn 1
  EndIf

  Protected Cmd.s = Chr(34) + G_GitExe + Chr(34) + " " + GitArgs
  Protected Prog.i
  Protected Script.s = ""
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; cmd.exe exige la forme /c "<commande>" quand la commande commence par
    ; un chemin entre guillemets (idiome documente de cmd).
    Prog = RunProgram("cmd.exe", "/c " + Chr(34) + Cmd + " 2>&1" + Chr(34), RepoPath, #PB_Program_Open | #PB_Program_Read | #PB_Program_Hide)
  CompilerElse
    ; RunProgram ne gere pas les guillemets dans les arguments sous Linux :
    ; on passe par un script sh temporaire (stderr fusionne).
    Script = GetTemporaryDirectory() + "mcp_git_" + Str(Date()) + "_" + Str(Random(999999)) + ".sh"
    Protected F.i = CreateFile(#PB_Any, Script)
    If F
      WriteString(F, Cmd + " 2>&1" + #LF$, #PB_UTF8)
      CloseFile(F)
    EndIf
    Prog = RunProgram("/bin/sh", Script, RepoPath, #PB_Program_Open | #PB_Program_Read | #PB_Program_Hide)
  CompilerEndIf
  If Prog = 0
    *R\ErrText = "Impossible de lancer git (" + G_GitExe + ")."
    ProcedureReturn -1
  EndIf

  ; Lecture jusqu'a la fin du processus (AvailableProgramOutput peut etre
  ; faux tant que le fils n'a rien ecrit : boucle avec petite attente).
  Repeat
    If AvailableProgramOutput(Prog)
      *R\Output + ReadProgramString(Prog, #PB_UTF8) + #LF$
      If Len(*R\Output) > #GIT_MAX_OUTPUT
        *R\Output = Left(*R\Output, #GIT_MAX_OUTPUT) + #LF$ + "[... sortie tronquee ...]"
        Break
      EndIf
    Else
      Delay(5)
    EndIf
  Until ProgramRunning(Prog) = 0 And AvailableProgramOutput(Prog) = 0
  WaitProgram(Prog)
  *R\ExitCode = ProgramExitCode(Prog)
  CloseProgram(Prog)
  If Script <> "" : DeleteFile(Script) : EndIf
  ProcedureReturn *R\ExitCode
EndProcedure

; Retire espaces et fins de ligne en fin de sortie git.
Procedure.s TrimOut(S.s)
  S = Trim(S)
  While S <> "" And (Right(S, 1) = #LF$ Or Right(S, 1) = #CR$)
    S = Left(S, Len(S) - 1)
  Wend
  ProcedureReturn S
EndProcedure

; Helper : message d'erreur standardise quand git echoue (stderr est deja
; fusionne dans Output).
Procedure.s GitFailText(*R.GitResult, Action.s)
  Protected Msg.s = "Erreur : " + Action + " (code " + Str(*R\ExitCode) + ")."
  If Trim(*R\Output) <> ""
    Msg + #LF$ + Trim(*R\Output)
  ElseIf Trim(*R\ErrText) <> ""
    Msg + #LF$ + Trim(*R\ErrText)
  EndIf
  ProcedureReturn Msg
EndProcedure

; ---------------------------------------------------------------------------
; Outils MCP
; ---------------------------------------------------------------------------

; repoPath (optionnel) valide ; retourne "" si OK sinon message d'erreur pret
; a renvoyer. Utilise GitSafeParam.
Procedure.s GitCheckRepoParam(RepoPath.s)
  If Not GitSafeParam(RepoPath)
    LogError("repoPath refuse (caracteres dangereux) : " + Left(RepoPath, 80))
    ProcedureReturn "Erreur : repoPath contient des caracteres interdits (; & | < > ` $ ( ) ' retours ligne)."
  EndIf
  ProcedureReturn ""
EndProcedure

; git_is_repo
Procedure.s ToolGitIsRepo(RepoPath.s)
  Protected Bad.s = GitCheckRepoParam(RepoPath)
  If Bad <> "" : ProcedureReturn Bad : EndIf
  Protected Result.GitResult
  GitRun(RepoPath, "rev-parse --is-inside-work-tree", @Result)
  If Result\ExitCode = 0 And FindString(Trim(Result\Output), "true") > 0
    ProcedureReturn "true"
  EndIf
  ProcedureReturn "false"
EndProcedure

; git_status (format porcelain)
Procedure.s ToolGitStatus(RepoPath.s)
  Protected Bad.s = GitCheckRepoParam(RepoPath)
  If Bad <> "" : ProcedureReturn Bad : EndIf
  Protected Result.GitResult
  GitRun(RepoPath, "status --porcelain", @Result)
  If Result\ExitCode <> 0
    ProcedureReturn GitFailText(@Result, "git status a echoue")
  EndIf
  If Trim(Result\Output) = ""
    ProcedureReturn "Working tree clean (aucune modification)."
  EndIf
  ProcedureReturn TrimOut(Result\Output)
EndProcedure

; git_log (count limite et borne 1..1000)
Procedure.s ToolGitLog(RepoPath.s, Count.i)
  Protected Bad.s = GitCheckRepoParam(RepoPath)
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Count <= 0 : Count = 10 : EndIf
  If Count > 1000 : Count = 1000 : EndIf
  Protected Result.GitResult
  GitRun(RepoPath, "log --oneline -n " + Str(Count), @Result)
  If Result\ExitCode <> 0
    ProcedureReturn GitFailText(@Result, "git log a echoue")
  EndIf
  ProcedureReturn TrimOut(Result\Output)
EndProcedure

; git_diff (refs A et B, chemin optionnel)
Procedure.s ToolGitDiff(RepoPath.s, RefA.s, RefB.s, Path.s)
  Protected Bad.s = GitCheckRepoParam(RepoPath)
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GitSafeParam(RefA) Or Not GitSafeParam(RefB) Or Not GitSafeParam(Path)
    ProcedureReturn "Erreur : refA/refB/path contiennent des caracteres interdits."
  EndIf
  If RefA = "" Or RefB = ""
    ProcedureReturn "Erreur : refA et refB sont requis."
  EndIf
  Protected DiffArgs.s = "diff " + GitQuote(RefA) + " " + GitQuote(RefB)
  If Path <> ""
    DiffArgs + " -- " + GitQuote(Path)
  EndIf
  Protected Result.GitResult
  GitRun(RepoPath, DiffArgs, @Result)
  If Result\ExitCode <> 0
    ProcedureReturn GitFailText(@Result, "git diff a echoue (ref inexistante ?)")
  EndIf
  If Trim(Result\Output) = ""
    ProcedureReturn "(pas de difference)"
  EndIf
  ProcedureReturn TrimOut(Result\Output)
EndProcedure

; git_show (contenu d'un fichier a une ref : "ref:path")
Procedure.s ToolGitShow(RepoPath.s, Ref.s, Path.s)
  Protected Bad.s = GitCheckRepoParam(RepoPath)
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GitSafeParam(Ref) Or Not GitSafeParam(Path)
    ProcedureReturn "Erreur : ref/path contiennent des caracteres interdits."
  EndIf
  If Ref = "" Or Path = ""
    ProcedureReturn "Erreur : ref et path sont requis."
  EndIf
  Protected Result.GitResult
  GitRun(RepoPath, "show " + GitQuote(Ref + ":" + Path), @Result)
  If Result\ExitCode <> 0
    ProcedureReturn GitFailText(@Result, "git show a echoue (ref ou fichier inexistant ?)")
  EndIf
  ProcedureReturn TrimOut(Result\Output)
EndProcedure

; git_branches (locales, ou remotes avec remote=true)
Procedure.s ToolGitBranches(RepoPath.s, Remote.i)
  Protected Bad.s = GitCheckRepoParam(RepoPath)
  If Bad <> "" : ProcedureReturn Bad : EndIf
  Protected Result.GitResult
  If Remote
    GitRun(RepoPath, "branch -r", @Result)
  Else
    GitRun(RepoPath, "branch", @Result)
  EndIf
  If Result\ExitCode <> 0
    ProcedureReturn GitFailText(@Result, "git branch a echoue")
  EndIf
  ; Nettoyer le marqueur "* " de la branche courante
  Protected Lines.s = Trim(Result\Output), Out.s = "", i.i
  Protected n.i = CountString(Lines, #LF$) + 1
  For i = 1 To n
    Protected L.s = Trim(StringField(Lines, i, #LF$))
    If Left(L, 2) = "* " : L = Mid(L, 3) : EndIf
    If L <> "" : Out + L + #LF$ : EndIf
  Next
  ProcedureReturn TrimOut(Out)
EndProcedure

; git_blame (plage de lignes 1..100000)
Procedure.s ToolGitBlame(RepoPath.s, Path.s, StartLine.i, EndLine.i)
  Protected Bad.s = GitCheckRepoParam(RepoPath)
  If Bad <> "" : ProcedureReturn Bad : EndIf
  If Not GitSafeParam(Path)
    ProcedureReturn "Erreur : path contient des caracteres interdits."
  EndIf
  If Path = ""
    ProcedureReturn "Erreur : path est requis."
  EndIf
  If StartLine < 1 : StartLine = 1 : EndIf
  If EndLine < StartLine : EndLine = StartLine + 49 : EndIf
  If EndLine > 100000 : EndLine = 100000 : EndIf
  Protected Result.GitResult
  GitRun(RepoPath, "blame -L " + Str(StartLine) + "," + Str(EndLine) + " -- " + GitQuote(Path), @Result)
  If Result\ExitCode <> 0
    ProcedureReturn GitFailText(@Result, "git blame a echoue (fichier ou lignes invalides ?)")
  EndIf
  ProcedureReturn TrimOut(Result\Output)
EndProcedure

; ---------------------------------------------------------------------------
; Catalogue MCP
; ---------------------------------------------------------------------------
Procedure.i GitBuildCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "git_is_repo", "Verifie qu'un repertoire est un depot git.", "repoPath|string|Repertoire a tester (defaut: repertoire courant)", "")
  ToolDef(ToolsArr, "git_status", "Etat du working tree (format porcelain : XY chemin).", "repoPath|string|Depot (defaut: courant)", "")
  ToolDef(ToolsArr, "git_log", "Historique des commits (oneline, derniers N).", "repoPath|string|Depot;count|integer|Nombre de commits (defaut: 10, max: 1000)", "")
  ToolDef(ToolsArr, "git_diff", "Differences entre deux refs (ou une ref et le working tree via refB vide interdit : utilisez HEAD).", "repoPath|string|Depot;refA|string|Ref de depart (ex. HEAD~1);refB|string|Ref d'arrivee (ex. HEAD);path|string|Filtre de chemin (optionnel)", "refA;refB")
  ToolDef(ToolsArr, "git_show", "Contenu d'un fichier a une ref donnee.", "repoPath|string|Depot;ref|string|Ref (ex. HEAD, v1.0.0, branche);path|string|Chemin du fichier dans le depot", "ref;path")
  ToolDef(ToolsArr, "git_branches", "Liste des branches (locales ou distantes).", "repoPath|string|Depot;remote|boolean|Branches distantes (defaut: false)", "")
  ToolDef(ToolsArr, "git_blame", "Annotations de lignes (auteur, commit) pour un fichier.", "repoPath|string|Depot;path|string|Fichier;startLine|integer|Ligne de depart (defaut: 1);endLine|integer|Ligne de fin (defaut: startLine+49)", "path")

  ProcedureReturn RootJSON
EndProcedure

; ---------------------------------------------------------------------------
; Dispatch des outils (hook *G_ToolHandler)
; ---------------------------------------------------------------------------
Procedure.s GitDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Protected RepoPath.s = GetArgString(ArgsObj, "repoPath")
  Select ToolName
    Case "git_is_repo"
      ProcedureReturn ToolGitIsRepo(RepoPath)
    Case "git_status"
      ProcedureReturn ToolGitStatus(RepoPath)
    Case "git_log"
      ProcedureReturn ToolGitLog(RepoPath, GetArgInt(ArgsObj, "count", 10))
    Case "git_diff"
      ProcedureReturn ToolGitDiff(RepoPath, GetArgString(ArgsObj, "refA"), GetArgString(ArgsObj, "refB"), GetArgString(ArgsObj, "path"))
    Case "git_show"
      ProcedureReturn ToolGitShow(RepoPath, GetArgString(ArgsObj, "ref"), GetArgString(ArgsObj, "path"))
    Case "git_branches"
      ProcedureReturn ToolGitBranches(RepoPath, GetArgBool(ArgsObj, "remote", 0))
    Case "git_blame"
      ProcedureReturn ToolGitBlame(RepoPath, GetArgString(ArgsObj, "path"), GetArgInt(ArgsObj, "startLine", 1), GetArgInt(ArgsObj, "endLine", 0))
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure
