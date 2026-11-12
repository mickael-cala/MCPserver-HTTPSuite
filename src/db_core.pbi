; ============================================================================
;  db_core.pbi - Coeur metier du serveur MCP Database (SQLite + PostgreSQL)
;  Inclus par src/dbMCP.pb (serveur) et tests/test_database.pb (tests).
; ============================================================================
;  Deux connexions simultanees :
;    * SQLite     : toujours active (chemin MCP_DB_PATH, defaut "database.db")
;    * PostgreSQL : optionnelle (MCP_DB_POSTGRES_DSN = chaine de connexion
;                   libpq, ex. "host=localhost port=5432 dbname=test")
;  Chaque outil prend un parametre "engine" ("sqlite" par defaut,
;  "postgres" si la connexion est configuree).
; ============================================================================

Global G_DBSQLite.i = 0
Global G_DBPostgres.i = 0
Global G_DBPG_DSN.s = ""
Global G_DBAllowWrite.i = #False
#DB_MAX_ROWS = 1000

; ---------------------------------------------------------------------------
; Connexions
; ---------------------------------------------------------------------------

Procedure.i DbOpenSQLite(Path.s)
  UseSQLiteDatabase()
  If FileSize(Path) < 0
    Protected Tmp.i = CreateFile(#PB_Any, Path)
    If Tmp = 0 : ProcedureReturn #False : EndIf
    CloseFile(Tmp)
  EndIf
  G_DBSQLite = OpenDatabase(#PB_Any, Path, "", "")
  If G_DBSQLite = 0 : ProcedureReturn #False : EndIf
  ; Defense en profondeur : lecture seule appliquee par le moteur quand
  ; MCP_DB_ALLOW_WRITE n'est pas actif (l'application refuse PRAGMA et les
  ; multi-statements, donc le client ne peut pas la lever).
  If Not G_DBAllowWrite
    If Not DatabaseQuery(G_DBSQLite, "PRAGMA query_only = 1")
      LogError("Impossible de forcer la lecture seule SQLite (PRAGMA query_only).")
      CloseDatabase(G_DBSQLite) : G_DBSQLite = 0
      ProcedureReturn #False
    EndIf
    FinishDatabaseQuery(G_DBSQLite)
  EndIf
  ProcedureReturn #True
EndProcedure

Procedure.i DbOpenPostgres(DSN.s)
  UsePostgreSQLDatabase()
  ; statement_timeout 30 s a la connexion (plancher de securite)
  If FindString(DSN, "statement_timeout") = 0
    DSN + " options='-c statement_timeout=30000'"
  EndIf
  G_DBPostgres = OpenDatabase(#PB_Any, DSN, "", "")
  If G_DBPostgres = 0
    ProcedureReturn #False
  EndIf
  ; Defense en profondeur : lecture seule appliquee par le moteur quand
  ; MCP_DB_ALLOW_WRITE n'est pas actif (l'application refuse SET/BEGIN et
  ; les multi-statements, donc le client ne peut pas la lever).
  If Not G_DBAllowWrite
    If Not DatabaseUpdate(G_DBPostgres, "SET default_transaction_read_only = on")
      LogError("Impossible de forcer la lecture seule PostgreSQL : " + DatabaseError())
      CloseDatabase(G_DBPostgres) : G_DBPostgres = 0
      ProcedureReturn #False
    EndIf
  EndIf
  G_DBPG_DSN = DSN
  ProcedureReturn #True
EndProcedure

Procedure DbClose()
  If G_DBSQLite : CloseDatabase(G_DBSQLite) : G_DBSQLite = 0 : EndIf
  If G_DBPostgres : CloseDatabase(G_DBPostgres) : G_DBPostgres = 0 : EndIf
EndProcedure

; ---------------------------------------------------------------------------
; Garde-fou lecture seule
; ---------------------------------------------------------------------------

; Normalise une requete (supprime les commentaires de tete) et verifie
; qu'elle est en lecture seule. Whitelist : SELECT / SHOW / DESCRIBE,
; et WITH uniquement si aucun mot-clef d'ecriture n'y figure.
; Notes :
;  - tout ';' est refuse (fail-closed) : PostgreSQL executerait les
;    requetes empilees ("SELECT 1; DROP TABLE x") ; SQLite n'en compile
;    qu'une, mais la divergence entre moteurs est inacceptable ;
;  - EXPLAIN est exclu de la whitelist : "EXPLAIN ANALYZE DELETE" execute
;    reellement le DML sur PostgreSQL. L'outil db_explain construit
;    lui-meme son EXPLAIN QUERY PLAN sur une requete deja validee.
; La lecture seule est aussi appliquee par le moteur (PRAGMA query_only /
; default_transaction_read_only, voir DbOpenSQLite/DbOpenPostgres) : meme
; un bug futur de ce garde applicatif ne permet plus d'ecrire.
Procedure.i IsReadOnlyQuery(Query.s)
  Protected Q.s = Trim(Query)
  If Q = "" : ProcedureReturn #False : EndIf

  ; Fail-closed : un point-virgule, meme dans un commentaire ou un
  ; littéral, rend la requete refusee (les consultations legitimes n'en
  ; ont pas besoin).
  If FindString(Q, ";") > 0 : ProcedureReturn #False : EndIf

  ; Supprimer les commentaires de debut (-- ligne, /* bloc */)
  While #True
    If Left(Q, 2) = "--"
      Protected P.i = FindString(Q, #LF$)
      If P = 0 : ProcedureReturn #False : EndIf   ; que des commentaires
      Q = Trim(Mid(Q, P + 1))
    ElseIf Left(Q, 2) = "/*"
      P = FindString(Q, "*/", 3)
      If P = 0 : ProcedureReturn #False : EndIf
      Q = Trim(Mid(Q, P + 2))
    Else
      Break
    EndIf
  Wend

  Protected U.s = UCase(Q)
  Protected FirstWord.s = Trim(StringField(U, 1, " "))
  Protected FirstChars.s = Left(U, 8)

  If FirstWord = "SELECT" Or FirstWord = "SHOW" Or FirstWord = "DESCRIBE"
    ProcedureReturn #True
  EndIf
  If FirstWord = "WITH"
    ; INTERSECT/EXCEPT reconduisent SELECT ; seuls les verbes d'ecriture
    ; doivent faire echouer la requete.
    If FindString(U, "INSERT") > 0 Or FindString(U, "UPDATE") > 0 Or FindString(U, "DELETE") > 0
      ProcedureReturn #False
    EndIf
    If FindString(U, "CREATE") > 0 Or FindString(U, "DROP") > 0 Or FindString(U, "ALTER") > 0
      ProcedureReturn #False
    EndIf
    If FindString(U, "TRUNCATE") > 0 Or FindString(U, "REPLACE") > 0 Or FindString(U, "MERGE") > 0
      ProcedureReturn #False
    EndIf
    If FindString(U, "GRANT") > 0 Or FindString(U, "REVOKE") > 0 Or FindString(U, "VACUUM") > 0
      ProcedureReturn #False
    EndIf
    If FindString(U, "PRAGMA") > 0 Or FindString(U, "ATTACH") > 0 Or FindString(U, "DETACH") > 0
      ProcedureReturn #False
    EndIf
    If FindString(U, "SELECT") > 0
      ProcedureReturn #True
    EndIf
  EndIf
  ProcedureReturn #False
EndProcedure

; ---------------------------------------------------------------------------
; Resolution d'engine + execution generique
; ---------------------------------------------------------------------------

; Retourne le handle de base pour "sqlite"/"postgres", ou 0 avec un message.
Procedure.i DbResolve(Engine.s, *Msg.String)
  Protected E.s = LCase(Trim(Engine))
  If E = "" : E = "sqlite" : EndIf
  If E = "sqlite"
    If G_DBSQLite = 0
      *Msg\s = "Erreur : connexion SQLite non configuree (MCP_DB_PATH)."
      ProcedureReturn 0
    EndIf
    ProcedureReturn G_DBSQLite
  EndIf
  If E = "postgres" Or E = "postgresql"
    If G_DBPostgres = 0
      *Msg\s = "Erreur : connexion PostgreSQL non configuree (MCP_DB_POSTGRES_DSN)."
      ProcedureReturn 0
    EndIf
    ProcedureReturn G_DBPostgres
  EndIf
  *Msg\s = "Erreur : engine inconnu '" + Engine + "' (attendu : sqlite ou postgres)."
  ProcedureReturn 0
EndProcedure

; Execute une requete de lecture et retourne un JSON texte :
;   {"columns": [...], "rows": [[...]], "rowCount": n, "truncated": bool}
Procedure.s DbRunQueryText(DB.i, Query.s)
  If Not DatabaseQuery(DB, Query)
    ProcedureReturn "Erreur SQL : " + DatabaseError()
  EndIf

  Protected J.i = CreateJSON(#PB_Any)
  Protected Root.i = SetJSONObject(JSONValue(J))
  Protected Cols.i = DatabaseColumns(DB)
  Protected ColArr.i = AddJSONMember(Root, "columns")
  SetJSONArray(ColArr)
  Protected c.i
  For c = 0 To Cols - 1
    SetJSONString(AddJSONElement(ColArr), DatabaseColumnName(DB, c))
  Next

  Protected RowArr.i = AddJSONMember(Root, "rows")
  SetJSONArray(RowArr)
  Protected Count.i = 0, Truncated.i = #False
  While NextDatabaseRow(DB)
    If Count >= #DB_MAX_ROWS
      Truncated = #True
      Break
    EndIf

    ; CheckDatabaseNull distingue un vrai NULL ; les requetes PRAGMA /
    ; EXPLAIN (colonnes sans type declare) retombent sur la representation
    ; texte via GetDatabaseString.
    Dim CellText.s(Cols - 1)
    Dim CellType.i(Cols - 1)
    For c = 0 To Cols - 1
      CellType(c) = DatabaseColumnType(DB, c)
      CellText(c) = GetDatabaseString(DB, c)
    Next

    Protected RowObj.i = AddJSONElement(RowArr)
    SetJSONArray(RowObj)
    For c = 0 To Cols - 1
      If CheckDatabaseNull(DB, c)
        SetJSONNull(AddJSONElement(RowObj))
      ElseIf CellType(c) = 1  ; entier long
        SetJSONInteger(AddJSONElement(RowObj), GetDatabaseLong(DB, c))
      ElseIf CellType(c) = 4  ; flottant
        SetJSONDouble(AddJSONElement(RowObj), GetDatabaseDouble(DB, c))
      Else
        SetJSONString(AddJSONElement(RowObj), CellText(c))
      EndIf
    Next
    Count + 1
  Wend
  FinishDatabaseQuery(DB)

  SetJSONInteger(AddJSONMember(Root, "rowCount"), Count)
  SetJSONBoolean(AddJSONMember(Root, "truncated"), Truncated)

  Protected Out.s = ComposeJSON(J)
  FreeJSON(J)
  ProcedureReturn Out
EndProcedure

; Execute une requete en respectant le garde-fou lecture seule.
Procedure.s DbExecuteGuarded(DB.i, Query.s)
  If Trim(Query) = ""
    ProcedureReturn "Erreur : requete vide."
  EndIf
  If Not G_DBAllowWrite And Not IsReadOnlyQuery(Query)
    LogError("Requete refusee (lecture seule) : " + Left(Query, 120))
    ProcedureReturn "Erreur : requete en ecriture refusee. Definir MCP_DB_ALLOW_WRITE=1 cote serveur pour l'autoriser."
  EndIf

  If IsReadOnlyQuery(Query)
    ProcedureReturn DbRunQueryText(DB, Query)
  EndIf

  ; Ecriture (autorisee par MCP_DB_ALLOW_WRITE)
  Protected Affected.i = DatabaseUpdate(DB, Query)
  If Affected = 0 And DatabaseError() <> ""
    ProcedureReturn "Erreur SQL : " + DatabaseError()
  EndIf
  ProcedureReturn "Requete executee avec succes (" + Str(Affected) + " ligne(s) affectee(s))."
EndProcedure

; ---------------------------------------------------------------------------
; Outils MCP
; ---------------------------------------------------------------------------

; Echappe une chaine pour SQL (double les ')
Procedure.s SqlQuoteDb(S.s)
  ProcedureReturn "'" + ReplaceString(S, "'", "''") + "'"
EndProcedure

; db_list_schemas
Procedure.s ToolDbListSchemas(Engine.s)
  Protected Msg.String\s
  Protected DB.i = DbResolve(Engine, @Msg)
  If DB = 0 : ProcedureReturn Msg\s : EndIf

  If DB = G_DBSQLite
    ProcedureReturn ~"[\"main\"]"
  EndIf
  ; PostgreSQL : information_schema.schemata
  ProcedureReturn DbRunQueryText(DB, "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name")
EndProcedure

; db_list_tables (Schema optionnel, PostgreSQL uniquement)
Procedure.s ToolDbListTables(Engine.s, Schema.s)
  Protected Msg.String\s
  Protected DB.i = DbResolve(Engine, @Msg)
  If DB = 0 : ProcedureReturn Msg\s : EndIf

  If DB = G_DBSQLite
    ProcedureReturn DbRunQueryText(DB, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
  EndIf
  If Schema = "" : Schema = "public" : EndIf
  ProcedureReturn DbRunQueryText(DB, "SELECT table_name FROM information_schema.tables WHERE table_schema=" + SqlQuoteDb(Schema) + " AND table_type='BASE TABLE' ORDER BY table_name")
EndProcedure

; db_describe_table
Procedure.s ToolDbDescribeTable(Engine.s, Table.s, Schema.s)
  If Trim(Table) = ""
    ProcedureReturn "Erreur : 'table' est requis."
  EndIf
  Protected Msg.String\s
  Protected DB.i = DbResolve(Engine, @Msg)
  If DB = 0 : ProcedureReturn Msg\s : EndIf

  If DB = G_DBSQLite
    ; PRAGMA table_info : cid, name, type, notnull, dflt_value, pk
    ProcedureReturn DbRunQueryText(DB, "PRAGMA table_info(" + SqlQuoteDb(Table) + ")")
  EndIf
  If Schema = "" : Schema = "public" : EndIf
  ProcedureReturn DbRunQueryText(DB,
    "SELECT column_name, data_type, is_nullable, column_default " +
    "FROM information_schema.columns WHERE table_schema=" + SqlQuoteDb(Schema) +
    " AND table_name=" + SqlQuoteDb(Table) + " ORDER BY ordinal_position")
EndProcedure

; db_execute_query
Procedure.s ToolDbExecuteQuery(Engine.s, Query.s)
  Protected Msg.String\s
  Protected DB.i = DbResolve(Engine, @Msg)
  If DB = 0 : ProcedureReturn Msg\s : EndIf
  ProcedureReturn DbExecuteGuarded(DB, Query)
EndProcedure

; db_explain
Procedure.s ToolDbExplain(Engine.s, Query.s)
  If Trim(Query) = ""
    ProcedureReturn "Erreur : requete vide."
  EndIf
  If Not IsReadOnlyQuery(Query)
    ProcedureReturn "Erreur : EXPLAIN est reserve aux requetes en lecture seule."
  EndIf
  Protected Msg.String\s
  Protected DB.i = DbResolve(Engine, @Msg)
  If DB = 0 : ProcedureReturn Msg\s : EndIf

  If DB = G_DBSQLite
    ProcedureReturn DbRunQueryText(DB, "EXPLAIN QUERY PLAN " + Query)
  EndIf
  ProcedureReturn DbRunQueryText(DB, "EXPLAIN (FORMAT TEXT) " + Query)
EndProcedure

; ---------------------------------------------------------------------------
; Catalogue MCP
; ---------------------------------------------------------------------------
Procedure.i DbBuildCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "db_list_schemas", "Liste les schemas (postgres) ou le schema principal (sqlite).", "engine|string|Moteur : sqlite (defaut) ou postgres", "")
  ToolDef(ToolsArr, "db_list_tables", "Liste les tables de la base / du schema.", "engine|string|Moteur;schema|string|Schema postgres (defaut: public)", "")
  ToolDef(ToolsArr, "db_describe_table", "Decrit les colonnes d'une table (PRAGMA / information_schema).", "table|string|Nom de la table;engine|string|Moteur;schema|string|Schema postgres (defaut: public)", "table")
  ToolDef(ToolsArr, "db_execute_query", "Execute une requete SQL. Lecture seule par defaut (MCP_DB_ALLOW_WRITE=1 pour ecrire). Resultat JSON limite a 1000 lignes.", "query|string|Requete SQL;engine|string|Moteur", "query")
  ToolDef(ToolsArr, "db_explain", "Plan d'execution (EXPLAIN QUERY PLAN / EXPLAIN).", "query|string|Requete SQL en lecture seule;engine|string|Moteur", "query")

  ProcedureReturn RootJSON
EndProcedure

; ---------------------------------------------------------------------------
; Dispatch des outils (hook *G_ToolHandler)
; ---------------------------------------------------------------------------
Procedure.s DbDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Protected Engine.s = GetArgString(ArgsObj, "engine")
  Select ToolName
    Case "db_list_schemas"
      ProcedureReturn ToolDbListSchemas(Engine)
    Case "db_list_tables"
      ProcedureReturn ToolDbListTables(Engine, GetArgString(ArgsObj, "schema"))
    Case "db_describe_table"
      ProcedureReturn ToolDbDescribeTable(Engine, GetArgString(ArgsObj, "table"), GetArgString(ArgsObj, "schema"))
    Case "db_execute_query"
      ProcedureReturn ToolDbExecuteQuery(Engine, GetArgString(ArgsObj, "query"))
    Case "db_explain"
      ProcedureReturn ToolDbExplain(Engine, GetArgString(ArgsObj, "query"))
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect
EndProcedure
