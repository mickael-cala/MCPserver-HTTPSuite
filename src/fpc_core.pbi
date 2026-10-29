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
