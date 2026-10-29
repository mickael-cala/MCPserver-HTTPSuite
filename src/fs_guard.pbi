; ============================================================================
; fs_guard.pbi - Gardien commun de chemins MCP
; ============================================================================
; INTENTION
; Garantir qu'un chemin demande reste sous une racine autorisee et ne
; traverse pas un lien symbolique/junction.
;
; CONTRAT
; FSPrepareRoot retourne une racine absolue normalisee, ou "" si elle est
; absente, non directory ou en lien. FSValidatePath retourne un chemin complet
; normalise sous la racine, ou "" sans toucher au disque metier.
;
; PARANO
; La validation est lexicale ET structurelle : les ".." sont normalises avant
; le test de prefixe, puis chaque composant sous la racine est verifie comme
; un lien potentiel. La racine elle-meme est aussi verifiee ici : accepter
; une racine en lien rendrait le reste de la validation inutile.
; ============================================================================

Procedure.s FSSeparator()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ProcedureReturn "\"
  CompilerElse
    ProcedureReturn "/"
  CompilerEndIf
EndProcedure

Procedure.s FSEnsureTrailingSlash(Path.s)
  Protected Sep.s = FSSeparator()
  If Right(Path, 1) <> "/" And Right(Path, 1) <> "\"
    ProcedureReturn Path + Sep
  EndIf
  ProcedureReturn Path
EndProcedure

Procedure.i FSPathIsAbsolute(Path.s)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If Mid(Path, 2, 1) = ":" Or Left(Path, 1) = "\" Or Left(Path, 1) = "/"
      ProcedureReturn #True
    EndIf
  CompilerElse
    If Left(Path, 1) = "/"
      ProcedureReturn #True
    EndIf
  CompilerEndIf
  ProcedureReturn #False
EndProcedure

Procedure.s FSNormalizePath(Path.s)
  Protected Sep.s = FSSeparator()
  Path = ReplaceString(ReplaceString(Path, "/", Sep), "\", Sep)

  Protected Prefix.s = ""
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If Mid(Path, 2, 1) = ":"
      Prefix = Left(Path, 2)
      Path = Mid(Path, 3)
    EndIf
  CompilerElse
    If Left(Path, 1) = "/"
      Prefix = "/"
      Path = Mid(Path, 2)
    EndIf
  CompilerEndIf

  NewList Segments.s()
  Protected i.i, Count.i = CountString(Path, Sep) + 1
  Protected Part.s

  For i = 1 To Count
    Part = Trim(StringField(Path, i, Sep))
    If Part = "" Or Part = "."
      ; Segment vide ou neutre : rien a ajouter.
    ElseIf Part = ".."
      ; Remonter sans jamais sortir par effet de bord.
      If ListSize(Segments()) > 0
        LastElement(Segments())
        DeleteElement(Segments())
      EndIf
    Else
      AddElement(Segments())
      Segments() = Part
    EndIf
  Next

  Protected Result.s = Prefix
  ForEach Segments()
    If Result = "" Or Result = "/"
      Result + Segments()
    ElseIf Right(Result, 1) = ":"
      Result + Sep + Segments()
    Else
      Result + Sep + Segments()
    EndIf
  Next

  If Result = "" And Prefix <> ""
    Result = Prefix
  EndIf

  ProcedureReturn Result
EndProcedure

Procedure.i FSIsLinkOrJunction(Path.s)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; FILE_ATTRIBUTE_REPARSE_POINT : le point d'entree peut etre une junction
    ; ou un lien symbolique. GetFileAttributesW ne suit pas ce lien ici.
    Protected Attr.i = GetFileAttributes_(Path)
    If Attr = -1 Or Attr = $FFFFFFFF : ProcedureReturn #False : EndIf
    ProcedureReturn Bool((Attr & $400) <> 0)
  CompilerElse
    Protected Attr.i = GetFileAttributes(Path)
    If Attr = -1 : ProcedureReturn #False : EndIf
    ProcedureReturn Bool((Attr & #PB_FileSystem_Link) <> 0)
  CompilerEndIf
EndProcedure

Procedure.i FSPathHasLinkInRoot(FullPath.s, FullRoot.s)
  If Len(FullPath) <= Len(FullRoot) : ProcedureReturn #False : EndIf
  Protected Rel.s = Mid(FullPath, Len(FullRoot) + 1)
  Protected Sep.s = FSSeparator()
  Protected Count.i = CountString(Rel, Sep) + 1
  Protected Prefix.s = FullRoot
  Protected i.i, Part.s

  For i = 1 To Count
    Part = StringField(Rel, i, Sep)
    If Part <> ""
      Prefix = FSEnsureTrailingSlash(Prefix) + Part
      ; Verifier le lien avant FileSize : un lien casse aurait FileSize=-1.
      If FSIsLinkOrJunction(Prefix) : ProcedureReturn #True : EndIf
      If FileSize(Prefix) = -1 : Break : EndIf
    EndIf
  Next
  ProcedureReturn #False
EndProcedure

Procedure.s FSPrepareRoot(Root.s)
  Root = Trim(Root)
  If Root = ""
    Root = GetCurrentDirectory()
  EndIf

  ; Une racine relative depend du cwd au moment de l'appel. La rendre absolue
  ; maintenant empeche toute interpretation differente plus tard.
  If Not FSPathIsAbsolute(Root)
    Root = GetCurrentDirectory() + FSSeparator() + Root
  EndIf

  Root = FSNormalizePath(Root)
  If FileSize(Root) <> -2
    ProcedureReturn ""
  EndIf
  If FSIsLinkOrJunction(Root)
    ProcedureReturn ""
  EndIf
  ProcedureReturn Root
EndProcedure

Procedure.s FSValidatePath(CheminDemande.s, AllowedRoot.s)
  CheminDemande = Trim(CheminDemande)
  If CheminDemande = ""
    ProcedureReturn ""
  EndIf

  Protected FullPath.s
  If Not FSPathIsAbsolute(CheminDemande)
    FullPath = FSNormalizePath(FSEnsureTrailingSlash(AllowedRoot) + CheminDemande)
  Else
    FullPath = FSNormalizePath(CheminDemande)
  EndIf

  Protected FullRoot.s = FSEnsureTrailingSlash(FSNormalizePath(AllowedRoot))
  Protected NormPath.s, NormRoot.s

  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; Les chemins Windows sont insensibles a la casse.
    NormPath = UCase(FSEnsureTrailingSlash(FullPath))
    NormRoot = UCase(FullRoot)
  CompilerElse
    NormPath = FSEnsureTrailingSlash(FullPath)
    NormRoot = FullRoot
  CompilerEndIf

  ; Le slash final dans NormRoot empeche C:\root de valider C:\root_evil.
  If Left(NormPath, Len(NormRoot)) <> NormRoot
    ProcedureReturn ""
  EndIf

  ; Un lien dans n'importe quel composant sous la racine peut faire sortir le
  ; noyau filesystem de la zone logique autorisee : on refuse avant ouverture.
  If FSPathHasLinkInRoot(FullPath, FullRoot)
    ProcedureReturn ""
  EndIf

  ProcedureReturn FullPath
EndProcedure
