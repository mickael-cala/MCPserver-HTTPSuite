; ============================================================================
;  SERVEUR MCP - PureBasic (HTTP) - 100 % Natif (Sans DLL / API)
;  Gestion de fichiers confinee a une racine autorisee (MCP_ROOT)
; ============================================================================
;  Compilation : build.bat / build.sh (ou Options du compilateur -> Console)
;  Transport   : JSON-RPC 2.0 sur HTTP (POST /mcp, JSON uniquement, sans SSE)
;  Modules     : mcp_common/ (runtime, logging, json_helpers, protocol,
;                jsonrpc, http_server)
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

Global G_AllowedRoot.s
Global G_RootSecret.s

#MAX_SEARCH_DEPTH   = 32
#MAX_SEARCH_ENTRIES = 10000
#SEARCH_TIMEOUT_MS  = 10000

; ---------------------------------------------------------------------------
; Utilitaires de chemins (100 % natifs)
; ---------------------------------------------------------------------------

Procedure.s GetPathSeparator()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ProcedureReturn "\"
  CompilerElse
    ProcedureReturn "/"
  CompilerEndIf
EndProcedure

Procedure.s EnsureTrailingSlash(Path.s)
  Protected Sep.s = GetPathSeparator()
  If Right(Path, 1) <> "/" And Right(Path, 1) <> "\"
    ProcedureReturn Path + Sep
  EndIf
  ProcedureReturn Path
EndProcedure

Procedure.s NormalizePath(Path.s)
  Protected Sep.s = GetPathSeparator()
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
      ; Ignorer les separateurs redondants et les segments neutres
    ElseIf Part = ".."
      ; Remonter d'un cran si possible
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

; ---------------------------------------------------------------------------
; Detection des liens symboliques / junctions (confinement reel)
; ---------------------------------------------------------------------------
Procedure.i IsLinkOrJunction(Path.s)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; GetFileAttributesW ne suit pas le lien : le bit reparse est present.
    Protected Attr.i = GetFileAttributes_(Path)
    If Attr = -1 Or Attr = $FFFFFFFF : ProcedureReturn #False : EndIf
    ProcedureReturn Bool((Attr & $400) <> 0)   ; FILE_ATTRIBUTE_REPARSE_POINT
  CompilerElse
    Protected Attr.i = GetFileAttributes(Path)
    If Attr = -1 : ProcedureReturn #False : EndIf
    ProcedureReturn Bool((Attr & #PB_FileSystem_Link) <> 0)
  CompilerEndIf
EndProcedure

; Verifie chaque composant sous FullRoot (racine incluse non verifiee).
Procedure.i PathHasLinkInRoot(FullPath.s, FullRoot.s)
  If Len(FullPath) <= Len(FullRoot) : ProcedureReturn #False : EndIf
  Protected Rel.s = Mid(FullPath, Len(FullRoot) + 1)
  Protected Sep.s = GetPathSeparator()
  Protected Count.i = CountString(Rel, Sep) + 1
  Protected Prefix.s = FullRoot
  Protected i.i, Part.s

  For i = 1 To Count
    Part = StringField(Rel, i, Sep)
    If Part <> ""
      Prefix = EnsureTrailingSlash(Prefix) + Part
      ; Verifier le lien avant FileSize (un lien casse a FileSize = -1).
      If IsLinkOrJunction(Prefix) : ProcedureReturn #True : EndIf
      If FileSize(Prefix) = -1 : Break : EndIf
    EndIf
  Next
  ProcedureReturn #False
EndProcedure

Procedure.i NativeCreateDirectories(Path.s)
  Protected Sep.s = GetPathSeparator()
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

Procedure.s ValiderChemin(CheminDemande.s)
  CheminDemande = Trim(CheminDemande)
  If CheminDemande = ""
    ProcedureReturn ""
  EndIf

  Protected IsAbsolute.i = #False
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If Mid(CheminDemande, 2, 1) = ":" Or Left(CheminDemande, 1) = "\" Or Left(CheminDemande, 1) = "/"
      IsAbsolute = #True
    EndIf
  CompilerElse
    If Left(CheminDemande, 1) = "/"
      IsAbsolute = #True
    EndIf
  CompilerEndIf

  Protected FullPath.s
  If Not IsAbsolute
    FullPath = NormalizePath(EnsureTrailingSlash(G_AllowedRoot) + CheminDemande)
  Else
    FullPath = NormalizePath(CheminDemande)
  EndIf

  Protected FullRoot.s = EnsureTrailingSlash(NormalizePath(G_AllowedRoot))
  Protected NormPath.s, NormRoot.s

  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    NormPath = UCase(EnsureTrailingSlash(FullPath))
    NormRoot = UCase(FullRoot)
  CompilerElse
    NormPath = EnsureTrailingSlash(FullPath)
    NormRoot = FullRoot
  CompilerEndIf

  ; Confinement sous la racine autorisee
  If Left(NormPath, Len(NormRoot)) <> NormRoot
    ProcedureReturn ""
  EndIf

  ; Interdire les liens/junctions a l'interieur de la racine (evasion).
  If PathHasLinkInRoot(FullPath, FullRoot)
    ProcedureReturn ""
  EndIf

  ProcedureReturn FullPath
EndProcedure

Procedure.i IsBinaryFile(Filename.s)
  Protected Ext.s = LCase(GetExtensionPart(Filename))
  Select Ext
    Case "exe", "dll", "so", "dylib", "o", "ppu", "obj", "bin", "a", "lib"
      ProcedureReturn #True
  EndSelect
  ProcedureReturn #False
EndProcedure

; ---------------------------------------------------------------------------
; Outils de manipulation de fichiers (Tools)
; ---------------------------------------------------------------------------

Procedure.s ToolListFiles(Path.s)
  Protected SafePath.s = ValiderChemin(Path)
  If SafePath = "" : ProcedureReturn "ACCES_REFUSE" : EndIf
  If FileSize(SafePath) <> -2 : ProcedureReturn "Le repertoire n'existe pas : " + Path : EndIf

  Protected Res.s = "", Count.i = 0
  Protected Dir.i = ExamineDirectory(#PB_Any, SafePath, "*")
  If Dir
    While NextDirectoryEntry(Dir)
      Protected EntryName.s = DirectoryEntryName(Dir)
      If EntryName <> "." And EntryName <> ".."
        Count + 1
        If DirectoryEntryType(Dir) = #PB_DirectoryEntry_Directory
          Res + "[DIR]  " + EntryName + #LF$
        Else
          Res + "[FILE] " + EntryName + "  (" + Str(DirectoryEntrySize(Dir)) + " octets)" + #LF$
        EndIf
      EndIf
    Wend
    FinishDirectory(Dir)
  EndIf
  ProcedureReturn SafePath + " (" + Str(Count) + " elements) :" + #LF$ + Res
EndProcedure

Procedure.s ToolReadFile(Path.s)
  Protected SafePath.s = ValiderChemin(Path)
  If SafePath = "" : ProcedureReturn "ACCES_REFUSE" : EndIf
  If FileSize(SafePath) < 0 : ProcedureReturn "Fichier introuvable : " + Path : EndIf

  Protected FileNum.i = ReadFile(#PB_Any, SafePath)
  If Not FileNum : ProcedureReturn "Impossible d'ouvrir le fichier : " + Path : EndIf

  Protected Size.q = Lof(FileNum)
  Protected BytesToRead.q = Size
  Protected Truncated.i = #False

  If BytesToRead > 20000
    BytesToRead = 20000
    Truncated = #True
  EndIf

  Protected *Buffer = AllocateMemory(BytesToRead + 1)
  Protected Content.s = ""
  If *Buffer
    ReadData(FileNum, *Buffer, BytesToRead)
    Content = PeekS(*Buffer, BytesToRead, #PB_UTF8 | #PB_ByteLength)
    FreeMemory(*Buffer)
  EndIf
  CloseFile(FileNum)

  If Truncated
    Content + #LF$ + "[... Tronque au-dela de 20000 octets ...]"
  EndIf
  ProcedureReturn Content
EndProcedure

Procedure.s ToolReadFileLines(Path.s, StartLine.i, MaxLines.i)
  Protected SafePath.s = ValiderChemin(Path)
  If SafePath = "" : ProcedureReturn "ACCES_REFUSE" : EndIf
  If FileSize(SafePath) < 0 : ProcedureReturn "Fichier introuvable : " + Path : EndIf
  If FileSize(SafePath) > 5 * 1024 * 1024 : ProcedureReturn "Fichier depasse la limite de 5 Mo." : EndIf

  Protected FileNum.i = ReadFile(#PB_Any, SafePath)
  If Not FileNum : ProcedureReturn "Impossible d'ouvrir le fichier : " + Path : EndIf

  If StartLine < 1 : StartLine = 1 : EndIf
  If MaxLines < 1 : MaxLines = 50 : EndIf
  Protected EndLine.i = StartLine + MaxLines - 1

  Protected CurrentLine.i = 1
  Protected Res.s = "", LineText.s = ""

  While Not Eof(FileNum)
    LineText = ReadString(FileNum, #PB_UTF8)
    If CurrentLine >= StartLine And CurrentLine <= EndLine
      Res + RSet(Str(CurrentLine), 5, " ") + ": " + LineText + #LF$
    EndIf
    If CurrentLine > EndLine : Break : EndIf
    CurrentLine + 1
  Wend

  CloseFile(FileNum)
  ProcedureReturn Res
EndProcedure

Procedure.s ToolWriteFile(Path.s, Content.s)
  Protected SafePath.s = ValiderChemin(Path)
  If SafePath = "" : ProcedureReturn "ACCES_REFUSE" : EndIf

  Protected FileNum.i = CreateFile(#PB_Any, SafePath)
  If Not FileNum : ProcedureReturn "Erreur lors de la creation du fichier : " + Path : EndIf

  WriteString(FileNum, Content, #PB_UTF8)
  CloseFile(FileNum)
  ProcedureReturn "Fichier ecrit avec succes (" + Str(StringByteLength(Content, #PB_UTF8)) + " octets) : " + SafePath
EndProcedure

Procedure.s ToolCreateDirectory(Path.s)
  Protected SafePath.s = ValiderChemin(Path)
  If SafePath = "" : ProcedureReturn "ACCES_REFUSE" : EndIf
  If FileSize(SafePath) = -2 : ProcedureReturn "Le repertoire existe deja : " + SafePath : EndIf

  If NativeCreateDirectories(SafePath)
    ProcedureReturn "Repertoire cree : " + SafePath
  Else
    ProcedureReturn "Impossible de creer le repertoire : " + SafePath
  EndIf
EndProcedure

Procedure.s ToolDeleteFile(Path.s)
  Protected SafePath.s = ValiderChemin(Path)
  If SafePath = "" : ProcedureReturn "ACCES_REFUSE" : EndIf

  If FileSize(SafePath) = -2
    If DeleteDirectory(SafePath, "", #PB_FileSystem_Recursive)
      ProcedureReturn "Dossier supprime : " + SafePath
    Else
      ProcedureReturn "Impossible de supprimer le dossier : " + SafePath
    EndIf
  ElseIf FileSize(SafePath) >= 0
    If DeleteFile(SafePath)
      ProcedureReturn "Fichier supprime : " + SafePath
    Else
      ProcedureReturn "Impossible de supprimer le fichier : " + SafePath
    EndIf
  EndIf
  ProcedureReturn "Cible introuvable : " + SafePath
EndProcedure

Procedure.s ToolMoveFile(OldPath.s, NewPath.s)
  Protected SafeOld.s = ValiderChemin(OldPath)
  Protected SafeNew.s = ValiderChemin(NewPath)
  If SafeOld = "" Or SafeNew = "" : ProcedureReturn "ACCES_REFUSE" : EndIf
  If FileSize(SafeOld) = -1 : ProcedureReturn "Source introuvable : " + SafeOld : EndIf

  If RenameFile(SafeOld, SafeNew)
    ProcedureReturn "Deplace avec succes : " + SafeOld + " -> " + SafeNew
  Else
    If CopyFile(SafeOld, SafeNew)
      DeleteFile(SafeOld)
      ProcedureReturn "Fichier deplace (copie/suppression) : " + SafeOld + " -> " + SafeNew
    EndIf
  EndIf
  ProcedureReturn "Echec du deplacement de " + SafeOld + " vers " + SafeNew
EndProcedure

Procedure.s ToolGetFileInfo(Path.s)
  Protected SafePath.s = ValiderChemin(Path)
  If SafePath = "" : ProcedureReturn "ACCES_REFUSE" : EndIf
  If FileSize(SafePath) = -1 : ProcedureReturn "Fichier ou dossier introuvable : " + SafePath : EndIf

  Protected IsDir.s = "non"
  Protected Size.q = FileSize(SafePath)
  If Size = -2
    IsDir = "oui"
    Size = 0
  EndIf

  Protected Stamp.i = GetFileDate(SafePath, #PB_Date_Modified)
  Protected DateText.s = FormatDate("%YYYY-%MM-%DD %HH:%II:%SS", Stamp)

  Protected Res.s = "Chemin : " + SafePath + #LF$
  Res + "Taille : " + Str(Size) + " octets" + #LF$
  Res + "Horodatage : " + DateText + #LF$
  Res + "Est un dossier : " + IsDir
  ProcedureReturn Res
EndProcedure

Procedure SearchRecursive(BaseDir.s, Pattern.s, List Matches.s(), *Count.Integer, Depth.i, *Deadline.Integer, *Visited.Integer)
  If *Count\i >= 100 Or Depth > #MAX_SEARCH_DEPTH : ProcedureReturn : EndIf
  If ElapsedMilliseconds() > *Deadline\i Or *Visited\i >= #MAX_SEARCH_ENTRIES : ProcedureReturn : EndIf

  Protected Dir.i = ExamineDirectory(#PB_Any, BaseDir, "*")
  If Dir
    While NextDirectoryEntry(Dir)
      *Visited\i + 1
      If *Visited\i > #MAX_SEARCH_ENTRIES : Break : EndIf

      Protected Name.s = DirectoryEntryName(Dir)
      If Name <> "." And Name <> ".."
        Protected Full.s = EnsureTrailingSlash(BaseDir) + Name
        ; Ignorer liens/junctions : evite les sorties de racine et les cycles.
        If Not IsLinkOrJunction(Full)
          If DirectoryEntryType(Dir) = #PB_DirectoryEntry_Directory
            SearchRecursive(Full, Pattern, Matches(), *Count, Depth + 1, *Deadline, *Visited)
          Else
            If Not IsBinaryFile(Full) And DirectoryEntrySize(Dir) <= 2 * 1024 * 1024
              Protected F.i = ReadFile(#PB_Any, Full)
              If F
                Protected LineNum.i = 0
                While Not Eof(F)
                  LineNum + 1
                  Protected Line.s = ReadString(F, #PB_UTF8)
                  If FindString(LCase(Line), LCase(Pattern))
                    AddElement(Matches())
                    Matches() = Full + ":" + Str(LineNum) + ": " + Trim(Line)
                    *Count\i + 1
                    If *Count\i >= 100 : Break : EndIf
                  EndIf
                Wend
                CloseFile(F)
              EndIf
            EndIf
          EndIf
        EndIf
      EndIf
      If *Count\i >= 100 Or ElapsedMilliseconds() > *Deadline\i Or *Visited\i >= #MAX_SEARCH_ENTRIES : Break : EndIf
    Wend
    FinishDirectory(Dir)
  EndIf
EndProcedure

Procedure.s ToolSearchFiles(Path.s, Pattern.s)
  Protected SafePath.s = ValiderChemin(Path)
  If SafePath = "" : ProcedureReturn "ACCES_REFUSE" : EndIf
  If FileSize(SafePath) <> -2 : ProcedureReturn "Repertoire introuvable : " + SafePath : EndIf

  NewList Matches.s()
  Protected Total.Integer\i = 0
  Protected Deadline.i = ElapsedMilliseconds() + #SEARCH_TIMEOUT_MS
  Protected Visited.i = 0
  SearchRecursive(SafePath, Pattern, Matches(), @Total, 0, @Deadline, @Visited)

  Protected Res.s = Str(Total\i) + " resultat(s) pour " + #DQUOTE$ + Pattern + #DQUOTE$ + " :" + #LF$
  ForEach Matches()
    Res + Matches() + #LF$
  Next
  If Visited >= #MAX_SEARCH_ENTRIES Or ElapsedMilliseconds() > Deadline
    Res + "[Recherche interrompue : limite de parcours atteinte]" + #LF$
  EndIf
  ProcedureReturn Res
EndProcedure

Procedure.s ToolChangeRoot(NewRoot.s, Secret.s)
  If G_RootSecret = ""
    ProcedureReturn "Modification refusee : MCP_ROOT_SECRET non configure cote serveur."
  EndIf
  If Secret <> G_RootSecret
    ProcedureReturn "Modification refusee : secret invalide."
  EndIf
  If FileSize(NewRoot) <> -2
    ProcedureReturn "Repertoire introuvable : " + NewRoot
  EndIf

  Protected NewNormalized.s = NormalizePath(NewRoot)
  If IsLinkOrJunction(NewNormalized)
    ProcedureReturn "Modification refusee : la racine ne doit pas etre un lien symbolique/junction."
  EndIf

  G_AllowedRoot = NewNormalized
  LogDebug("Racine autorisee modifiee : " + G_AllowedRoot)
  ProcedureReturn "Racine autorisee modifiee : " + G_AllowedRoot
EndProcedure

; ---------------------------------------------------------------------------
; Catalogue MCP (hook *G_CatalogBuilder)
; ---------------------------------------------------------------------------
Procedure.i BuildToolsCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "list_files", "Lister le contenu d'un repertoire (confine a la racine autorisee)", "path|string|Chemin du repertoire", "path")
  ToolDef(ToolsArr, "read_file", "Lire un fichier texte (tronque au-dela de 20000 octets)", "path|string|Chemin du fichier", "path")
  ToolDef(ToolsArr, "read_file_lines", "Lire une plage de lignes (fichier limite a 5 Mo)", "path|string|Chemin;startLine|integer|Ligne de depart (defaut:1);maxLines|integer|Nombre de lignes (defaut:50)", "path")
  ToolDef(ToolsArr, "write_file", "Ecrire/creer un fichier texte", "path|string|Chemin;content|string|Contenu", "path;content")
  ToolDef(ToolsArr, "create_directory", "Creer un repertoire", "path|string|Chemin", "path")
  ToolDef(ToolsArr, "delete_file", "Supprimer un fichier ou dossier", "path|string|Chemin", "path")
  ToolDef(ToolsArr, "move_file", "Deplacer ou renommer un fichier", "oldPath|string|Chemin source;newPath|string|Chemin destination", "oldPath;newPath")
  ToolDef(ToolsArr, "get_file_info", "Infos detaillees fichier/dossier", "path|string|Chemin", "path")
  ToolDef(ToolsArr, "search_files", "Rechercher du texte (recursif)", "path|string|Repertoire de depart;pattern|string|Texte recherche", "path;pattern")
  ToolDef(ToolsArr, "change_root", "CHANGER LA ZONE AUTORISEE", "newRoot|string|Nouveau repertoire racine;secret|string|Mot de passe MCP_ROOT_SECRET", "newRoot;secret")

  ProcedureReturn RootJSON
EndProcedure

; ---------------------------------------------------------------------------
; Dispatch des outils (hook *G_ToolHandler)
; ---------------------------------------------------------------------------
Procedure.s ToolDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Select ToolName
    Case "list_files"
      ProcedureReturn ToolListFiles(GetArgString(ArgsObj, "path"))
    Case "read_file"
      ProcedureReturn ToolReadFile(GetArgString(ArgsObj, "path"))
    Case "read_file_lines"
      ProcedureReturn ToolReadFileLines(GetArgString(ArgsObj, "path"), GetArgInt(ArgsObj, "startLine", 1), GetArgInt(ArgsObj, "maxLines", 50))
    Case "write_file"
      ProcedureReturn ToolWriteFile(GetArgString(ArgsObj, "path"), GetArgString(ArgsObj, "content"))
    Case "create_directory"
      ProcedureReturn ToolCreateDirectory(GetArgString(ArgsObj, "path"))
    Case "delete_file"
      ProcedureReturn ToolDeleteFile(GetArgString(ArgsObj, "path"))
    Case "move_file"
      ProcedureReturn ToolMoveFile(GetArgString(ArgsObj, "oldPath"), GetArgString(ArgsObj, "newPath"))
    Case "get_file_info"
      ProcedureReturn ToolGetFileInfo(GetArgString(ArgsObj, "path"))
    Case "search_files"
      ProcedureReturn ToolSearchFiles(GetArgString(ArgsObj, "path"), GetArgString(ArgsObj, "pattern"))
    Case "change_root"
      ProcedureReturn ToolChangeRoot(GetArgString(ArgsObj, "newRoot"), GetArgString(ArgsObj, "secret"))
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "FileMCPServer-PureBasic"
G_ServerVersion = "2.0.0"
*G_ToolHandler = @ToolDispatch()
*G_CatalogBuilder = @BuildToolsCatalog()

G_AllowedRoot = GetEnvironmentVariable("MCP_ROOT")
If G_AllowedRoot = ""
  G_AllowedRoot = GetCurrentDirectory()
EndIf
G_AllowedRoot = NormalizePath(G_AllowedRoot)

G_RootSecret = GetEnvironmentVariable("MCP_ROOT_SECRET")

If Not CheckRuntime()
  End 1
EndIf

If Not MCPHttpMainLoop(8101)
  End 1
EndIf

End
