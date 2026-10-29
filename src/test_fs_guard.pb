; ============================================================================
; test_fs_guard.pb - Tests du gardien commun de chemins
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "fs_guard.pbi"

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

Procedure CheckStartsWith(Actual.s, Prefix.s, Name.s)
  Check(Bool(Left(Actual, Len(Prefix)) = Prefix), Name)
EndProcedure

If Not CheckRuntime()
  End 1
EndIf

Global Root.s = GetTemporaryDirectory() + "mcp_fs_guard_test_" + Str(Date()) + "_" + Str(Random(1000000))
Global Work.s = Root + FSSeparator() + "sous" + FSSeparator() + "dossier"
; CreateDirectory ne cree qu'un seul niveau a la fois : on descend progressivement.
CreateDirectory(Root)
CreateDirectory(Root + FSSeparator() + "sous")
CreateDirectory(Work)
Check(Bool(FileSize(Root) = -2), "racine temporaire creee")
Check(Bool(FileSize(Work) = -2), "sous-dossier cree")

Global Prepared.s = FSPrepareRoot(Root)
Check(Bool(Prepared <> ""), "racine absolue acceptee")
Check(Bool(FSIsLinkOrJunction(Prepared) = #False), "racine ordinaire non detectee comme lien")

Global Current.s = FSPrepareRoot("")
Check(Bool(Current <> ""), "racine vide remplacee par le repertoire courant")
Check(Bool(FileSize(Current) = -2), "repertoire courant existant")

Global Valid.s = FSValidatePath("sous" + FSSeparator() + ".." + FSSeparator() + "sous" + FSSeparator() + "dossier", Root)
CheckStartsWith(Valid, Prepared, "chemin normalise sous la racine")
Check(Bool(FSValidatePath(".." + FSSeparator() + "escape.txt", Root) = ""), "traversal parent refuse")
Check(Bool(FSValidatePath("sous" + FSSeparator() + ".." + FSSeparator() + ".." + FSSeparator() + "escape.txt", Root) = ""), "double traversal refuse")
Check(Bool(FSValidatePath(Prepared + FSSeparator() + "sous" + FSSeparator() + "dossier", Root) <> ""), "chemin absolu sous la racine accepte")
Check(Bool(FSValidatePath(Prepared + "_autre" + FSSeparator() + "x.txt", Root) = ""), "prefixe voisin refuse")

DeleteDirectory(Root, "", #PB_FileSystem_Recursive)

SendStderrLine("---")
SendStderrLine("test_fs_guard : " + Str(G_Passed) + " reussis, " + Str(G_Failed) + " echoues")
If G_Failed > 0
  End 1
EndIf
