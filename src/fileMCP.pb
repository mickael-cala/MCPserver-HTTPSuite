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

; Bornes de l'outil exec (exécution shell confirmée).
#EXEC_MAX_OUTPUT         = 65536
#EXEC_DEFAULT_TIMEOUT_MS = 10000
#EXEC_MAX_TIMEOUT_MS     = 60000
#EXEC_MAX_CMD_LEN        = 4096
#EXEC_MAX_BATCH          = 20

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
  ; Comparaison a temps constant (mcp_common/http_server.pbi) : le secret
  ; ne se devine pas caractere par caractere via le temps de reponse.
  If Not HttpConstCompare(Secret, G_RootSecret)
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
; Outil exec : execution shell confirmee (cmd.exe sous Windows, bash/sh sinon).
; Chaque appel (commande unique ou lot) doit porter confirm=true : le client
; MCP soumet l'appel a la validation de l'operateur avant de le renvoyer,
; comme pour les ecritures githubMCP. Le repertoire de travail est confine
; sous la racine autorisee, mais la commande elle-meme reste libre : ne
; confirmer que des commandes verifiees.
; ---------------------------------------------------------------------------

Procedure.s ToolExec(Confirm.i, Command.s, CommandsArr.i, Workdir.s, TimeoutMs.i)
  ; Garde de confirmation : une validation humaine par commande ou par lot.
  If Not Confirm
    LogError("exec refuse sans confirmation : " + Left(Command, 120))
    ProcedureReturn "Erreur : commande non confirmee (confirm=true requis). L'operateur doit valider chaque commande ou lot avant execution."
  EndIf

  ; Commande unique OU lot, jamais les deux.
  Protected CmdCount.i = 0
  If CommandsArr
    CmdCount = JSONArraySize(CommandsArr)
    If CmdCount < 0 : CmdCount = 0 : EndIf
  EndIf
  If Command <> "" And CmdCount > 0
    ProcedureReturn "Erreur : fournir command (unique) ou commands (lot), pas les deux."
  EndIf
  If Command = "" And CmdCount = 0
    ProcedureReturn "Erreur : commande vide (command ou commands requis)."
  EndIf
  If CmdCount > #EXEC_MAX_BATCH
    ProcedureReturn "Erreur : lot depasse la limite de " + Str(#EXEC_MAX_BATCH) + " commandes."
  EndIf

  ; Corps du script : bornes par ligne, elements non texte ignores.
  NewList Cmds.s()
  Protected i.i, Elt.i, OneCmd.s
  If Command <> ""
    If Len(Command) > #EXEC_MAX_CMD_LEN
      ProcedureReturn "Erreur : commande depasse " + Str(#EXEC_MAX_CMD_LEN) + " caracteres."
    EndIf
    AddElement(Cmds())
    Cmds() = Command
  Else
    For i = 0 To CmdCount - 1
      Elt = GetJSONElement(CommandsArr, i)
      If Elt And JSONType(Elt) = #PB_JSON_String
        OneCmd = GetJSONString(Elt)
        If OneCmd <> ""
          If Len(OneCmd) > #EXEC_MAX_CMD_LEN
            ProcedureReturn "Erreur : commande " + Str(i + 1) + " depasse " + Str(#EXEC_MAX_CMD_LEN) + " caracteres."
          EndIf
          AddElement(Cmds())
          Cmds() = OneCmd
        EndIf
      EndIf
    Next
    If ListSize(Cmds()) = 0
      ProcedureReturn "Erreur : lot vide (aucune commande texte valide)."
    EndIf
  EndIf

  ; Timeout borne : le serveur est mono-thread, une commande bloquee doit mourir.
  If TimeoutMs < 1000 : TimeoutMs = 1000 : EndIf
  If TimeoutMs > #EXEC_MAX_TIMEOUT_MS : TimeoutMs = #EXEC_MAX_TIMEOUT_MS : EndIf

  ; Repertoire de travail confine sous la racine autorisee.
  If Workdir = ""
    Workdir = G_AllowedRoot
  Else
    Workdir = ValiderChemin(Workdir)
    If Workdir = "" : ProcedureReturn "ACCES_REFUSE" : EndIf
  EndIf
  ; RunProgram ignore silencieusement un working dir invalide (cf. GitRun).
  If FileSize(Workdir) <> -2
    ProcedureReturn "Erreur : repertoire de travail introuvable : " + Workdir
  EndIf

  ; Script temporaire : un seul shell pour tout l'appel (le lot partage cd,
  ; variables d'environnement...). stderr y est fusionne dans stdout.
  Protected ScriptExt.s
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ScriptExt = ".cmd"
  CompilerElse
    ScriptExt = ".sh"
  CompilerEndIf
  Protected Script.s = GetTemporaryDirectory() + "mcp_exec_" + Str(Date()) + "_" + Str(Random(999999)) + ScriptExt

  LogDebug("exec confirme : " + Str(ListSize(Cmds())) + " commande(s), workdir=" + Workdir)

  Protected F.i = CreateFile(#PB_Any, Script)
  If Not F
    ProcedureReturn "Impossible de creer le script temporaire : " + Script
  EndIf
  Protected WriteOk.i = #True
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; cmd.exe lit les .cmd dans la page de code ANSI : ecrire en ASCII
    ; (les accents ne survivent pas, cf. ERRATA).
    ForEach Cmds()
      If Not WriteStringN(F, Cmds(), #PB_Ascii) : WriteOk = #False : EndIf
    Next
  CompilerElse
    ; "exec 2>&1" fusionne stderr des le demarrage du shell, sans modifier
    ; les lignes de commande elles-memes.
    If Not WriteStringN(F, "exec 2>&1", #PB_UTF8) : WriteOk = #False : EndIf
    ForEach Cmds()
      If Not WriteStringN(F, Cmds(), #PB_UTF8) : WriteOk = #False : EndIf
    Next
  CompilerEndIf
  CloseFile(F)
  If Not WriteOk
    DeleteFile(Script)
    ProcedureReturn "Impossible d'ecrire le script temporaire : " + Script
  EndIf

  Protected Prog.i
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; cmd.exe exige la forme /c "<commande>" quand celle-ci commence par un
    ; chemin entre guillemets (idiome documente de cmd, cf. GitRun).
    Prog = RunProgram("cmd.exe", "/c " + Chr(34) + Chr(34) + Script + Chr(34) + " 2>&1" + Chr(34), Workdir,
                      #PB_Program_Open | #PB_Program_Read | #PB_Program_Hide)
  CompilerElse
    ; bash si present, sinon sh POSIX.
    Protected Shell.s = "/bin/bash"
    If FileSize(Shell) = -1
      Shell = "/bin/sh"
    EndIf
    Prog = RunProgram(Shell, Script, Workdir,
                      #PB_Program_Open | #PB_Program_Read | #PB_Program_Hide)
  CompilerEndIf
  If Prog = 0
    DeleteFile(Script)
    ProcedureReturn "Impossible de lancer le shell d'execution."
  EndIf

  ; Lecture avec deadline et sortie bornee. Au-dela de la borne, on continue
  ; de lire sans stocker : sinon le fils bloquerait sur un pipe plein.
  Protected StartMs.i = ElapsedMilliseconds()
  Protected Deadline.i = StartMs + TimeoutMs
  Protected Out.s = ""
  Protected OutLine.s
  Protected Truncated.i = #False
  Protected TimedOut.i = #False

  Repeat
    If AvailableProgramOutput(Prog)
      OutLine = ReadProgramString(Prog, #PB_UTF8)
      If Not Truncated
        Out + OutLine + #LF$
        If Len(Out) > #EXEC_MAX_OUTPUT
          Out = Left(Out, #EXEC_MAX_OUTPUT) + #LF$ + "[... sortie tronquee ...]"
          Truncated = #True
        EndIf
      EndIf
    Else
      Delay(5)
    EndIf
    If ElapsedMilliseconds() > Deadline
      TimedOut = #True
      KillProgram(Prog)
      Break
    EndIf
  Until ProgramRunning(Prog) = 0 And AvailableProgramOutput(Prog) = 0

  WaitProgram(Prog)
  Protected ExitCode.i = ProgramExitCode(Prog)
  Protected DurationMs.i = ElapsedMilliseconds() - StartMs
  CloseProgram(Prog)
  DeleteFile(Script)

  Protected Res.s
  If TimedOut
    Res = "Echec : commande interrompue apres " + Str(TimeoutMs) + " ms (timeout)." + #LF$
  ElseIf ExitCode <> 0
    Res = "Echec : commande terminee avec le code " + Str(ExitCode) + "." + #LF$
  Else
    Res = "Commande executee." + #LF$
  EndIf
  Res + "Repertoire : " + Workdir + #LF$
  Res + "Code de sortie : " + Str(ExitCode) + #LF$
  Res + "Duree : " + Str(DurationMs) + " ms" + #LF$
  Res + "--- Sortie (stdout+stderr) ---" + #LF$
  Res + Out
  ProcedureReturn Res
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
  ToolDef(ToolsArr, "exec", "Executer une commande shell (cmd.exe sous Windows, bash sous Linux/macOS) dans un repertoire confine. EXIGE confirm=true : validation humaine requise pour chaque commande ou lot.", "command|string|Commande unique;commands|array|Lot de commandes (un seul shell);workdir|string|Repertoire de travail sous la racine (defaut: racine);timeoutMs|integer|Duree max en ms (defaut:10000, max:60000);confirm|boolean|Doit valoir true", "confirm")

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
    Case "exec"
      ProcedureReturn ToolExec(GetArgBool(ArgsObj, "confirm", 0), GetArgString(ArgsObj, "command"), GetArgArray(ArgsObj, "commands"), GetArgString(ArgsObj, "workdir"), GetArgInt(ArgsObj, "timeoutMs", #EXEC_DEFAULT_TIMEOUT_MS))
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "FileMCPServer-PureBasic"
G_ServerVersion = "2.1.0"
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
