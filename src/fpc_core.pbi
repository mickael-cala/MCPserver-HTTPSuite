; ============================================================================
; fpc_core.pbi - Coeur metier du serveur MCP Free Pascal
; ============================================================================
; INTENTION
; Exposer six cibles Free Pascal sans jamais laisser le client choisir une
; commande libre.
;
; CONTRAT
; Les procedures ToolFpc* retournent du texte destine au payload MCP. Les
; procedures Fpc* internes valident avant tout effet de bord.
;
; PARANO
; Le compilateur est un binaire de confiance choisi par configuration, pas un
; chemin envoye par le projet. Les chemins utilisateur passent par fs_guard.
; Les options sont issues d'une table interne et d'un fichier de reponse.
; ============================================================================

#FPC_STREAM_LIMIT = 65536
#FPC_TARGET_COUNT = 6

Structure FpcTarget
  Id.s
  Cpu.s
  Os.s
  Args.s
  EnvName.s
EndStructure

Structure FpcResult
  ExitCode.i
  TimedOut.i
  DurationMs.i
  StdOut.s
  StdErr.s
EndStructure

Global Dim FpcTargets.FpcTarget(5)
Global G_FpcTargetsReady.i = #False
Global G_FpcRoot.s = ""
Global G_FpcCompilerDefault.s = "fpc"
Global G_FpcTimeoutMs.i = 60000

; ---------------------------------------------------------------------------
; Variables de sortie (idempotence PureBasic)
; ---------------------------------------------------------------------------
; PARANO PB : un pointeur type *.String N'EST PAS une sortie fiable. L'affectation
; *Ptr\s = valeur copie dans le buffer existant sans le redimensionner (ecriture
; silencieusement perdue sur chaine vide) et peut meme planter. La convention
; du projet est donc : la procedure retourne un code/erreur et ecrit ses
; sorties chaines dans des globales G_Fpc* dediees, lues immediatement par
; l'appelant. Les pointeurs typés restent reserves aux entiers (*p.Integer),
; dont l'ecriture par *p\i est fiable et verifiee.
; ---------------------------------------------------------------------------
Global G_FpcSafeSource.s = ""
Global G_FpcExeDir.s = ""
Global G_FpcUnitDir.s = ""

Procedure FpcInitTargets()
  If G_FpcTargetsReady : ProcedureReturn : EndIf

  FpcTargets(0)\Id = "win32"
  FpcTargets(0)\Cpu = "i386"
  FpcTargets(0)\Os = "win32"
  FpcTargets(0)\Args = "-Pi386 -Twin32"
  FpcTargets(0)\EnvName = "MCP_FPC_WIN32"

  FpcTargets(1)\Id = "win64"
  FpcTargets(1)\Cpu = "x86_64"
  FpcTargets(1)\Os = "win64"
  FpcTargets(1)\Args = "-Px86_64 -Twin64"
  FpcTargets(1)\EnvName = "MCP_FPC_WIN64"

  FpcTargets(2)\Id = "linux32"
  FpcTargets(2)\Cpu = "i386"
  FpcTargets(2)\Os = "linux"
  FpcTargets(2)\Args = "-Pi386 -Tlinux"
  FpcTargets(2)\EnvName = "MCP_FPC_LINUX32"

  FpcTargets(3)\Id = "linux64"
  FpcTargets(3)\Cpu = "x86_64"
  FpcTargets(3)\Os = "linux"
  FpcTargets(3)\Args = "-Px86_64 -Tlinux"
  FpcTargets(3)\EnvName = "MCP_FPC_LINUX64"

  FpcTargets(4)\Id = "linux-aarch64"
  FpcTargets(4)\Cpu = "aarch64"
  FpcTargets(4)\Os = "linux"
  FpcTargets(4)\Args = "-Paarch64 -Tlinux"
  FpcTargets(4)\EnvName = "MCP_FPC_LINUX_AARCH64"

  FpcTargets(5)\Id = "macos-aarch64"
  FpcTargets(5)\Cpu = "aarch64"
  FpcTargets(5)\Os = "darwin"
  FpcTargets(5)\Args = "-Paarch64 -Tdarwin"
  FpcTargets(5)\EnvName = "MCP_FPC_MACOS_AARCH64"

  G_FpcTargetsReady = #True
EndProcedure

Procedure FpcConfigure(Root.s, DefaultCompiler.s, TimeoutMs.i)
  G_FpcRoot = Root
  ; Chaine vide = aucune configuration generale explicite. FpcResolveCompiler
  ; retournera alors "fpc" avec l'origine PATH, ce qui garde l'origine honnete.
  G_FpcCompilerDefault = Trim(DefaultCompiler)
  If TimeoutMs < 1000 : TimeoutMs = 1000 : EndIf
  If TimeoutMs > 300000 : TimeoutMs = 300000 : EndIf
  G_FpcTimeoutMs = TimeoutMs
  FpcInitTargets()
EndProcedure

Procedure.i FpcTargetIndex(TargetId.s)
  FpcInitTargets()
  TargetId = LCase(Trim(TargetId))
  Protected i.i
  For i = 0 To #FPC_TARGET_COUNT - 1
    If FpcTargets(i)\Id = TargetId
      ProcedureReturn i
    EndIf
  Next
  ProcedureReturn -1
EndProcedure

Procedure.s FpcResolveCompiler(TargetIndex.i, *Origin.Integer)
  ; Ordre volontairement explicite : configuration locale d'abord, PATH ensuite.
  ; Le projet compile ne peut pas designer son propre executable.
  If TargetIndex >= 0 And TargetIndex < #FPC_TARGET_COUNT
    Protected Dedicated.s = Trim(GetEnvironmentVariable(FpcTargets(TargetIndex)\EnvName))
    If Dedicated <> ""
      *Origin\i = 1
      ProcedureReturn Dedicated
    EndIf
  EndIf

  If Trim(G_FpcCompilerDefault) <> ""
    *Origin\i = 2
    ProcedureReturn Trim(G_FpcCompilerDefault)
  EndIf

  *Origin\i = 3
  ProcedureReturn "fpc"
EndProcedure

Procedure.i FpcValidateOutputName(Name.s)
  Name = Trim(Name)
  If Name = "" Or Len(Name) > 128 : ProcedureReturn #False : EndIf
  If Left(Name, 1) = "." : ProcedureReturn #False : EndIf
  If FindString(Name, "..") > 0 : ProcedureReturn #False : EndIf

  Protected i.i, c.i
  For i = 1 To Len(Name)
    c = Asc(Mid(Name, i, 1))
    ; Lettres, chiffres, point, tiret, underscore. Aucun chemin, aucun espace.
    If Not ((c >= 48 And c <= 57) Or (c >= 65 And c <= 90) Or (c >= 97 And c <= 122) Or c = 46 Or c = 45 Or c = 95)
      ProcedureReturn #False
    EndIf
  Next
  ProcedureReturn #True
EndProcedure

; Retour : "" = OK (le chemin normalise est alors dans G_FpcSafeSource),
; sinon message d'erreur detaille. Pas de pointeur sortie : voir note globale.
Procedure.s FpcValidateSource(SourcePath.s)
  Protected SafePath.s = FSValidatePath(SourcePath, G_FpcRoot)
  If SafePath = ""
    ProcedureReturn "Erreur : acces refuse en dehors de MCP_FPC_ROOT ou via un lien."
  EndIf
  If FileSize(SafePath) = -2
    ProcedureReturn "Erreur : source est un repertoire, pas un fichier Pascal."
  EndIf
  If FileSize(SafePath) < 0
    ProcedureReturn "Erreur : source introuvable : " + SourcePath
  EndIf

  Protected Ext.s = LCase(GetExtensionPart(SafePath))
  If Ext <> "pas" And Ext <> "pp" And Ext <> "lpr"
    ProcedureReturn "Erreur : extension autorisee : pas, pp ou lpr."
  EndIf

  G_FpcSafeSource = SafePath
  ProcedureReturn ""
EndProcedure

Procedure.i FpcCreateDirectories(Path.s)
  Protected Sep.s = FSSeparator()
  Path = ReplaceString(ReplaceString(Path, "/", Sep), "\", Sep)

  Protected i.i, Count.i = CountString(Path, Sep) + 1
  Protected SubPath.s = "", Part.s

  For i = 1 To Count
    Part = StringField(Path, i, Sep)
    If Part <> ""
      If SubPath = ""
        CompilerIf #PB_Compiler_OS = #PB_OS_Windows
          SubPath = Part
        CompilerElse
          SubPath = "/" + Part
        CompilerEndIf
      Else
        SubPath + Sep + Part
      EndIf
      If FileSize(SubPath) = -1
        CreateDirectory(SubPath)
      EndIf
    EndIf
  Next

  ProcedureReturn Bool(FileSize(Path) = -2)
EndProcedure

; Sorties : G_FpcExeDir et G_FpcUnitDir (voir note sur les pointeurs string).
Procedure.i FpcPrepareBuildDirs(TargetIndex.i)
  If TargetIndex < 0 Or TargetIndex >= #FPC_TARGET_COUNT
    ProcedureReturn #False
  EndIf

  Protected Sep.s = FSSeparator()
  Protected Base.s = FSEnsureTrailingSlash(G_FpcRoot) + "build" + Sep + FpcTargets(TargetIndex)\Id
  Protected ExePath.s = Base
  Protected UnitPath.s = Base + Sep + "units"

  If Not FpcCreateDirectories(UnitPath)
    ProcedureReturn #False
  EndIf

  G_FpcExeDir = ExePath
  G_FpcUnitDir = UnitPath
  ProcedureReturn #True
EndProcedure

; ---------------------------------------------------------------------------
; Runner borne : execution directe, sans shell
; ---------------------------------------------------------------------------

; Ajoute Addition au flux StdOut (ToErr = #False) ou StdErr (ToErr = #True)
; du resultat, en bornant la longueur totale a #FPC_STREAM_LIMIT octets
; (mesure en caracteres, borne conservative car un caractere UTF-8 fait au
; plus 4 octets cote reseau... ici on reste sur une borne simple et sure).
; PARANO PB : on ecrit dans un CHAMP de structure (*R\StdOut) via pointeur,
; operation verifiee fiable ; ecrire @VariableString\s serait perdu ou plante.
Procedure FpcAppendLimited(*R.FpcResult, Addition.s, ToErr.i)
  Protected Current.s
  If ToErr
    Current = *R\StdErr
  Else
    Current = *R\StdOut
  EndIf

  If Len(Current) >= #FPC_STREAM_LIMIT
    If Not FindString(Current, "[... tronque ...]")
      Current + "[... tronque ...]"
    EndIf
  Else
    Protected Room.i = #FPC_STREAM_LIMIT - Len(Current)
    If Len(Addition) > Room
      Addition = Left(Addition, Room)
    EndIf
    Current + Addition
    ; Marqueur unique, ajoute une seule fois, des la borne atteinte.
    If Len(Current) >= #FPC_STREAM_LIMIT And Not FindString(Current, "[... tronque ...]")
      Current + "[... tronque ...]"
    EndIf
  EndIf

  If ToErr
    *R\StdErr = Current
  Else
    *R\StdOut = Current
  EndIf
EndProcedure

Procedure.i FpcRunProgram(Program.s, Parameters.s, WorkingDirectory.s, TimeoutMs.i, *R.FpcResult)
  *R\ExitCode = -1
  *R\TimedOut = #False
  *R\DurationMs = 0
  *R\StdOut = ""
  *R\StdErr = ""

  If Trim(Program) = ""
    *R\StdErr = "Erreur : executable vide."
    ProcedureReturn -1
  EndIf
  If WorkingDirectory <> "" And FileSize(WorkingDirectory) <> -2
    *R\StdErr = "Erreur : repertoire de travail introuvable : " + WorkingDirectory
    ProcedureReturn -1
  EndIf
  If TimeoutMs < 1000 : TimeoutMs = 1000 : EndIf

  ; Aucun shell ici : RunProgram recoit un executable et une chaine d'arguments
  ; fixes. Le but est de reduire l'interpreteur disponible pour l'attaquant.
  Protected Prog.i = RunProgram(Program, Parameters, WorkingDirectory,
                                #PB_Program_Open | #PB_Program_Read |
                                #PB_Program_Error | #PB_Program_Hide)
  If Prog = 0
    *R\StdErr = "Erreur : impossible de lancer " + Program
    ProcedureReturn -1
  EndIf

  Protected StartMs.i = ElapsedMilliseconds()
  Protected Deadline.i = StartMs + TimeoutMs
  Protected ErrLine.s

  While ProgramRunning(Prog)
    If AvailableProgramOutput(Prog)
      FpcAppendLimited(*R, ReadProgramString(Prog, #PB_UTF8) + #LF$, #False)
    EndIf

    ; ReadProgramError est non bloquant : lire stderr empeche un processus
    ; verbeux de mourir sur un pipe plein.
    ErrLine = ReadProgramError(Prog, #PB_UTF8)
    If ErrLine <> ""
      FpcAppendLimited(*R, ErrLine + #LF$, #True)
    EndIf

    If ElapsedMilliseconds() > Deadline
      *R\TimedOut = #True
      KillProgram(Prog)
      Break
    EndIf
    Delay(5)
  Wend

  While AvailableProgramOutput(Prog)
    FpcAppendLimited(*R, ReadProgramString(Prog, #PB_UTF8) + #LF$, #False)
  Wend
  Repeat
    ErrLine = ReadProgramError(Prog, #PB_UTF8)
    If ErrLine <> ""
      FpcAppendLimited(*R, ErrLine + #LF$, #True)
    EndIf
  Until ErrLine = ""

  WaitProgram(Prog)
  *R\ExitCode = ProgramExitCode(Prog)
  *R\DurationMs = ElapsedMilliseconds() - StartMs
  CloseProgram(Prog)

  If *R\TimedOut
    FpcAppendLimited(*R, "Erreur : compilation arretee apres timeout." + #LF$, #True)
  EndIf

  ProcedureReturn *R\ExitCode
EndProcedure

Procedure.s FpcListFilesLimited(Dir.s, Label.s)
  Protected Res.s = Label + " :" + #LF$
  Protected Count.i = 0
  Protected D.i = ExamineDirectory(#PB_Any, Dir, "*")
  If D
    While NextDirectoryEntry(D)
      Protected Name.s = DirectoryEntryName(D)
      If Name <> "." And Name <> ".." And DirectoryEntryType(D) = #PB_DirectoryEntry_File
        Count + 1
        Res + "  " + Name + " (" + Str(DirectoryEntrySize(D)) + " octets)" + #LF$
        If Count >= 20
          Res + "  [... liste limitee a 20 fichiers ...]" + #LF$
          Break
        EndIf
      EndIf
    Wend
    FinishDirectory(D)
  EndIf
  If Count = 0
    Res + "  (aucun fichier)" + #LF$
  EndIf
  ProcedureReturn Res
EndProcedure

Procedure.s FpcResultText(TargetId.s, SourcePath.s, Compiler.s, *R.FpcResult, ExeDir.s, UnitDir.s)
  Protected Res.s = "Statut    : "
  If *R\TimedOut
    Res + "Echec (timeout)" + #LF$
  ElseIf *R\ExitCode = 0
    Res + "Reussi" + #LF$
  Else
    Res + "Echec" + #LF$
  EndIf

  Res + "Cible     : " + TargetId + #LF$
  Res + "Compilateur : " + Compiler + #LF$
  Res + "Source    : " + SourcePath + #LF$
  Res + "Code      : " + Str(*R\ExitCode) + #LF$
  Res + "Duree     : " + Str(*R\DurationMs) + " ms" + #LF$ + #LF$

  Res + "Sortie compilateur" + #LF$
  Res + "------------------" + #LF$
  If *R\StdOut = ""
    Res + "(vide)" + #LF$
  Else
    Res + *R\StdOut
  EndIf
  Res + #LF$

  Res + "Erreurs compilateur" + #LF$
  Res + "-------------------" + #LF$
  If *R\StdErr = ""
    Res + "(vide)" + #LF$
  Else
    Res + *R\StdErr
  EndIf
  Res + #LF$

  Res + "Artefacts" + #LF$
  Res + "---------" + #LF$
  Res + FpcListFilesLimited(ExeDir, "Executables")
  Res + FpcListFilesLimited(UnitDir, "Unites")
  ProcedureReturn Res
EndProcedure

Procedure.s ToolFpcTargets()
  FpcInitTargets()
  Protected Res.s = "Cibles Free Pascal :" + #LF$
  Protected i.i, Origin.i
  For i = 0 To #FPC_TARGET_COUNT - 1
    Origin = 0
    Protected Compiler.s = FpcResolveCompiler(i, @Origin)
    Protected OriginText.s = "PATH"
    If Origin = 1
      OriginText = FpcTargets(i)\EnvName
    ElseIf Origin = 2
      OriginText = "MCP_FPC"
    EndIf

    Res + "- " + FpcTargets(i)\Id + " : CPU=" + FpcTargets(i)\Cpu +
          ", OS=" + FpcTargets(i)\Os + ", args=" + FpcTargets(i)\Args +
          ", compilateur=" + Compiler + " (" + OriginText + ")" + #LF$
  Next
  ProcedureReturn Res
EndProcedure

Procedure.s ToolFpcVersion(TargetId.s)
  Protected Compiler.s = Trim(G_FpcCompilerDefault)
  If Compiler = ""
    Compiler = "fpc"
  EndIf

  If Trim(TargetId) <> ""
    Protected Index.i = FpcTargetIndex(TargetId)
    If Index < 0
      ProcedureReturn "Erreur : cible inconnue : " + TargetId
    EndIf
    Protected Origin.i
    Compiler = FpcResolveCompiler(Index, @Origin)
  EndIf

  Protected R.FpcResult
  FpcRunProgram(Compiler, "-iV", "", 10000, @R)

  Protected Res.s = "Compilateur : " + Compiler + #LF$
  If Trim(TargetId) <> ""
    Res + "Cible       : " + LCase(Trim(TargetId)) + #LF$
  EndIf
  Res + "Code        : " + Str(R\ExitCode) + #LF$
  Res + "Version     :" + #LF$
  If R\StdOut = ""
    Res + "(aucune sortie)" + #LF$
  Else
    Res + R\StdOut
  EndIf
  If R\StdErr <> ""
    Res + "Stderr      :" + #LF$ + R\StdErr
  EndIf
  ProcedureReturn Res
EndProcedure

Procedure.s ToolFpcCompile(SourcePath.s, TargetId.s, BuildMode.s, OutputName.s)
  Protected Index.i = FpcTargetIndex(TargetId)
  If Index < 0
    ProcedureReturn "Erreur : cible inconnue : " + TargetId
  EndIf

  BuildMode = LCase(Trim(BuildMode))
  If BuildMode = ""
    BuildMode = "debug"
  EndIf
  If BuildMode <> "debug" And BuildMode <> "release"
    ProcedureReturn "Erreur : buildMode doit etre debug ou release."
  EndIf

  OutputName = Trim(OutputName)
  If Not FpcValidateOutputName(OutputName)
    ProcedureReturn "Erreur : outputName invalide (nom simple : lettres, chiffres, point, tiret, underscore ; pas de chemin)."
  EndIf

  ; Interface sans pointeur sortie : "" = OK, chemin dans G_FpcSafeSource.
  Protected Bad.s = FpcValidateSource(SourcePath)
  If Bad <> ""
    ProcedureReturn Bad
  EndIf
  Protected SafeSource.s = G_FpcSafeSource

  ; Repertoires de sortie dans G_FpcExeDir / G_FpcUnitDir.
  If Not FpcPrepareBuildDirs(Index)
    ProcedureReturn "Erreur : impossible de creer les repertoires de sortie."
  EndIf
  Protected ExeDir.s = G_FpcExeDir
  Protected UnitDir.s = G_FpcUnitDir

  Protected Origin.i
  Protected Compiler.s = FpcResolveCompiler(Index, @Origin)

  ; Repertoire temporaire nomme de facon simple : l'argument passe a FPC est
  ; seulement "@mcp_fpc.rsp", donc il ne contient ni espace ni chemin projet.
  Protected TempDir.s = GetTemporaryDirectory() + "mcp_fpc_" + Str(Date()) + "_" + Str(Random(1000000))
  CreateDirectory(TempDir)
  If FileSize(TempDir) <> -2
    ProcedureReturn "Erreur : impossible de creer le repertoire temporaire."
  EndIf

  Protected Response.s = TempDir + FSSeparator() + "mcp_fpc.rsp"
  Protected F.i = CreateFile(#PB_Any, Response)
  If F = 0
    DeleteDirectory(TempDir, "", #PB_FileSystem_Recursive)
    ProcedureReturn "Erreur : impossible de creer le fichier de reponse FPC."
  EndIf

  ; Chaque option vient de la table ou d'une validation stricte. Le chemin
  ; source complet vit dans le fichier de reponse, pas dans un shell.
  WriteString(F, FpcTargets(Index)\Args + #LF$, #PB_UTF8)
  If BuildMode = "debug"
    WriteString(F, "-g" + #LF$ + "-gl" + #LF$, #PB_UTF8)
  Else
    WriteString(F, "-O2" + #LF$ + "-Xs" + #LF$, #PB_UTF8)
  EndIf
  WriteString(F, "-FE" + ExeDir + #LF$, #PB_UTF8)
  WriteString(F, "-FU" + UnitDir + #LF$, #PB_UTF8)
  If OutputName <> ""
    WriteString(F, "-o" + OutputName + #LF$, #PB_UTF8)
  EndIf
  WriteString(F, SafeSource + #LF$, #PB_UTF8)
  CloseFile(F)

  Protected R.FpcResult
  FpcRunProgram(Compiler, "@mcp_fpc.rsp", TempDir, G_FpcTimeoutMs, @R)

  Protected Res.s = FpcResultText(FpcTargets(Index)\Id, SafeSource, Compiler, @R, ExeDir, UnitDir)
  DeleteFile(Response)
  DeleteDirectory(TempDir, "", #PB_FileSystem_Recursive)
  ProcedureReturn Res
EndProcedure

Procedure.i FpcBuildCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "fpc_targets", "Liste les six cibles Free Pascal et la resolution du compilateur", "", "")
  ToolDef(ToolsArr, "fpc_version", "Version du compilateur Free Pascal resolu", "target|string|Cible optionnelle (ex. linux64)", "")
  ToolDef(ToolsArr, "fpc_compile", "Compile un source Pascal confine dans MCP_FPC_ROOT", "sourcePath|string|Chemin du source;target|string|Cible (win32, win64, linux32, linux64, linux-aarch64, macos-aarch64);buildMode|string|debug ou release (defaut: debug);outputName|string|Nom de sortie simple (optionnel)", "sourcePath;target")

  ProcedureReturn RootJSON
EndProcedure

Procedure.s FpcDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Protected Result.s
  Select ToolName
    Case "fpc_targets"
      Result = ToolFpcTargets()
    Case "fpc_version"
      Result = ToolFpcVersion(GetArgString(ArgsObj, "target"))
    Case "fpc_compile"
      Result = ToolFpcCompile(GetArgString(ArgsObj, "sourcePath"),
                              GetArgString(ArgsObj, "target"),
                              GetArgString(ArgsObj, "buildMode"),
                              GetArgString(ArgsObj, "outputName"))
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect

  If FindString(Result, "Erreur :") = 1 Or FindString(Result, "Statut    : Echec") = 1
    *IsError\i = #True
  EndIf
  ProcedureReturn Result
EndProcedure
