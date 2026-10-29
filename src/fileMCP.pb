; ============================================================================
;  SERVEUR MCP - PureBasic (HTTP) - 100 % Natif (Sans DLL / API)
;  Gestion de fichiers confinee a une racine autorisee (MCP_ROOT)
; ============================================================================
;  Compilation : build.bat / build.sh (ou Options du compilateur -> Console)
;  Transport   : JSON-RPC 2.0 sur HTTP (POST /mcp, JSON par defaut, SSE optionnel)
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
IncludeFile "fs_guard.pbi"

Global G_AllowedRoot.s
Global G_RootSecret.s

#FILE_MAX_READ_BYTES = 2 * 1024 * 1024
#MAX_SEARCH_DEPTH   = 32
#MAX_SEARCH_ENTRIES = 10000
#SEARCH_TIMEOUT_MS  = 10000

; ---------------------------------------------------------------------------
; Utilitaires de chemins (100 % natifs)
; ---------------------------------------------------------------------------

; Desormais de simples wrappers : la logique de confinement vit dans
; fs_guard.pbi pour etre partagee entre fileMCP et fpcMCP sans copie.
Procedure.s GetPathSeparator()
  ProcedureReturn FSSeparator()
EndProcedure

Procedure.s EnsureTrailingSlash(Path.s)
  ProcedureReturn FSEnsureTrailingSlash(Path)
EndProcedure

Procedure.s NormalizePath(Path.s)
  ProcedureReturn FSNormalizePath(Path)
EndProcedure

Procedure.i IsLinkOrJunction(Path.s)
  ProcedureReturn FSIsLinkOrJunction(Path)
EndProcedure

Procedure.i PathHasLinkInRoot(FullPath.s, FullRoot.s)
  ProcedureReturn FSPathHasLinkInRoot(FullPath, FullRoot)
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
  ; La racine autorisee G_AllowedRoot est fixee et durcie au demarrage par
  ; FSPrepareRoot : le gardien peut s'y appuyer pour chaque demande.
  ProcedureReturn FSValidatePath(CheminDemande, G_AllowedRoot)
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

  ; Borne unique : la meme constante sert a la lecture directe, la lecture
  ; par lignes et la recherche. Ne pas laisser 20000 ici : le catalogue et le
  ; comportement divergeraient silencieusement.
  If BytesToRead > #FILE_MAX_READ_BYTES
    BytesToRead = #FILE_MAX_READ_BYTES
    Truncated = #True
  EndIf

  Protected *Buffer = AllocateMemory(BytesToRead + 1)
  Protected Content.s = ""
  If *Buffer
    ; Ne jamais decoder plus d'octets que ReadData n'en a reellement lus.
    Protected ReadBytes.q = ReadData(FileNum, *Buffer, BytesToRead)
    If ReadBytes < 0 : ReadBytes = 0 : EndIf
    PokeB(*Buffer + ReadBytes, 0)
    Content = PeekS(*Buffer, ReadBytes, #PB_UTF8 | #PB_ByteLength)
    FreeMemory(*Buffer)
  EndIf
  CloseFile(FileNum)

  If Truncated
    ; Annoncer aussi la taille reelle : l'agent consommateur peut alors
    ; estimer combien de plages read_file_lines seront necessaires, sans
    ; appel supplementaire get_file_info.
    Content + #LF$ + "[... Tronque au-dela de " + Str(#FILE_MAX_READ_BYTES) +
            " octets (fichier : " + Str(Size) + " octets) ...]"
  EndIf
  ProcedureReturn Content
EndProcedure

Procedure.s ToolReadFileLines(Path.s, StartLine.i, MaxLines.i)
  Protected SafePath.s = ValiderChemin(Path)
  If SafePath = "" : ProcedureReturn "ACCES_REFUSE" : EndIf
  If FileSize(SafePath) < 0 : ProcedureReturn "Fichier introuvable : " + Path : EndIf
  ; Lecture ligne par ligne != lecture moins couteuse : une ligne peut etre
  ; enorme. La borne de fichier reste donc identique a read_file.
  If FileSize(SafePath) > #FILE_MAX_READ_BYTES
    ProcedureReturn "Fichier depasse la limite de 2 Mio."
  EndIf

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
            If Not IsBinaryFile(Full) And DirectoryEntrySize(Dir) <= #FILE_MAX_READ_BYTES
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
  ToolDef(ToolsArr, "read_file", "Lire un fichier texte (tronque au-dela de 2 Mio)", "path|string|Chemin du fichier", "path")
  ToolDef(ToolsArr, "read_file_lines", "Lire une plage de lignes (fichier limite a 2 Mio)", "path|string|Chemin;startLine|integer|Ligne de depart (defaut:1);maxLines|integer|Nombre de lignes (defaut:50)", "path")
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

; La racine vient de l'environnement, mais elle doit etre absolue et reelle :
; un lien ici contournerait toute la validation effectuee sous cette racine.
G_AllowedRoot = FSPrepareRoot(GetEnvironmentVariable("MCP_ROOT"))
If G_AllowedRoot = ""
  LogError("MCP_ROOT invalide : repertoire introuvable ou lien symbolique/junction.")
  End 1
EndIf
LogDebug("Racine autorisee : " + G_AllowedRoot)

G_RootSecret = GetEnvironmentVariable("MCP_ROOT_SECRET")

If Not CheckRuntime()
  End 1
EndIf

If Not MCPHttpMainLoop(8101)
  End 1
EndIf

End
