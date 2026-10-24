; ============================================================================
;  test_memory.pb - Tests unitaires du serveur Memory (Phase 1)
;  T1.1 - T1.18 du plan : couvre les 9 outils, la cascade, la recherche,
;  l'echappement SQL et les contenus longs.
; ============================================================================
;  La base est recreee a chaque run (fichier temporaire supprime a la fin).
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../src/memory_core.pbi"
IncludeFile "unit_test.pbi"

Global G_TestDB.s

; Ouvre les arguments d'un appel d'outil a partir d'un JSON literal
Procedure.i ArgsFrom(JsonLiteral.s)
  Protected J.i = ParseJSON(#PB_Any, JsonLiteral)
  If J = 0
    SendStderrLine("[ERREUR] JSON de test invalide : " + JsonLiteral)
    End 2
  EndIf
  ; Le caller ne libere pas : fuite acceptable dans un processus de test court
  ProcedureReturn JSONValue(J)
EndProcedure

; Nombre d'entites dans le graphe complet
Procedure.i CountEntities()
  Protected J.i = ParseJSON(#PB_Any, ToolReadGraph())
  Protected Root.i = JSONValue(J)
  Protected Arr.i = GetJSONMember(Root, "entities")
  Protected n.i = JSONArraySize(Arr)
  FreeJSON(J)
  ProcedureReturn n
EndProcedure

Procedure.i CountRelations()
  Protected J.i = ParseJSON(#PB_Any, ToolReadGraph())
  Protected Root.i = JSONValue(J)
  Protected Arr.i = GetJSONMember(Root, "relations")
  Protected n.i = JSONArraySize(Arr)
  FreeJSON(J)
  ProcedureReturn n
EndProcedure

; Le graphe JSON contient-il une entite de ce nom ?
Procedure.i GraphHasEntity(Name.s)
  Protected J.i = ParseJSON(#PB_Any, ToolReadGraph())
  Protected Root.i = JSONValue(J)
  Protected Arr.i = GetJSONMember(Root, "entities")
  Protected Found.i = #False
  Protected i.i
  For i = 0 To JSONArraySize(Arr) - 1
    Protected Ent.i = GetJSONElement(Arr, i)
    If GetArgString(Ent, "name") = Name
      Found = #True
      Break
    EndIf
  Next
  FreeJSON(J)
  ProcedureReturn Found
EndProcedure

; Nombre d'observations d'une entite (via open_nodes)
Procedure.i CountObservations(Name.s)
  Protected Out.s = ToolOpenNodes(ArgsFrom(~"{\"names\":[\"" + Name + ~"\"]}"))
  Protected J.i = ParseJSON(#PB_Any, Out)
  Protected Root.i = JSONValue(J)
  Protected Arr.i = GetJSONMember(Root, "entities")
  Protected Result.i = -1
  If JSONArraySize(Arr) > 0
    Protected Ent.i = GetJSONElement(Arr, 0)
    Protected Obs.i = GetJSONMember(Ent, "observations")
    Result = JSONArraySize(Obs)
  EndIf
  FreeJSON(J)
  ProcedureReturn Result
EndProcedure

; ===========================================================================
; T1.1 - T1.4 : creation d'entites
; ===========================================================================
Procedure Test_CreateEntities()
  SendStderrLine("--- T1.1-T1.4 create_entities ---")

  Protected Out.s = ToolCreateEntities(ArgsFrom(~"{\"entities\":[{\"name\":\"Alice\",\"entityType\":\"person\",\"observations\":[\"aime le cafe\"]}]}"))
  UTAssertContains(Out, "1 observations", "T1.1 creation simple (1 entite, 1 observation)")
  UTAssert(1, CountEntities(), "T1.1 graphe = 1 entite")

  Out = ToolCreateEntities(ArgsFrom(~"{\"entities\":[{\"name\":\"Bob\",\"entityType\":\"person\"},{\"name\":\"Charlie\",\"entityType\":\"person\"},{\"name\":\"Dora\",\"entityType\":\"lieu\"}]}"))
  UTAssertContains(Out, "3", "T1.2 creation multiple (3 entites)")
  UTAssert(4, CountEntities(), "T1.2 graphe = 4 entites")

  Out = ToolCreateEntities(ArgsFrom(~"{\"entities\":[{\"name\":\"Alice\",\"entityType\":\"person\"}]}"))
  UTAssert(4, CountEntities(), "T1.3 doublon ignore (toujours 4 entites)")

  Out = ToolCreateEntities(ArgsFrom(~"{\"entities\":[{\"name\":\"\",\"entityType\":\"person\"}]}"))
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T1.4 nom vide -> erreur")
  UTAssert(4, CountEntities(), "T1.4 nom vide -> 0 entite creee")
EndProcedure

; ===========================================================================
; T1.5 - T1.6 : relations
; ===========================================================================
Procedure Test_CreateRelations()
  SendStderrLine("--- T1.5-T1.6 create_relations ---")

  Protected Out.s = ToolCreateRelations(ArgsFrom(~"{\"relations\":[{\"from\":\"Alice\",\"to\":\"Bob\",\"relationType\":\"connait\"}]}"))
  UTAssertContains(Out, "1", "T1.5 relation valide creee")
  UTAssert(1, CountRelations(), "T1.5 graphe = 1 relation")

  Out = ToolCreateRelations(ArgsFrom(~"{\"relations\":[{\"from\":\"Inconnu\",\"to\":\"Bob\",\"relationType\":\"connait\"}]}"))
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T1.6 entite inexistante -> erreur")
  UTAssert(1, CountRelations(), "T1.6 relation refusee (toujours 1)")
EndProcedure

; ===========================================================================
; T1.7 - T1.8 : observations
; ===========================================================================
Procedure Test_AddObservations()
  SendStderrLine("--- T1.7-T1.8 add_observations ---")

  Protected Out.s = ToolAddObservations(ArgsFrom(~"{\"observations\":[{\"entityName\":\"Alice\",\"contents\":[\"deuxieme observation\",\"troisieme observation\"]}]}"))
  UTAssertContains(Out, "2", "T1.7 ajout de 2 observations")
  UTAssert(3, CountObservations("Alice"), "T1.7 Alice a maintenant 3 observations")

  Out = ToolAddObservations(ArgsFrom(~"{\"observations\":[{\"entityName\":\"Inconnu\",\"contents\":[\"x\"]}]}"))
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T1.8 observation sur entite inconnue -> erreur")
EndProcedure

; ===========================================================================
; T1.9 - T1.10 : suppressions
; ===========================================================================
Procedure Test_Deletions()
  SendStderrLine("--- T1.9-T1.10 suppressions ---")

  ; T1.9 : cascade -> supprimer Alice efface ses observations et ses relations
  Protected Out.s = ToolDeleteEntities(ArgsFrom(~"{\"entityNames\":[\"Alice\"]}"))
  UTAssertContains(Out, "1", "T1.9 suppression d'Alice")
  UTAssert(0, Bool(GraphHasEntity("Alice")), "T1.9 Alice absente du graphe")
  UTAssert(0, CountRelations(), "T1.9 relation Alice->Bob supprimee en cascade")
  UTAssert(-1, CountObservations("Alice"), "T1.9 observations d'Alice en cascade")

  ; T1.10 : suppression partielle d'observation
  Out = ToolDeleteObservations(ArgsFrom(~"{\"observations\":[{\"entityName\":\"Bob\",\"contents\":[\"obs a garder\"]}]}"))
  ToolAddObservations(ArgsFrom(~"{\"observations\":[{\"entityName\":\"Bob\",\"contents\":[\"obs a garder\",\"obs a supprimer\"]}]}"))
  Out = ToolDeleteObservations(ArgsFrom(~"{\"observations\":[{\"entityName\":\"Bob\",\"contents\":[\"obs a supprimer\"]}]}"))
  UTAssertContains(Out, "1", "T1.10 1 observation supprimee")
  UTAssert(1, CountObservations("Bob"), "T1.10 1 observation restante")
EndProcedure

; ===========================================================================
; T1.11 - T1.13 : recherche
; ===========================================================================
Procedure Test_Search()
  SendStderrLine("--- T1.11-T1.13 search_nodes ---")

  ToolCreateEntities(ArgsFrom(~"{\"entities\":[{\"name\":\"Eve\",\"entityType\":\"person\",\"observations\":[\"collectionne les timbres\"]}]}"))

  Protected Out.s = ToolSearchNodes("eve")
  UTAssert(1, Bool(FindString(Out, "Eve") > 0), "T1.11 recherche par nom (insensible a la casse)")

  Out = ToolSearchNodes("timbres")
  UTAssert(1, Bool(FindString(Out, "Eve") > 0), "T1.12 recherche par contenu d'observation")

  Out = ToolSearchNodes("zzzzsansresultat")
  UTAssert(1, Bool(FindString(Out, ~"\"entities\":[]") > 0), "T1.13 recherche sans resultat -> liste vide")
EndProcedure

; ===========================================================================
; T1.14 - T1.15 : open_nodes
; ===========================================================================
Procedure Test_OpenNodes()
  SendStderrLine("--- T1.14-T1.15 open_nodes ---")

  Protected Out.s = ToolOpenNodes(ArgsFrom(~"{\"names\":[\"Bob\",\"Charlie\"]}"))
  UTAssert(1, Bool(FindString(Out, "Bob") > 0), "T1.14 Bob present")
  UTAssert(1, Bool(FindString(Out, "Charlie") > 0), "T1.14 Charlie present")

  Out = ToolOpenNodes(ArgsFrom(~"{\"names\":[\"Bob\",\"Fantome\"]}"))
  UTAssert(1, Bool(FindString(Out, "Bob") > 0), "T1.15 Bob present")
  Protected J.i = ParseJSON(#PB_Any, Out)
  Protected Root.i = JSONValue(J)
  Protected Arr.i = GetJSONMember(Root, "entities")
  UTAssert(1, JSONArraySize(Arr), "T1.15 seule l'entite existante est retournee")
  FreeJSON(J)
EndProcedure

; ===========================================================================
; T1.16 : read_graph coherent
; ===========================================================================
Procedure Test_ReadGraph()
  SendStderrLine("--- T1.16 read_graph ---")

  ToolCreateEntities(ArgsFrom(~"{\"entities\":[{\"name\":\"Fred\",\"entityType\":\"person\"}]}"))
  ToolCreateRelations(ArgsFrom(~"{\"relations\":[{\"from\":\"Fred\",\"to\":\"Bob\",\"relationType\":\"travaille_avec\"}]}"))
  Protected Out.s = ToolReadGraph()
  UTAssert(1, Bool(FindString(Out, "Fred") > 0), "T1.16 Fred dans le graphe")
  UTAssert(1, Bool(FindString(Out, "travaille_avec") > 0), "T1.16 relation presente")
EndProcedure

; ===========================================================================
; T1.17 - T1.18 : echappement SQL et contenus longs
; ===========================================================================
Procedure Test_SecurityAndLimits()
  SendStderrLine("--- T1.17-T1.18 securite et limites ---")

  ; Injection : le nom doit etre stocke tel quel, la table intacte
  Protected Evil.s = "Robert'); DROP TABLE entities;--"
  Protected Out.s = ToolCreateEntities(ArgsFrom(~"{\"entities\":[{\"name\":\"" + Evil + ~"\",\"entityType\":\"person\"}]}"))
  UTAssert(1, Bool(Left(Out, 6) <> "Erreur"), "T1.17 nom hostile accepte (echappe)")
  UTAssert(1, Bool(GraphHasEntity(Evil)), "T1.17 nom hostile stocke litteralement")
  Protected J.i = ParseJSON(#PB_Any, ToolReadGraph())
  UTAssert(1, Bool(J <> 0), "T1.17 table entities intacte (graphe lisible)")
  FreeJSON(J)

  ; Contenu long (100 Ko) : arguments construits par programme (evite un
  ; litteral JSON de 100 Ko a parser)
  Protected Big.s = ""
  Protected i.i
  For i = 1 To 1000
    Big + "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789" ; 100 x 1000 = 100 000 caracteres
  Next
  Protected BJ.i = CreateJSON(#PB_Any)
  Protected BRoot.i = SetJSONObject(JSONValue(BJ))
  Protected BArr.i = AddJSONMember(BRoot, "observations")
  SetJSONArray(BArr)
  Protected BObs.i = AddJSONElement(BArr)
  SetJSONObject(BObs)
  SetJSONString(AddJSONMember(BObs, "entityName"), "Bob")
  Protected BCont.i = AddJSONMember(BObs, "contents")
  SetJSONArray(BCont)
  SetJSONString(AddJSONElement(BCont), Big)
  Out = ToolAddObservations(JSONValue(BJ))
  FreeJSON(BJ)
  UTAssert(1, Bool(CountObservations("Bob") >= 2), "T1.18 contenu long ajoute")
EndProcedure

; ===========================================================================
; Programme principal
; ===========================================================================
If Not CheckRuntime()
  End 1
EndIf

; Base temporaire recreee a chaque run (nom unique par date + alea)
G_TestDB = GetTemporaryDirectory() + "mcp_memory_unittest_" + Str(Date()) + "_" + Str(Random(100000)) + ".db"

If FileSize(G_TestDB) >= 0 : DeleteFile(G_TestDB) : EndIf

If Not MemoryOpen(G_TestDB)
  SendStderrLine("[ERREUR] ouverture base de test : " + G_TestDB)
  End 2
EndIf
If Not MemoryInitSchema()
  SendStderrLine("[ERREUR] schema : " + DatabaseError())
  End 2
EndIf

Test_CreateEntities()
Test_CreateRelations()
Test_AddObservations()
Test_Deletions()
Test_Search()
Test_OpenNodes()
Test_ReadGraph()
Test_SecurityAndLimits()

MemoryClose()
DeleteFile(G_TestDB)

UTFinalize()

End
