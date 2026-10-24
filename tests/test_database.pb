; ============================================================================
;  test_database.pb - Tests unitaires du serveur Database (Phase 2)
;  T2.1-T2.8 (SQLite) + batterie IsReadOnlyQuery. Les tests PostgreSQL
;  (T2.9-T2.12) sont des tests d'integration conditionnels (DSN requis).
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../src/db_core.pbi"
IncludeFile "unit_test.pbi"

Global G_TestDB.s

; ===========================================================================
; IsReadOnlyQuery (T2.5 cote pure + cas limites)
; ===========================================================================
Procedure Test_ReadOnlyGuard()
  SendStderrLine("--- IsReadOnlyQuery ---")

  UTAssert(1, IsReadOnlyQuery("SELECT 1"), "SELECT accepte")
  UTAssert(1, IsReadOnlyQuery("  select * from t"), "select minuscule accepte")
  UTAssert(1, IsReadOnlyQuery("WITH x AS (SELECT 1) SELECT * FROM x"), "CTE WITH accepte")
  UTAssert(1, IsReadOnlyQuery("EXPLAIN SELECT 1"), "EXPLAIN accepte")
  UTAssert(1, IsReadOnlyQuery("SHOW TABLES"), "SHOW accepte")
  UTAssert(1, IsReadOnlyQuery("-- commentaire" + #LF$ + "SELECT 1"), "commentaire -- saute")
  UTAssert(1, IsReadOnlyQuery("/* bloc */ SELECT 1"), "commentaire /* */ saute")

  UTAssert(0, IsReadOnlyQuery("INSERT INTO t VALUES (1)"), "INSERT refuse")
  UTAssert(0, IsReadOnlyQuery("UPDATE t SET a=1"), "UPDATE refuse")
  UTAssert(0, IsReadOnlyQuery("DELETE FROM t"), "DELETE refuse")
  UTAssert(0, IsReadOnlyQuery("CREATE TABLE t (a INT)"), "CREATE refuse")
  UTAssert(0, IsReadOnlyQuery("DROP TABLE t"), "DROP refuse")
  UTAssert(0, IsReadOnlyQuery("ALTER TABLE t ADD b INT"), "ALTER refuse")
  UTAssert(0, IsReadOnlyQuery("VACUUM"), "VACUUM refuse")
  UTAssert(0, IsReadOnlyQuery("PRAGMA journal_mode=DELETE"), "PRAGMA refuse (peut ecrire)")
  UTAssert(0, IsReadOnlyQuery("WITH x AS (SELECT 1) DELETE FROM t"), "CTE avec DELETE refuse")
  UTAssert(0, IsReadOnlyQuery("WITH x AS (SELECT 1) CREATE TABLE y AS SELECT * FROM x"), "CTE avec CREATE refuse")
  UTAssert(0, IsReadOnlyQuery(""), "requete vide refusee")
  UTAssert(0, IsReadOnlyQuery("-- rien"), "commentaire seul refuse")
EndProcedure

; ===========================================================================
; T2.1 - T2.3 : list_tables / describe_table
; ===========================================================================
Procedure Test_ListAndDescribe()
  SendStderrLine("--- T2.1-T2.3 list_tables / describe ---")

  Protected Out.s = ToolDbListTables("sqlite", "")
  UTAssert(1, Bool(FindString(Out, ~"\"rows\":[]") > 0), "T2.1 base vide -> aucune table")

  G_DBAllowWrite = #True   ; setup de la fixture
  ToolDbExecuteQuery("sqlite", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)")
  G_DBAllowWrite = #False

  Out = ToolDbListTables("sqlite", "")
  UTAssert(1, Bool(FindString(Out, "users") > 0), "T2.2 table users visible")

  Out = ToolDbDescribeTable("sqlite", "users", "")
  UTAssert(1, Bool(FindString(Out, "name") > 0 And FindString(Out, "TEXT") > 0 And FindString(Out, "pk") > 0), "T2.3 describe retourne colonnes/types/PK")

  Out = ToolDbDescribeTable("sqlite", "", "")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "describe sans nom -> erreur")
EndProcedure

; ===========================================================================
; T2.4 - T2.6 : execute_query (lecture, refus ecriture, ecriture autorisee)
; ===========================================================================
Procedure Test_ExecuteQuery()
  SendStderrLine("--- T2.4-T2.6 execute_query ---")

  Protected Out.s = ToolDbExecuteQuery("sqlite", "SELECT 1 AS un, 'x' AS lettre, 2.5 AS flt, NULL AS vide")
  UTAssert(1, Bool(FindString(Out, "un") > 0), "T2.4 colonnes presentes")
  UTAssert(1, Bool(FindString(Out, ~"\"1\"") > 0), "T2.4 valeur entiere")
  UTAssert(1, Bool(FindString(Out, "null") > 0), "T2.4 NULL preserve")

  Out = ToolDbExecuteQuery("sqlite", "INSERT INTO users (name, age) VALUES ('bob', 25)")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T2.5 INSERT refuse sans flag")

  G_DBAllowWrite = #True
  Out = ToolDbExecuteQuery("sqlite", "INSERT INTO users (name, age) VALUES ('bob', 25)")
  UTAssert(1, Bool(FindString(Out, "succes") > 0), "T2.6 INSERT autorise avec flag")
  G_DBAllowWrite = #False

  Out = ToolDbExecuteQuery("sqlite", "SELECT name FROM users WHERE name='bob'")
  UTAssert(1, Bool(FindString(Out, "bob") > 0), "T2.6 ligne inseree lisible")
EndProcedure

; ===========================================================================
; T2.7 : requete invalide ; T2.8 : chaines avec apostrophes
; ===========================================================================
Procedure Test_ErrorsAndEscaping()
  SendStderrLine("--- T2.7-T2.8 erreurs / echappement ---")

  Protected Out.s = ToolDbExecuteQuery("sqlite", "SELECT * FROM table_inexistante")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T2.7 requete invalide -> erreur claire")
  UTAssert(0, Bool(FindString(Out, "Erreur") = 0), "T2.7 serveur toujours vivant")

  G_DBAllowWrite = #True
  Out = ToolDbExecuteQuery("sqlite", "INSERT INTO users (name) VALUES ('l''oiseau')")
  G_DBAllowWrite = #False
  UTAssert(1, Bool(FindString(Out, "succes") > 0), "T2.8 apostrophe echappee inserable")

  Out = ToolDbExecuteQuery("sqlite", "SELECT name FROM users WHERE name='l''oiseau'")
  UTAssert(1, Bool(FindString(Out, "oiseau") > 0), "T2.8 valeur avec apostrophe lisible")
EndProcedure

; ===========================================================================
; db_explain + engine invalide
; ===========================================================================
Procedure Test_ExplainAndEngine()
  SendStderrLine("--- db_explain / engine invalide ---")

  Protected Out.s = ToolDbExplain("sqlite", "SELECT * FROM users WHERE age > 10")
  UTAssert(1, Bool(FindString(Out, "SCAN users") > 0), "EXPLAIN QUERY PLAN retourne le plan")

  Out = ToolDbExplain("sqlite", "DELETE FROM users")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "EXPLAIN refuse une ecriture")

  Out = ToolDbListTables("moteur_inconnu", "")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "engine inconnu -> erreur claire")

  Out = ToolDbListTables("postgres", "")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "postgres non configure -> erreur claire")
EndProcedure

; ===========================================================================
; Programme principal
; ===========================================================================
If Not CheckRuntime()
  End 1
EndIf

G_TestDB = GetTemporaryDirectory() + "mcp_db_unittest_" + Str(Date()) + "_" + Str(Random(100000)) + ".db"
If FileSize(G_TestDB) >= 0 : DeleteFile(G_TestDB) : EndIf

If Not DbOpenSQLite(G_TestDB)
  SendStderrLine("[ERREUR] ouverture base de test : " + G_TestDB)
  End 2
EndIf

Test_ReadOnlyGuard()
Test_ListAndDescribe()
Test_ExecuteQuery()
Test_ErrorsAndEscaping()
Test_ExplainAndEngine()

DbClose()
DeleteFile(G_TestDB)

UTFinalize()

End
