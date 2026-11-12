; ============================================================================
;  memory_core.pbi - Coeur metier du serveur MCP Memory (graphe d'entites)
;  Persistance SQLite (bibliotheque integree PureBasic, aucune dependance).
;  Inclus par src/memoryMCP.pb (serveur) et tests/test_memory.pb (tests).
; ============================================================================
;  Schema (reference : serveur MCP "memory" officiel) :
;    entities(name, entityType)                    -- name = cle primaire
;    observations(id, entity_name -> FK CASCADE, content)
;    relations(id, from_entity -> FK CASCADE, to_entity -> FK CASCADE,
;              relation_type, UNIQUE(from,to,type))
; ============================================================================

Global G_MemDB.i = 0

; Bornes d'entrees (audit I5) : le serveur est mono-thread, un nom de
; plusieurs Mo ou un tableau de milliers d'elements pousserait memoire et
; CPU pour tous les clients. Le plafond du corps HTTP (1 Mio defaut) ne
; suffit pas si l'operateur l'elargit. #MEM_MAX_CONTENT laisse passer les
; contenus longs legitimes (le test unitaire T1.18 en valide un de 100 Ko)
; tout en bloquant l'abus a l'echelle du Mo.
#MEM_MAX_NAME = 256
#MEM_MAX_TYPE = 128
#MEM_MAX_CONTENT = 131072
#MEM_MAX_ITEMS = 100

; ---------------------------------------------------------------------------
; Couche d'acces SQLite
; ---------------------------------------------------------------------------

; Ouvre (ou cree) la base. Path.s = chemin du fichier SQLite.
; Le fichier doit exister avant OpenDatabase : on le cree vide si besoin.
Procedure.i MemoryOpen(Path.s)
  UseSQLiteDatabase()
  If FileSize(Path) < 0
    Protected Tmp.i = CreateFile(#PB_Any, Path)
    If Tmp = 0 : ProcedureReturn #False : EndIf
    CloseFile(Tmp)
  EndIf
  Protected db.i = OpenDatabase(#PB_Any, Path, "", "")
  If db = 0
    ProcedureReturn #False
  EndIf
  G_MemDB = db
  ; Activer les cles etrangeres (cascades de suppression) sur cette connexion
  DatabaseUpdate(G_MemDB, "PRAGMA foreign_keys = ON")
  ProcedureReturn #True
EndProcedure

; Cree le schema si necessaire.
Procedure.i MemoryInitSchema()
  If G_MemDB = 0 : ProcedureReturn #False : EndIf
  If DatabaseUpdate(G_MemDB, "CREATE TABLE IF NOT EXISTS entities (name TEXT PRIMARY KEY, entityType TEXT NOT NULL DEFAULT '', created_at DATETIME DEFAULT CURRENT_TIMESTAMP)") = 0 And DatabaseError() <> ""
    ProcedureReturn #False
  EndIf
  If DatabaseUpdate(G_MemDB, "CREATE TABLE IF NOT EXISTS observations (id INTEGER PRIMARY KEY AUTOINCREMENT, entity_name TEXT NOT NULL REFERENCES entities(name) ON DELETE CASCADE, content TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)") = 0 And DatabaseError() <> ""
    ProcedureReturn #False
  EndIf
  If DatabaseUpdate(G_MemDB, "CREATE TABLE IF NOT EXISTS relations (id INTEGER PRIMARY KEY AUTOINCREMENT, from_entity TEXT NOT NULL REFERENCES entities(name) ON DELETE CASCADE, to_entity TEXT NOT NULL REFERENCES entities(name) ON DELETE CASCADE, relation_type TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE(from_entity, to_entity, relation_type))") = 0 And DatabaseError() <> ""
    ProcedureReturn #False
  EndIf
  ProcedureReturn #True
EndProcedure

Procedure MemoryClose()
  If G_MemDB
    CloseDatabase(G_MemDB)
    G_MemDB = 0
  EndIf
EndProcedure

; Echappe une chaine pour inclusion dans une requete SQL (double les ')
Procedure.s SqlQuote(S.s)
  ProcedureReturn "'" + ReplaceString(S, "'", "''") + "'"
EndProcedure

; Echappe les jokers LIKE (audit I4) : % et _ sont des jokers, \ est
; l'echappement declare via ESCAPE '\' dans la requete. Sinon "%%%" forcerait
; un scan complet (DoS CPU sur le mono-thread) et "a_b" matcherait "aXb".
Procedure.s LikeEscape(S.s)
  S = ReplaceString(S, "\", "\\")
  S = ReplaceString(S, "%", "\%")
  S = ReplaceString(S, "_", "\_")
  ProcedureReturn S
EndProcedure

Procedure.i EntityExists(Name.s)
  Protected Found.i = #False
  If DatabaseQuery(G_MemDB, "SELECT 1 FROM entities WHERE name=" + SqlQuote(Name))
    If NextDatabaseRow(G_MemDB) : Found = #True : EndIf
    FinishDatabaseQuery(G_MemDB)
  EndIf
  ProcedureReturn Found
EndProcedure

Procedure.i RelationExists(From.s, Dest.s, RelType.s)
  Protected Found.i = #False
  If DatabaseQuery(G_MemDB, "SELECT 1 FROM relations WHERE from_entity=" + SqlQuote(From) + " AND to_entity=" + SqlQuote(Dest) + " AND relation_type=" + SqlQuote(RelType))
    If NextDatabaseRow(G_MemDB) : Found = #True : EndIf
    FinishDatabaseQuery(G_MemDB)
  EndIf
  ProcedureReturn Found
EndProcedure

; ---------------------------------------------------------------------------
; Constructeurs JSON internes
; ---------------------------------------------------------------------------

; Ajoute au tableau EntitiesArr l'entite Name avec ses observations.
Procedure BuildEntityJSON(EntitiesArr.i, Name.s, EntityType.s)
  Protected EntObj.i = AddJSONElement(EntitiesArr)
  SetJSONObject(EntObj)
  SetJSONString(AddJSONMember(EntObj, "name"), Name)
  SetJSONString(AddJSONMember(EntObj, "entityType"), EntityType)

  Protected ObsArr.i = AddJSONMember(EntObj, "observations")
  SetJSONArray(ObsArr)
  If DatabaseQuery(G_MemDB, "SELECT content FROM observations WHERE entity_name=" + SqlQuote(Name) + " ORDER BY id")
    While NextDatabaseRow(G_MemDB)
      SetJSONString(AddJSONElement(ObsArr), GetDatabaseString(G_MemDB, 0))
    Wend
    FinishDatabaseQuery(G_MemDB)
  EndIf
EndProcedure

; Construit {"entities": [...], "relations": [...]} pour une liste de noms.
; Relations retournees : celles dont from ET to sont dans la liste.
Procedure.s BuildGraphJSON(List Names.s())
  Protected J.i = CreateJSON(#PB_Any)
  Protected Root.i = SetJSONObject(JSONValue(J))
  Protected EntitiesArr.i = AddJSONMember(Root, "entities")
  SetJSONArray(EntitiesArr)
  Protected RelationsArr.i = AddJSONMember(Root, "relations")
  SetJSONArray(RelationsArr)

  ; Entites (typee via la table entities)
  ForEach Names()
    If DatabaseQuery(G_MemDB, "SELECT name, entityType FROM entities WHERE name=" + SqlQuote(Names()))
      If NextDatabaseRow(G_MemDB)
        BuildEntityJSON(EntitiesArr, GetDatabaseString(G_MemDB, 0), GetDatabaseString(G_MemDB, 1))
      EndIf
      FinishDatabaseQuery(G_MemDB)
    EndIf
  Next

  ; Relations internes a la liste. La membership est testee via une map :
  ; un ForEach interne deplacerait le curseur du ForEach externe (boucle
  ; infinie), d'ou la map de noms.
  NewMap NameSet.i()
  ForEach Names()
    If Not FindMapElement(NameSet(), Names())
      AddMapElement(NameSet(), Names())
    EndIf
    NameSet() = 1
  Next

  ForEach Names()
    Protected FromName.s = Names()
    If DatabaseQuery(G_MemDB, "SELECT from_entity, to_entity, relation_type FROM relations WHERE from_entity=" + SqlQuote(FromName))
      While NextDatabaseRow(G_MemDB)
        Protected ToName.s = GetDatabaseString(G_MemDB, 1)
        If FindMapElement(NameSet(), ToName)
          Protected RelObj.i = AddJSONElement(RelationsArr)
          SetJSONObject(RelObj)
          SetJSONString(AddJSONMember(RelObj, "from"), FromName)
          SetJSONString(AddJSONMember(RelObj, "to"), ToName)
          SetJSONString(AddJSONMember(RelObj, "relationType"), GetDatabaseString(G_MemDB, 2))
        EndIf
      Wend
      FinishDatabaseQuery(G_MemDB)
    EndIf
  Next

  Protected Out.s = ComposeJSON(J)
  FreeJSON(J)
  ProcedureReturn Out
EndProcedure

; ---------------------------------------------------------------------------
; Outils MCP
; ---------------------------------------------------------------------------

; create_entities : entities[] = [{name, entityType, observations[]}]
Procedure.s ToolCreateEntities(ArgsObj.i)
  Protected Arr.i = GetArgArray(ArgsObj, "entities")
  If Arr = 0 Or JSONType(Arr) <> #PB_JSON_Array
    ProcedureReturn "Erreur : 'entities' doit etre un tableau."
  EndIf

  Protected n.i = JSONArraySize(Arr), i.i
  If n > #MEM_MAX_ITEMS
    ProcedureReturn "Erreur : 'entities' depasse " + Str(#MEM_MAX_ITEMS) + " elements par appel."
  EndIf
  Protected Created.i = 0, ObsCreated.i = 0

  ; Une seule transaction : 100 entites passent de ~900 ms a quelques ms
  If DatabaseUpdate(G_MemDB, "BEGIN TRANSACTION") = 0 And DatabaseError() <> ""
    ProcedureReturn "Erreur SQLite : " + DatabaseError()
  EndIf

  For i = 0 To n - 1
    Protected Item.i = GetJSONElement(Arr, i)
    If JSONType(Item) <> #PB_JSON_Object
      DatabaseUpdate(G_MemDB, "ROLLBACK")
      ProcedureReturn "Erreur : chaque entite doit etre un objet {name, entityType, observations}."
    EndIf
    Protected Name.s = GetArgString(Item, "name")
    If Trim(Name) = ""
      DatabaseUpdate(G_MemDB, "ROLLBACK")
      ProcedureReturn "Erreur : 'name' ne peut pas etre vide. " + Str(Created) + " entite(s) creee(s) avant l'echec."
    EndIf
    If Len(Name) > #MEM_MAX_NAME
      DatabaseUpdate(G_MemDB, "ROLLBACK")
      ProcedureReturn "Erreur : 'name' depasse " + Str(#MEM_MAX_NAME) + " caracteres."
    EndIf
    Protected EType.s = GetArgString(Item, "entityType")
    If EType = "" : EType = "unknown" : EndIf
    If Len(EType) > #MEM_MAX_TYPE
      DatabaseUpdate(G_MemDB, "ROLLBACK")
      ProcedureReturn "Erreur : 'entityType' depasse " + Str(#MEM_MAX_TYPE) + " caracteres."
    EndIf

    ; INSERT OR IGNORE : doublon -> pas d'erreur, pas de duplication
    DatabaseUpdate(G_MemDB, "INSERT OR IGNORE INTO entities (name, entityType) VALUES (" + SqlQuote(Name) + ", " + SqlQuote(EType) + ")")
    If DatabaseError() <> ""
      DatabaseUpdate(G_MemDB, "ROLLBACK")
      ProcedureReturn "Erreur SQLite : " + DatabaseError()
    EndIf
    If DatabaseUpdate(G_MemDB, "UPDATE entities SET entityType=" + SqlQuote(EType) + " WHERE name=" + SqlQuote(Name)) >= 0
      Created + 1
    EndIf

    ; Observations de l'entite
    Protected ObsArr.i = GetArgArray(Item, "observations")
    If ObsArr And JSONType(ObsArr) = #PB_JSON_Array
      Protected j.i, m.i = JSONArraySize(ObsArr)
      If m > #MEM_MAX_ITEMS
        DatabaseUpdate(G_MemDB, "ROLLBACK")
        ProcedureReturn "Erreur : 'observations' depasse " + Str(#MEM_MAX_ITEMS) + " elements par entite."
      EndIf
      For j = 0 To m - 1
        Protected OVal.i = GetJSONElement(ObsArr, j)
        If JSONType(OVal) = #PB_JSON_String
          If Len(GetJSONString(OVal)) > #MEM_MAX_CONTENT
            DatabaseUpdate(G_MemDB, "ROLLBACK")
            ProcedureReturn "Erreur : observation depasse " + Str(#MEM_MAX_CONTENT) + " caracteres."
          EndIf
          DatabaseUpdate(G_MemDB, "INSERT INTO observations (entity_name, content) VALUES (" + SqlQuote(Name) + ", " + SqlQuote(GetJSONString(OVal)) + ")")
          If DatabaseError() = ""
            ObsCreated + 1
          EndIf
        EndIf
      Next
    EndIf
  Next

  DatabaseUpdate(G_MemDB, "COMMIT")
  ProcedureReturn "Entites enregistrees : " + Str(Created) + " (" + Str(ObsCreated) + " observations)."
EndProcedure

; create_relations : relations[] = [{from, to, relationType}]
Procedure.s ToolCreateRelations(ArgsObj.i)
  Protected Arr.i = GetArgArray(ArgsObj, "relations")
  If Arr = 0 Or JSONType(Arr) <> #PB_JSON_Array
    ProcedureReturn "Erreur : 'relations' doit etre un tableau."
  EndIf

  Protected n.i = JSONArraySize(Arr), i.i, Created.i = 0
  If n > #MEM_MAX_ITEMS
    ProcedureReturn "Erreur : 'relations' depasse " + Str(#MEM_MAX_ITEMS) + " elements par appel."
  EndIf
  For i = 0 To n - 1
    Protected Item.i = GetJSONElement(Arr, i)
    If JSONType(Item) <> #PB_JSON_Object
      ProcedureReturn "Erreur : chaque relation doit etre un objet {from, to, relationType}."
    EndIf
    Protected From.s = GetArgString(Item, "from")
    Protected Dest.s = GetArgString(Item, "to")
    Protected RelType.s = GetArgString(Item, "relationType")
    If From = "" Or Dest = "" Or RelType = ""
      ProcedureReturn "Erreur : 'from', 'to' et 'relationType' sont requis."
    EndIf
    If Len(From) > #MEM_MAX_NAME Or Len(Dest) > #MEM_MAX_NAME Or Len(RelType) > #MEM_MAX_NAME
      ProcedureReturn "Erreur : champs de relation limites a " + Str(#MEM_MAX_NAME) + " caracteres."
    EndIf
    ; Integrite referentielle explicite (message clair au lieu d'une erreur FK)
    If Not EntityExists(From)
      ProcedureReturn "Erreur : entite inconnue '" + From + "'. Relation non creee."
    EndIf
    If Not EntityExists(Dest)
      ProcedureReturn "Erreur : entite inconnue '" + Dest + "'. Relation non creee."
    EndIf
    DatabaseUpdate(G_MemDB, "INSERT OR IGNORE INTO relations (from_entity, to_entity, relation_type) VALUES (" + SqlQuote(From) + ", " + SqlQuote(Dest) + ", " + SqlQuote(RelType) + ")")
    If DatabaseError() <> ""
      ProcedureReturn "Erreur SQLite : " + DatabaseError()
    EndIf
    Created + 1
  Next

  ProcedureReturn "Relations enregistrees : " + Str(Created) + "."
EndProcedure

; add_observations : observations[] = [{entityName, contents[]}]
Procedure.s ToolAddObservations(ArgsObj.i)
  Protected Arr.i = GetArgArray(ArgsObj, "observations")
  If Arr = 0 Or JSONType(Arr) <> #PB_JSON_Array
    ProcedureReturn "Erreur : 'observations' doit etre un tableau."
  EndIf

  Protected n.i = JSONArraySize(Arr), i.i, Added.i = 0
  If n > #MEM_MAX_ITEMS
    ProcedureReturn "Erreur : 'observations' depasse " + Str(#MEM_MAX_ITEMS) + " elements par appel."
  EndIf
  For i = 0 To n - 1
    Protected Item.i = GetJSONElement(Arr, i)
    If JSONType(Item) <> #PB_JSON_Object
      ProcedureReturn "Erreur : chaque observation doit etre un objet {entityName, contents}."
    EndIf
    Protected Name.s = GetArgString(Item, "entityName")
    If Not EntityExists(Name)
      ProcedureReturn "Erreur : entite inconnue '" + Name + "'. Observation non ajoutee."
    EndIf
    Protected Contents.i = GetArgArray(Item, "contents")
    If Contents And JSONType(Contents) = #PB_JSON_Array
      Protected j.i, m.i = JSONArraySize(Contents)
      If m > #MEM_MAX_ITEMS
        ProcedureReturn "Erreur : 'contents' depasse " + Str(#MEM_MAX_ITEMS) + " elements par entite."
      EndIf
      For j = 0 To m - 1
        Protected CVal.i = GetJSONElement(Contents, j)
        If JSONType(CVal) = #PB_JSON_String
          If Len(GetJSONString(CVal)) > #MEM_MAX_CONTENT
            ProcedureReturn "Erreur : observation depasse " + Str(#MEM_MAX_CONTENT) + " caracteres."
          EndIf
          DatabaseUpdate(G_MemDB, "INSERT INTO observations (entity_name, content) VALUES (" + SqlQuote(Name) + ", " + SqlQuote(GetJSONString(CVal)) + ")")
          If DatabaseError() = ""
            Added + 1
          EndIf
        EndIf
      Next
    EndIf
  Next

  ProcedureReturn "Observations ajoutees : " + Str(Added) + "."
EndProcedure

; delete_entities : entityNames[] (cascade sur observations + relations)
Procedure.s ToolDeleteEntities(ArgsObj.i)
  Protected Arr.i = GetArgArray(ArgsObj, "entityNames")
  If Arr = 0 Or JSONType(Arr) <> #PB_JSON_Array
    ProcedureReturn "Erreur : 'entityNames' doit etre un tableau."
  EndIf

  Protected n.i = JSONArraySize(Arr), i.i, Deleted.i = 0
  For i = 0 To n - 1
    Protected Val.i = GetJSONElement(Arr, i)
    If JSONType(Val) = #PB_JSON_String
      DatabaseUpdate(G_MemDB, "DELETE FROM entities WHERE name=" + SqlQuote(GetJSONString(Val)))
      If DatabaseError() = ""
        Deleted + 1
      EndIf
    EndIf
  Next

  ProcedureReturn "Entites supprimees : " + Str(Deleted) + " (observations et relations en cascade)."
EndProcedure

; delete_observations : observations[] = [{entityName, contents[]}]
Procedure.s ToolDeleteObservations(ArgsObj.i)
  Protected Arr.i = GetArgArray(ArgsObj, "observations")
  If Arr = 0 Or JSONType(Arr) <> #PB_JSON_Array
    ProcedureReturn "Erreur : 'observations' doit etre un tableau."
  EndIf

  Protected n.i = JSONArraySize(Arr), i.i, Deleted.i = 0
  For i = 0 To n - 1
    Protected Item.i = GetJSONElement(Arr, i)
    If JSONType(Item) <> #PB_JSON_Object
      ProcedureReturn "Erreur : chaque observation doit etre un objet {entityName, contents}."
    EndIf
    Protected Name.s = GetArgString(Item, "entityName")
    Protected Contents.i = GetArgArray(Item, "contents")
    If Contents And JSONType(Contents) = #PB_JSON_Array
      Protected j.i, m.i = JSONArraySize(Contents)
      For j = 0 To m - 1
        Protected CVal.i = GetJSONElement(Contents, j)
        If JSONType(CVal) = #PB_JSON_String
          DatabaseUpdate(G_MemDB, "DELETE FROM observations WHERE entity_name=" + SqlQuote(Name) + " AND content=" + SqlQuote(GetJSONString(CVal)))
          If DatabaseError() = ""
            Deleted + 1
          EndIf
        EndIf
      Next
    EndIf
  Next

  ProcedureReturn "Observations supprimees : " + Str(Deleted) + "."
EndProcedure

; delete_relations : relations[] = [{from, to, relationType}]
Procedure.s ToolDeleteRelations(ArgsObj.i)
  Protected Arr.i = GetArgArray(ArgsObj, "relations")
  If Arr = 0 Or JSONType(Arr) <> #PB_JSON_Array
    ProcedureReturn "Erreur : 'relations' doit etre un tableau."
  EndIf

  Protected n.i = JSONArraySize(Arr), i.i, Deleted.i = 0
  For i = 0 To n - 1
    Protected Item.i = GetJSONElement(Arr, i)
    If JSONType(Item) <> #PB_JSON_Object
      ProcedureReturn "Erreur : chaque relation doit etre un objet {from, to, relationType}."
    EndIf
    Protected From.s = GetArgString(Item, "from")
    Protected Dest.s = GetArgString(Item, "to")
    Protected RelType.s = GetArgString(Item, "relationType")
    DatabaseUpdate(G_MemDB, "DELETE FROM relations WHERE from_entity=" + SqlQuote(From) + " AND to_entity=" + SqlQuote(Dest) + " AND relation_type=" + SqlQuote(RelType))
    If DatabaseError() = ""
      Deleted + 1
    EndIf
  Next

  ProcedureReturn "Relations supprimees : " + Str(Deleted) + "."
EndProcedure

; read_graph : tout le graphe
Procedure.s ToolReadGraph()
  NewList Names.s()
  If DatabaseQuery(G_MemDB, "SELECT name FROM entities ORDER BY name")
    While NextDatabaseRow(G_MemDB)
      AddElement(Names())
      Names() = GetDatabaseString(G_MemDB, 0)
    Wend
    FinishDatabaseQuery(G_MemDB)
  EndIf
  ProcedureReturn BuildGraphJSON(Names())
EndProcedure

; search_nodes : query (LIKE insensible a la casse sur nom/type/contenu,
; jokers % et _ echappes, borne de taille)
Procedure.s ToolSearchNodes(Query.s)
  If Trim(Query) = ""
    ProcedureReturn "Erreur : 'query' ne peut pas etre vide."
  EndIf
  If Len(Query) > #MEM_MAX_NAME
    ProcedureReturn "Erreur : 'query' depasse " + Str(#MEM_MAX_NAME) + " caracteres."
  EndIf
  Protected LikeExpr.s = "'%" + LikeEscape(Query) + "%' ESCAPE " + SqlQuote("\")

  NewList Names.s()
  Protected SQL.s = "SELECT DISTINCT e.name FROM entities e LEFT JOIN observations o ON o.entity_name = e.name " +
                    "WHERE e.name LIKE " + LikeExpr + " OR e.entityType LIKE " + LikeExpr + " OR o.content LIKE " + LikeExpr + " ORDER BY e.name"
  If DatabaseQuery(G_MemDB, SQL)
    While NextDatabaseRow(G_MemDB)
      AddElement(Names())
      Names() = GetDatabaseString(G_MemDB, 0)
    Wend
    FinishDatabaseQuery(G_MemDB)
  EndIf
  ProcedureReturn BuildGraphJSON(Names())
EndProcedure

; open_nodes : names[] -> entites + relations internes
Procedure.s ToolOpenNodes(ArgsObj.i)
  Protected Arr.i = GetArgArray(ArgsObj, "names")
  If Arr = 0 Or JSONType(Arr) <> #PB_JSON_Array
    ProcedureReturn "Erreur : 'names' doit etre un tableau."
  EndIf

  NewList Names.s()
  Protected n.i = JSONArraySize(Arr), i.i
  For i = 0 To n - 1
    Protected Val.i = GetJSONElement(Arr, i)
    If JSONType(Val) = #PB_JSON_String
      AddElement(Names())
      Names() = GetJSONString(Val)
    EndIf
  Next
  ProcedureReturn BuildGraphJSON(Names())
EndProcedure

; ---------------------------------------------------------------------------
; Catalogue MCP
; ---------------------------------------------------------------------------
Procedure.i MemoryBuildCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "create_entities", "Cree des entites avec leurs observations (doublons ignores).", "entities|array|Liste d'entites {name, entityType, observations[]}", "entities")
  ToolDef(ToolsArr, "create_relations", "Cree des relations entre entites existantes.", "relations|array|Liste de relations {from, to, relationType}", "relations")
  ToolDef(ToolsArr, "add_observations", "Ajoute des observations a des entites existantes.", "observations|array|Liste {entityName, contents[]}", "observations")
  ToolDef(ToolsArr, "delete_entities", "Supprime des entites (observations et relations en cascade).", "entityNames|array|Noms des entites a supprimer", "entityNames")
  ToolDef(ToolsArr, "delete_observations", "Supprime des observations precises.", "observations|array|Liste {entityName, contents[]}", "observations")
  ToolDef(ToolsArr, "delete_relations", "Supprime des relations precises.", "relations|array|Liste {from, to, relationType}", "relations")
  ToolDef(ToolsArr, "read_graph", "Retourne tout le graphe (entites + relations) en JSON.", "", "")
  ToolDef(ToolsArr, "search_nodes", "Recherche insensible a la casse sur nom, type et observations.", "query|string|Texte recherche", "query")
  ToolDef(ToolsArr, "open_nodes", "Retourne des entites par nom, avec relations internes.", "names|array|Noms des entites a ouvrir", "names")

  ProcedureReturn RootJSON
EndProcedure

; ---------------------------------------------------------------------------
; Dispatch des outils (hook *G_ToolHandler)
; ---------------------------------------------------------------------------
Procedure.s MemoryDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Select ToolName
    Case "create_entities"
      ProcedureReturn ToolCreateEntities(ArgsObj)
    Case "create_relations"
      ProcedureReturn ToolCreateRelations(ArgsObj)
    Case "add_observations"
      ProcedureReturn ToolAddObservations(ArgsObj)
    Case "delete_entities"
      ProcedureReturn ToolDeleteEntities(ArgsObj)
    Case "delete_observations"
      ProcedureReturn ToolDeleteObservations(ArgsObj)
    Case "delete_relations"
      ProcedureReturn ToolDeleteRelations(ArgsObj)
    Case "read_graph"
      ProcedureReturn ToolReadGraph()
    Case "search_nodes"
      ProcedureReturn ToolSearchNodes(GetArgString(ArgsObj, "query"))
    Case "open_nodes"
      ProcedureReturn ToolOpenNodes(ArgsObj)
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure
