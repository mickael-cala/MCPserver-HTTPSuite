; ============================================================================
;  test_database.pb - Tests unitaires du serveur Database (Phase 2)
;  T2.1-T2.8 (SQLite) + batterie IsReadOnlyQuery. Les tests PostgreSQL
;  (T2.9-T2.12) sont des tests d'integration conditionnels (DSN requis).
;
;  Cycle de vie reel : le mode ecriture est fixe au demarrage (avant
;  l'ouverture de la base) et ne se bascule plus a chaud — la lecture
;  seule est appliquee par le moteur (PRAGMA query_only) a l'ouverture.
;  Le test suit ce cycle en trois phases :
;    A : ouverture lecture seule (garde applicatif + moteur)
;    B : reouverture avec MCP_DB_ALLOW_WRITE (fixture : CREATE + INSERT)
;    C : reouverture lecture seule (lectures des ecritures de B, refus
;        moteur d'un INSERT direct qui contourne le garde applicatif)
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
  ; EXPLAIN est retire de la whitelist : "EXPLAIN ANALYZE DELETE" execute
  ; reellement le DML sur PostgreSQL (db_explain construit lui-meme son
  ; EXPLAIN QUERY PLAN sur une requete deja validee).
  UTAssert(0, IsReadOnlyQuery("EXPLAIN SELECT 1"), "EXPLAIN refuse (EXPLAIN ANALYZE execute le DML)")
  ; Fail-closed : tout ';' rend la requete refusee, meme si le premier mot
  ; est un SELECT (PostgreSQL executerait les requetes empilees).
  UTAssert(0, IsReadOnlyQuery("SELECT 1; DROP TABLE x"), "multi-statements refuse")
  UTAssert(0, IsReadOnlyQuery("SELECT 1;"), "point-virgule final refuse")
EndProcedure

; ===========================================================================
; Phase A : lecture seule (T2.1 vide, T2.5 refus, T2.7 erreurs)
; ===========================================================================
Procedure Test_PhaseA_ReadOnly()
  SendStderrLine("--- Phase A : lecture seule (T2.1/T2.5/T2.7) ---")

  Protected Out.s = ToolDbListTables("sqlite", "")
  UTAssert(1, Bool(FindString(Out, ~"\"rows\":[]") > 0), "T2.1 base vide -> aucune table")

  Out = ToolDbExecuteQuery("sqlite", "INSERT INTO users (name, age) VALUES ('bob', 25)")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T2.5 INSERT refuse sans flag")

  Out = ToolDbExecuteQuery("sqlite", "SELECT * FROM table_inexistante")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T2.7 requete invalide -> erreur claire")
  UTAssert(0, Bool(FindString(Out, "Erreur") = 0), "T2.7 serveur toujours vivant")
EndProcedure

; ===========================================================================
; Phase B : reouverture en ecriture, fixture (CREATE + INSERT)
; ===========================================================================
Procedure Test_PhaseB_WriteFixture()
  SendStderrLine("--- Phase B : fixture en ecriture (T2.6/T2.8 setup) ---")

  Protected Out.s = ToolDbExecuteQuery("sqlite", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)")
  UTAssert(1, Bool(FindString(Out, "succes") > 0), "T2.6 CREATE TABLE autorise avec flag")

  Out = ToolDbExecuteQuery("sqlite", "INSERT INTO users (name, age) VALUES ('bob', 25)")
  UTAssert(1, Bool(FindString(Out, "succes") > 0), "T2.6 INSERT autorise avec flag")

  Out = ToolDbExecuteQuery("sqlite", "INSERT INTO users (name) VALUES ('l''oiseau')")
  UTAssert(1, Bool(FindString(Out, "succes") > 0), "T2.8 apostrophe echappee inserable")
EndProcedure

; ===========================================================================
; Phase C : reouverture lecture seule (T2.2/T2.3/T2.6/T2.8 + defense en
; profondeur : le moteur refuse un INSERT direct qui contourne le garde)
; ===========================================================================
Procedure Test_PhaseC_VerifyAndEngine()
  SendStderrLine("--- Phase C : verifs lecture seule + moteur (T2.2/T2.3/T2.6/T2.8) ---")

  Protected Out.s = ToolDbListTables("sqlite", "")
  UTAssert(1, Bool(FindString(Out, "users") > 0), "T2.2 table users visible")

  Out = ToolDbDescribeTable("sqlite", "users", "")
  UTAssert(1, Bool(FindString(Out, "name") > 0 And FindString(Out, "TEXT") > 0 And FindString(Out, "pk") > 0), "T2.3 describe retourne colonnes/types/PK")

  Out = ToolDbDescribeTable("sqlite", "", "")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "describe sans nom -> erreur")

  Out = ToolDbExecuteQuery("sqlite", "INSERT INTO users (name, age) VALUES ('carol', 30)")
  UTAssert(1, Bool(Left(Out, 6) = "Erreur"), "T2.5 INSERT refuse sans flag (relecture)")

  Out = ToolDbExecuteQuery("sqlite", "SELECT name FROM users WHERE name='bob'")
  UTAssert(1, Bool(FindString(Out, "bob") > 0), "T2.6 ligne inseree lisible")

  Out = ToolDbExecuteQuery("sqlite", "SELECT name FROM users WHERE name='l''oiseau'")
  UTAssert(1, Bool(FindString(Out, "oiseau") > 0), "T2.8 valeur avec apostrophe lisible")

  ; Defense en profondeur (audit C2) : on contourne le garde applicatif en
  ; appelant le moteur directement — PRAGMA query_only doit refuser.
  UTAssert(1, Bool(DatabaseUpdate(G_DBSQLite, "INSERT INTO users (name) VALUES ('pirate')") = 0), "moteur : INSERT direct refuse (query_only)")
  UTAssert(1, Bool(DatabaseError() <> ""), "moteur : erreur SQL presente")
  Out = ToolDbExecuteQuery("sqlite", "SELECT name FROM users WHERE name='pirate'")
  UTAssert(1, Bool(FindString(Out, ~"\"rows\":[]") > 0), "moteur : ligne pirate absente")

  Out = ToolDbExplain("sqlite", "SELECT * FROM users WHERE age > 10")
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

Test_ReadOnlyGuard()

; Phase A : ouverture lecture seule (G_DBAllowWrite=0, defaut).
If Not DbOpenSQLite(G_TestDB)
  SendStderrLine("[ERREUR] ouverture base de test : " + G_TestDB)
  End 2
EndIf
Test_PhaseA_ReadOnly()
DbClose()

; Phase B : reouverture en ecriture — le mode est fixe avant l'ouverture,
; comme le fait le serveur avec MCP_DB_ALLOW_WRITE=1.
G_DBAllowWrite = #True
If Not DbOpenSQLite(G_TestDB)
  SendStderrLine("[ERREUR] reouverture base de test (ecriture) : " + G_TestDB)
  End 2
EndIf
Test_PhaseB_WriteFixture()
DbClose()

; Phase C : reouverture en lecture seule — le moteur refuse les ecritures.
G_DBAllowWrite = #False
If Not DbOpenSQLite(G_TestDB)
  SendStderrLine("[ERREUR] reouverture base de test (lecture seule) : " + G_TestDB)
  End 2
EndIf
Test_PhaseC_VerifyAndEngine()
DbClose()

DeleteFile(G_TestDB)

UTFinalize()

End
