#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tests fonctionnels des serveurs MCP, via le harnais tests/mcp_client.py.

Transport : HTTP JSON-RPC (POST /mcp), SSE optionnel. Chaque serveur est lance
sur un port libre et interroge via GET /health puis POST /mcp.

Serveurs testes :
    fileMCP                   gestion de fichiers (racine temporaire)
    MCP-Fetch-PB              recuperation web (catalogue + cas d'erreur hors
                              ligne ; le cas nominal necessite internet)
    MCP-SequentialThinking-PB raisonnement sequentiel (local, sans reseau)
    memoryMCP                 graphe d'entites SQLite
    dbMCP                     exploration SQL SQLite/PostgreSQL
    context7MCP               API Context7 (live conditionnel)
    gitMCP                    depots git locaux
    githubMCP                 API GitHub via mock local

Chaque binaire est cherche dans l'ordre :
    1. variable d'environnement <NOM>_BIN (ex. FILEMCP_BIN)
    2. build/<nom>(.exe)
    3. src/<nom>(.exe)

Usage :
    python tests/test_mcp.py [nom-du-serveur ...]   # par defaut : les 8
"""

import json
import os
import re
import socket
import sys
import tempfile
from pathlib import Path

from mcp_client import MCPTestClient

ROOT_SECRET = "test-secret-123"

passed = 0
failed = 0
current_suite = None
suite_stats = {}


def check(name, condition, detail=""):
    global passed, failed
    stats = suite_stats.setdefault(current_suite or "global", {"passed": 0, "failed": 0})
    if condition:
        passed += 1
        stats["passed"] += 1
        print(f"  [OK]   {name}")
    else:
        failed += 1
        stats["failed"] += 1
        print(f"  [FAIL] {name}  {detail}")


def find_binary(server):
    env_var = server.upper().replace("-", "_") + "_BIN"
    if os.environ.get(env_var):
        return Path(os.environ[env_var])
    exe = ".exe" if os.name == "nt" else ""
    base = Path(__file__).resolve().parent.parent
    for candidate in (f"build/{server}{exe}", f"src/{server}{exe}"):
        p = base / candidate
        if p.exists():
            return p
    return None


# ---------------------------------------------------------------------------
# Suite fileMCP (gestion de fichiers)
# ---------------------------------------------------------------------------

def run_tests_filemcp():
    with tempfile.TemporaryDirectory(prefix="filemcp-test-") as tmp:
        env = {"MCP_ROOT": tmp, "MCP_ROOT_SECRET": ROOT_SECRET}
        with MCPTestClient(find_binary("fileMCP"), env=env) as client:
            run_checks_filemcp(client, Path(tmp))


def run_checks_filemcp(client, root):
    print("\n== fileMCP : tools/list ==")
    names = client.list_tools()
    expected = {
        "list_files", "read_file", "read_file_lines", "write_file",
        "create_directory", "delete_file", "move_file", "get_file_info",
        "search_files", "change_root",
    }
    check("tools/list retourne 10 outils", len(names) == 10, f"obtenu: {names}")
    check("catalogue conforme", set(names) == expected, f"diff: {set(names) ^ expected}")

    print("\n== fileMCP : write_file / read_file ==")
    err, text = client.tool_text("write_file", {"path": "hello.txt", "content": "ligne 1\nligne 2\n"})
    check("write_file ok", not err, text)
    err, text = client.tool_text("read_file", {"path": "hello.txt"})
    check("read_file renvoie le contenu", not err and "ligne 1" in text, text)

    print("\n== fileMCP : read_file_lines ==")
    err, text = client.tool_text("read_file_lines", {"path": "hello.txt", "startLine": 2, "maxLines": 1})
    check("read_file_lines (startLine=2)", not err and "ligne 2" in text and "ligne 1" not in text, text)

    print("\n== fileMCP : create_directory / list_files ==")
    err, text = client.tool_text("create_directory", {"path": "dossier"})
    check("create_directory ok", not err, text)
    err, text = client.tool_text("list_files", {"path": "."})
    check("list_files voit le dossier et le fichier", not err and "dossier" in text and "hello.txt" in text, text)

    print("\n== fileMCP : get_file_info ==")
    err, text = client.tool_text("get_file_info", {"path": "hello.txt"})
    check("get_file_info ok", not err and "hello.txt" in text, text)

    print("\n== fileMCP : search_files ==")
    err, text = client.tool_text("search_files", {"path": ".", "pattern": "ligne 2"})
    check("search_files trouve le texte", not err and "hello.txt" in text, text)

    print("\n== fileMCP : move_file ==")
    err, text = client.tool_text("move_file", {"oldPath": "hello.txt", "newPath": "rename.txt"})
    check("move_file ok", not err, text)
    err, text = client.tool_text("read_file", {"path": "rename.txt"})
    check("fichier renomme lisible", not err and "ligne 1" in text, text)

    print("\n== fileMCP : securite - confinement a la racine ==")
    for traversal in ("../escape.txt", "..\\..\\escape.txt", "dossier/../../escape.txt"):
        err, text = client.tool_text("read_file", {"path": traversal})
        check(f"travers refuse: {traversal}", err, text)

    print("\n== fileMCP : securite - change_root ==")
    err, text = client.tool_text("change_root", {"newRoot": str(Path.home()), "secret": "mauvais-secret"})
    check("change_root refuse avec mauvais secret", err, text)

    print("\n== fileMCP : delete_file ==")
    err, text = client.tool_text("delete_file", {"path": "rename.txt"})
    check("delete_file ok", not err, text)
    err, text = client.tool_text("read_file", {"path": "rename.txt"})
    check("fichier supprime illisible", err, text)


# ---------------------------------------------------------------------------
# Suite MCP-SequentialThinking-PB
# ---------------------------------------------------------------------------

def run_tests_sequential():
    with MCPTestClient(find_binary("MCP-SequentialThinking-PB")) as client:
        print("\n== SequentialThinking : tools/list ==")
        names = client.list_tools()
        check("catalogue = [sequential_thinking]", names == ["sequential_thinking"], f"obtenu: {names}")

        print("\n== SequentialThinking : sequential_thinking ==")
        err, text = client.tool_text("sequential_thinking", {
            "thought": "Etape 1 : analyser le probleme.",
            "thoughtNumber": 1, "totalThoughts": 3, "nextThoughtNeeded": True,
        })
        check("etape 1 acceptee", not err, text)
        check("etat retourne (etape/total)", "1" in text and "3" in text, text)

        err, text = client.tool_text("sequential_thinking", {
            "thought": "Etape 2 : proposer une solution.",
            "thoughtNumber": 2, "totalThoughts": 3, "nextThoughtNeeded": True,
        })
        check("etape 2 acceptee", not err, text)

        err, text = client.tool_text("sequential_thinking", {
            "thought": "Revision de l'etape 1.",
            "thoughtNumber": 3, "totalThoughts": 3, "nextThoughtNeeded": False,
            "isRevision": True, "revisesThought": 1,
        })
        check("revision acceptee", not err, text)
        check("historique mis a jour (3 etapes)", '"thoughtHistoryLength":3' in text, text)


# ---------------------------------------------------------------------------
# Suite MCP-Fetch-PB
# ---------------------------------------------------------------------------

def run_tests_fetch():
    with MCPTestClient(find_binary("MCP-Fetch-PB")) as client:
        print("\n== Fetch : tools/list ==")
        names = client.list_tools()
        check("catalogue = [fetch]", names == ["fetch"], f"obtenu: {names}")

        print("\n== Fetch : cas d'erreur hors ligne ==")
        err, text = client.tool_text("fetch", {"url": "http://127.0.0.1:9/"})
        check("connexion refusee signalee en erreur", err, text[:120])

        err, text = client.tool_text("fetch", {"url": "not-a-url"})
        check("URL invalide signalee en erreur", err, text[:120])


# ---------------------------------------------------------------------------
# Suite memoryMCP (graphe d'entites SQLite)
# ---------------------------------------------------------------------------

def run_tests_memory():
    with tempfile.TemporaryDirectory(prefix="memorymcp-test-") as tmp:
        env = {"MCP_MEMORY_DB": str(Path(tmp) / "memory.db")}
        with MCPTestClient(find_binary("memoryMCP"), env=env) as client:
            run_checks_memory(client)


def run_checks_memory(client):
    print("\n== Memory : tools/list ==")
    names = client.list_tools()
    expected = {
        "create_entities", "create_relations", "add_observations",
        "delete_entities", "delete_observations", "delete_relations",
        "read_graph", "search_nodes", "open_nodes",
    }
    check("tools/list retourne 9 outils", len(names) == 9, f"obtenu: {names}")
    check("catalogue conforme", set(names) == expected, f"diff: {set(names) ^ expected}")

    print("\n== Memory : cycle complet create -> search -> add -> delete ==")
    err, text = client.tool_text("create_entities", {"entities": [
        {"name": "Alice", "entityType": "person", "observations": ["aime le cafe"]},
        {"name": "Bob", "entityType": "person", "observations": []},
    ]})
    check("create_entities ok", not err, text)

    err, text = client.tool_text("create_relations", {"relations": [
        {"from": "Alice", "to": "Bob", "relationType": "connait"},
    ]})
    check("create_relations ok", not err, text)

    err, text = client.tool_text("search_nodes", {"query": "cafe"})
    check("search_nodes trouve par observation", not err and "Alice" in text, text[:120])

    err, text = client.tool_text("search_nodes", {"query": "bob"})
    check("search_nodes insensible a la casse", not err and "Bob" in text, text[:120])

    err, text = client.tool_text("add_observations", {"observations": [
        {"entityName": "Alice", "contents": ["deuxieme observation"]},
    ]})
    check("add_observations ok", not err, text)

    err, text = client.tool_text("open_nodes", {"names": ["Alice", "Bob"]})
    check("open_nodes retourne les 2 entites", not err and "Alice" in text and "Bob" in text, text[:120])
    check("observation ajoutee visible", "deuxieme observation" in text)

    err, text = client.tool_text("read_graph", {})
    check("read_graph contient la relation", not err and "connait" in text, text[:120])

    print("\n== Memory : securite et erreurs ==")
    err, text = client.tool_text("create_entities", {"entities": [
        {"name": "Robert'); DROP TABLE entities;--", "entityType": "person"},
    ]})
    check("injection SQL echappee", not err, text[:120])
    err, text = client.tool_text("read_graph", {})
    check("table intacte apres injection", not err, text[:120])

    err, text = client.tool_text("create_relations", {"relations": [
        {"from": "Inconnu", "to": "Bob", "relationType": "x"},
    ]})
    check("relation sur entite inconnue refusee", err, text[:120])

    err, text = client.tool_text("add_observations", {"observations": [
        {"entityName": "Fantome", "contents": ["x"]},
    ]})
    check("observation sur entite inconnue refusee", err, text[:120])

    print("\n== Memory : suppressions ==")
    err, text = client.tool_text("delete_observations", {"observations": [
        {"entityName": "Alice", "contents": ["aime le cafe"]},
    ]})
    check("delete_observations ok", not err, text)
    err, text = client.tool_text("delete_relations", {"relations": [
        {"from": "Alice", "to": "Bob", "relationType": "connait"},
    ]})
    check("delete_relations ok", not err, text)
    err, text = client.tool_text("delete_entities", {"entityNames": ["Alice"]})
    check("delete_entities ok", not err, text)
    err, text = client.tool_text("open_nodes", {"names": ["Alice"]})
    compact = re.sub(r"\s+", "", text)
    check("Alice supprimee (cascade)", not err and '"entities":[]' in compact, text[:120])


# ---------------------------------------------------------------------------
# Suite dbMCP (exploration SQL, SQLite + PostgreSQL optionnel)
# ---------------------------------------------------------------------------

def run_tests_database():
    with tempfile.TemporaryDirectory(prefix="dbmcp-test-") as tmp:
        env = {"MCP_DB_PATH": str(Path(tmp) / "test.db")}
        with MCPTestClient(find_binary("dbMCP"), env=env) as client:
            run_checks_database(client)
        run_checks_database_postgres(env)


def run_checks_database_postgres(base_env):
    """T2.9-T2.12 : executes uniquement si un DSN PostgreSQL de test est fourni."""
    print("\n== Database : PostgreSQL (T2.9-T2.12) ==")
    dsn = os.environ.get("MCP_DB_POSTGRES_TEST_DSN")
    if not dsn:
        print("  [SKIP] definir MCP_DB_POSTGRES_TEST_DSN pour executer les tests PostgreSQL")
        return
    env = dict(base_env)
    env["MCP_DB_POSTGRES_DSN"] = dsn
    with MCPTestClient(find_binary("dbMCP"), env=env) as client:
        err, text = client.tool_text("db_list_schemas", {"engine": "postgres"})
        check("T2.9 list_schemas retourne public", not err and "public" in text, text[:120])
        err, text = client.tool_text("db_list_tables", {"engine": "postgres"})
        check("T2.9b list_tables postgres ok", not err, text[:120])
        err, text = client.tool_text("db_execute_query", {
            "engine": "postgres",
            "query": "SELECT table_name FROM information_schema.tables WHERE table_schema='public' LIMIT 1",
        })
        check("T2.12 requete information_schema ok", not err, text[:120])
    # Connexion invalide : le serveur doit demarrer quand meme et rejeter proprement
    bad_env = dict(base_env)
    bad_env["MCP_DB_POSTGRES_DSN"] = "host=127.0.0.1 port=9 dbname=rien connect_timeout=2"
    with MCPTestClient(find_binary("dbMCP"), env=bad_env) as client:
        err, text = client.tool_text("db_list_schemas", {"engine": "postgres"})
        check("T2.11 connexion postgres invalide -> erreur claire, serveur vivant", err, text[:120])


def run_checks_database(client):
    print("\n== Database : tools/list ==")
    names = client.list_tools()
    expected = {
        "db_list_schemas", "db_list_tables", "db_describe_table",
        "db_execute_query", "db_explain",
    }
    check("tools/list retourne 5 outils", len(names) == 5, f"obtenu: {names}")
    check("catalogue conforme", set(names) == expected, f"diff: {set(names) ^ expected}")

    print("\n== Database : lecture seule (defaut) ==")
    err, text = client.tool_text("db_execute_query", {"query": "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"})
    check("CREATE refuse sans MCP_DB_ALLOW_WRITE", err, text[:100])
    err, text = client.tool_text("db_execute_query", {"query": "INSERT INTO users (name) VALUES ('x')"})
    check("INSERT refuse", err, text[:100])
    err, text = client.tool_text("db_execute_query", {"query": "DROP TABLE users"})
    check("DROP refuse", err, text[:100])
    err, text = client.tool_text("db_execute_query", {"query": "WITH x AS (SELECT 1) DELETE FROM t"})
    check("CTE avec DELETE refuse", err, text[:100])

    print("\n== Database : requetes en lecture ==")
    err, text = client.tool_text("db_execute_query", {"query": "SELECT 1 AS un, 'x' AS t, 2.5 AS f, NULL AS vide"})
    check("SELECT expression ok", not err, text[:120])
    check("NULL preserve en JSON", ",null]" in text.replace(" ", ""), text[:120])
    err, text = client.tool_text("db_execute_query", {"query": "SELECT * FROM table_inexistante"})
    check("requete invalide -> erreur claire", err, text[:120])

    print("\n== Database : schemas / engine ==")
    err, text = client.tool_text("db_list_schemas", {})
    check("sqlite -> [main]", not err and "main" in text, text[:120])
    err, text = client.tool_text("db_list_tables", {"engine": "moteur_fou"})
    check("engine invalide -> erreur", err, text[:120])
    err, text = client.tool_text("db_list_tables", {"engine": "postgres"})
    check("postgres non configure -> erreur", err, text[:120])


# ---------------------------------------------------------------------------
# Suite context7MCP (resolution de bibliotheques + docs Context7)
# ---------------------------------------------------------------------------

def run_tests_context7():
    with MCPTestClient(find_binary("context7MCP")) as client:
        run_checks_context7(client)


def run_checks_context7(client):
    print("\n== Context7 : tools/list ==")
    names = client.list_tools()
    check("catalogue = [resolve_library_id, query_docs]",
          names == ["resolve_library_id", "query_docs"], f"obtenu: {names}")

    print("\n== Context7 : garde-fous (hors ligne) ==")
    err, text = client.tool_text("resolve_library_id", {"query": ""})
    check("query vide -> erreur", err, text[:100])
    err, text = client.tool_text("query_docs", {"libraryId": "", "query": "x"})
    check("libraryId vide -> erreur", err, text[:100])
    err, text = client.tool_text("query_docs", {"libraryId": "/react/react", "query": "hooks"})
    check("cle absente -> consigne explicite", err and "MCP_CONTEXT7_API_KEY" in text, text[:120])

    print("\n== Context7 : API live (skip si hors ligne) ==")
    err, text = client.tool_text("resolve_library_id", {"query": "react"})
    if err and "echec reseau" in text:
        print("  [SKIP] pas d'acces reseau vers context7.com")
        return
    check("T3.1 resolve react -> /reactjs/react.dev", not err and "/reactjs/react.dev" in text, text[:120])
    err, text = client.tool_text("resolve_library_id", {"query": "zzzznonexistentqqq"})
    check("T3.2 recherche sans resultat", not err and "Aucune bibliotheque" in text, text[:120])

    # T3.5 cle invalide -> 401 propre (le serveur doit etre relance avec la
    # fausse cle : sous-processus dedie)
    import subprocess
    env = os.environ.copy()
    env["MCP_CONTEXT7_API_KEY"] = "ctx7sk_fausse_cle_de_test_0123456789"
    with MCPTestClient(find_binary("context7MCP"), env=env) as bad_client:
        err, text = bad_client.tool_text("query_docs", {"libraryId": "/react/react", "query": "hooks"})
    check("T3.5 cle invalide -> 401 explicite", err and "401" in text, text[:120])

    # T3.3/T3.8 : seulement avec une vraie cle
    if os.environ.get("MCP_CONTEXT7_API_KEY", "").startswith("ctx7sk"):
        err, text = client.tool_text("query_docs", {
            "libraryId": "/reactjs/react.dev/latest", "query": "useState", "tokens": 500,
        })
        check("T3.3 query_docs retourne du contenu", not err and len(text) > 50, text[:120])
        err, text = client.tool_text("query_docs", {
            "libraryId": "/reactjs/react.dev/latest", "query": "useState",
            "tokens": 500, "max_length": 100,
        })
        check("T3.8 max_length tronque", not err and "tronque" in text, text[-120:])
    else:
        print("  [SKIP] T3.3/T3.8 : definir une vraie MCP_CONTEXT7_API_KEY")


# ---------------------------------------------------------------------------
# Suite gitMCP (depots locaux)
# ---------------------------------------------------------------------------

def run_tests_git():
    import subprocess
    with tempfile.TemporaryDirectory(prefix="gitmcp-test-") as tmp:
        repo = Path(tmp) / "repo"
        repo.mkdir()

        def git(*args):
            subprocess.run(["git", *args], cwd=repo, check=True,
                           capture_output=True, text=True)

        git("init", "-q", "-b", "main")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Tester")
        (repo / "README.md").write_text("ligne 1\nligne 2\n", encoding="utf-8")
        git("add", "README.md")
        git("commit", "-q", "-m", "premier-commit")
        (repo / "README.md").write_text("ligne 1 modifiee\nligne 2\n", encoding="utf-8")
        git("add", "README.md")
        git("commit", "-q", "-m", "deuxieme-commit")
        git("checkout", "-q", "-b", "feature")
        (repo / "f.txt").write_text("feature\n", encoding="utf-8")
        git("add", "f.txt")
        git("commit", "-q", "-m", "commit-feature")
        git("checkout", "-q", "main")
        (repo / "espace.txt").write_text("a\nb\n", encoding="utf-8")
        git("add", "espace.txt")
        git("commit", "-q", "-m", "troisieme-commit")
        (repo / "README.md").write_text("modifie\n", encoding="utf-8")

        with MCPTestClient(find_binary("gitMCP")) as client:
            run_checks_git(client, str(repo))


def run_checks_git(client, repo):
    print("\n== Git : tools/list ==")
    names = client.list_tools()
    expected = {"git_is_repo", "git_status", "git_log", "git_diff",
                "git_show", "git_branches", "git_blame"}
    check("tools/list retourne 7 outils", len(names) == 7, f"obtenu: {names}")
    check("catalogue conforme", set(names) == expected, f"diff: {set(names) ^ expected}")

    print("\n== Git : lecture du depot ==")
    err, text = client.tool_text("git_is_repo", {"repoPath": repo})
    check("git_is_repo true", not err and text.strip() == "true", text[:80])

    err, text = client.tool_text("git_status", {"repoPath": repo})
    check("status voit README.md modifie", not err and "README.md" in text, text[:120])

    err, text = client.tool_text("git_log", {"repoPath": repo, "count": 1})
    check("log count=1", not err and "troisieme-commit" in text, text[:120])

    err, text = client.tool_text("git_diff", {"repoPath": repo, "refA": "HEAD~1", "refB": "HEAD"})
    check("diff HEAD~1..HEAD", not err and "espace.txt" in text, text[:120])

    err, text = client.tool_text("git_show", {"repoPath": repo, "ref": "HEAD", "path": "espace.txt"})
    check("show fichier", not err and "a" in text, text[:80])

    err, text = client.tool_text("git_branches", {"repoPath": repo})
    check("branches main + feature", not err and "main" in text and "feature" in text, text[:120])

    err, text = client.tool_text("git_blame", {"repoPath": repo, "path": "espace.txt", "startLine": 1, "endLine": 2})
    check("blame 2 lignes", not err and len([l for l in text.strip().splitlines() if l.strip()]) == 2, text[:120])

    print("\n== Git : securite ==")
    err, text = client.tool_text("git_log", {"repoPath": repo + "; rm -rf /", "count": 1})
    check("repoPath injecte rejete", err, text[:120])
    err, text = client.tool_text("git_diff", {"repoPath": repo, "refA": "HEAD; touch x", "refB": "HEAD"})
    check("ref injectee rejetee", err, text[:120])
    err, text = client.tool_text("git_log", {"repoPath": repo + "_absent", "count": 1})
    check("depot inexistant -> erreur", err, text[:120])


# ---------------------------------------------------------------------------
# Suite githubMCP (API GitHub via mock local)
# ---------------------------------------------------------------------------

def run_tests_github():
    from mock_github import MockGitHub
    mock = MockGitHub()
    base = mock.start()
    try:
        env = {"MCP_GITHUB_TOKEN": "ghp_test_token", "MCP_GITHUB_API_BASE": base}
        with MCPTestClient(find_binary("githubMCP"), env=env) as client:
            run_checks_github(client)
        # T5.4 : sans token -> erreur explicite au premier appel
        with MCPTestClient(find_binary("githubMCP"),
                           env={"MCP_GITHUB_TOKEN": "", "MCP_GITHUB_API_BASE": base}) as client:
            err, text = client.tool_text("gh_get_repo", {"owner": "o", "repo": "r"})
            check("T5.4 sans token -> erreur explicite", err and "MCP_GITHUB_TOKEN" in text, text[:120])
    finally:
        mock.stop()


def run_checks_github(client):
    print("\n== GitHub : tools/list ==")
    names = client.list_tools()
    expected = {
        "gh_get_repo", "gh_list_issues", "gh_get_issue", "gh_create_issue",
        "gh_list_pull_requests", "gh_get_pull_request", "gh_create_pull_request",
        "gh_list_commits", "gh_search_code", "gh_search_repositories",
    }
    check("tools/list retourne 10 outils", len(names) == 10, f"obtenu: {names}")
    check("catalogue conforme", set(names) == expected, f"diff: {set(names) ^ expected}")

    print("\n== GitHub : lecture ==")
    err, text = client.tool_text("gh_get_repo", {"owner": "mock", "repo": "repo"})
    check("T5.1 get_repo 200", not err and "mock/repo" in text, text[:120])

    err, text = client.tool_text("gh_get_repo", {"owner": "o", "repo": "notfound"})
    check("T5.2 get_repo 404 -> introuvable", err and "introuvable" in text, text[:120])

    err, text = client.tool_text("gh_get_repo", {"owner": "o", "repo": "unauth"})
    check("T5.3 get_repo 401 -> token invalide", err and "token invalide" in text, text[:120])

    err, text = client.tool_text("gh_list_issues", {"owner": "o", "repo": "r"})
    check("T5.6 per_page defaut 30", not err and '"count":30' in text.replace(" ", ""), text[:120])

    err, text = client.tool_text("gh_list_issues", {
        "owner": "o", "repo": "r", "state": "closed", "page": 2, "per_page": 7})
    check("T5.5 state=closed transmis", not err and '"state":"closed"' in text.replace(" ", ""), text[:160])
    check("T5.7 page=2 transmis", not err and '"page":"2"' in text.replace(" ", ""), text[:160])

    err, text = client.tool_text("gh_list_issues", {"owner": "o", "repo": "r", "state": "bogus"})
    check("state invalide refuse", err, text[:120])

    err, text = client.tool_text("gh_get_issue", {"owner": "o", "repo": "r", "number": 5})
    check("get_issue", not err and "issue detail" in text, text[:120])

    err, text = client.tool_text("gh_list_pull_requests", {"owner": "o", "repo": "r"})
    check("list PRs", not err and '"count":30' in text.replace(" ", ""), text[:120])

    err, text = client.tool_text("gh_get_pull_request", {"owner": "o", "repo": "r", "number": 3})
    check("get PR", not err and "pr detail" in text, text[:120])

    err, text = client.tool_text("gh_list_commits", {"owner": "o", "repo": "r", "sha": "main"})
    check("T5.13 sha=main transmis", not err and '"sha":"main"' in text.replace(" ", ""), text[:160])

    print("\n== GitHub : ecritures (garde confirm) ==")
    err, text = client.tool_text("gh_create_issue", {"owner": "o", "repo": "r", "title": "t"})
    check("T5.8 create_issue sans confirm -> refus", err and "non confirmee" in text, text[:120])

    err, text = client.tool_text("gh_create_issue", {"owner": "o", "repo": "r", "title": "t", "confirm": True})
    check("T5.9 create_issue avec confirm", not err and '"number":1' in text.replace(" ", ""), text[:120])
    check("Authorization envoyee au mock", "Bearer ghp_test_token" in text, text[:160])

    err, text = client.tool_text("gh_create_issue", {
        "owner": "o", "repo": "r", "title": "invalid", "confirm": True})
    check("T5.10 create_issue 422 -> message", err and "validation" in text, text[:160])

    err, text = client.tool_text("gh_create_pull_request", {
        "owner": "o", "repo": "r", "title": "t", "head": "feature", "base": "main"})
    check("create PR sans confirm -> refus", err and "non confirmee" in text, text[:120])

    err, text = client.tool_text("gh_create_pull_request", {
        "owner": "o", "repo": "r", "title": "t", "head": "feature", "base": "main", "confirm": True})
    check("create PR avec confirm", not err and '"number":2' in text.replace(" ", ""), text[:120])

    print("\n== GitHub : recherches ==")
    err, text = client.tool_text("gh_search_code", {"query": "json parser"})
    check("T5.12 search code", not err and "total_count" in text, text[:120])

    err, text = client.tool_text("gh_search_code", {"query": "ratelimit test"})
    check("T5.11 search 403 rate limit -> quota", err and "limite de taux" in text, text[:120])

    err, text = client.tool_text("gh_search_repositories", {"query": "mcp"})
    check("search repositories", not err and "mock/repo" in text, text[:120])

    err, text = client.tool_text("gh_search_code", {"query": "a b&c=d"})
    check("T5.14 caracteres speciaux encodes", not err and '%20b%26c%3Dd' in text, text[:160])

    err, text = client.tool_text("gh_get_repo", {"owner": "o", "repo": "badjson"})
    check("T5.15 JSON invalide -> erreur", err and "reponse GitHub invalide" in text, text[:120])


# ---------------------------------------------------------------------------
# Suite transport HTTP (JSON par defaut, SSE optionnel)
# ---------------------------------------------------------------------------

def read_sse_headers(client, timeout=3):
    """Ouvre GET /mcp en SSE et retourne (socket, en-tetes brutes)."""
    s = socket.create_connection((client.host, client.port), timeout=timeout)
    s.settimeout(timeout)
    request = (
        f"GET /mcp HTTP/1.1\r\n"
        f"Host: {client.host}:{client.port}\r\n"
        "Accept: text/event-stream\r\n\r\n"
    )
    s.sendall(request.encode("ascii"))
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    return s, data


def run_tests_transport():
    print("\n== Transport HTTP JSON / SSE optionnel ==")
    with tempfile.TemporaryDirectory(prefix="http-transport-") as tmp:
        env = {"MCP_ROOT": tmp, "MCP_ROOT_SECRET": ROOT_SECRET}
        with MCPTestClient(find_binary("fileMCP"), env=env) as client:
            status, body, headers = client.raw_request("GET", "/health")
            health = json.loads(body.decode("utf-8")) if body else {}
            check("health HTTP 200", status == 200, f"status={status}")
            check("health transport=http", health.get("transport") == "http", str(health))
            check("health sse=true", health.get("sse") is True, str(health))

            status, body, headers = client.raw_request("GET", "/mcp")
            check("GET /mcp sans Accept -> 405", status == 405, f"status={status}")
            allow = headers.get("allow", "")
            check("GET /mcp Allow GET+POST", "GET" in allow and "POST" in allow, allow)
            check("GET /mcp sans Accept ne force pas SSE",
                  "text/event-stream" not in headers.get("content-type", "").lower(),
                  str(headers))

            sse_sock, sse_data = read_sse_headers(client)
            try:
                sse_head = sse_data.split(b"\r\n\r\n", 1)[0].decode("latin-1").lower()
                check("GET /mcp SSE -> 200 + text/event-stream",
                      sse_head.startswith("http/1.1 200")
                      and "content-type: text/event-stream" in sse_head,
                      sse_head[:200])
            finally:
                sse_sock.close()

            status, body, sse_headers = client.raw_request(
                "POST", "/mcp",
                body=b'{"jsonrpc":"2.0","id":77,"method":"ping"}',
                headers={"Content-Type": "application/json",
                         "Accept": "application/json, text/event-stream"})
            sse_text = body.decode("utf-8", "replace")
            check("POST /mcp SSE -> 200 + evenement message",
                  status == 200
                  and "text/event-stream" in sse_headers.get("content-type", "")
                  and "event: message" in sse_text
                  and '"id":77' in sse_text,
                  f"status={status}, headers={sse_headers}, body={sse_text[:200]!r}")

            status, body, headers = client.raw_request("DELETE", "/mcp")
            check("DELETE /mcp -> 204", status == 204, f"status={status}")

            status, body, headers = client.raw_request(
                "POST", "/mcp", body=b"{}",
                headers={"Content-Type": "text/plain"})
            check("Content-Type invalide -> 415", status == 415, f"status={status}")

            status, body, _ = client.post_raw(
                b"{pas du json", headers={"Content-Type": "application/json"})
            resp = json.loads(body.decode("utf-8")) if body else {}
            check("JSON invalide -> -32700",
                  status == 200 and (resp.get("error") or {}).get("code") == -32700,
                  f"status={status}, {resp}")

            status, body, _ = client.post_raw(
                b'{"jsonrpc":"2.0","method":"notifications/initialized"}',
                headers={"Content-Type": "application/json"})
            check("notification -> 202 sans corps",
                  status == 202 and body == b"", f"status={status}, body={body[:80]!r}")

            status, body, _ = client.post_raw(
                b'{"jsonrpc":"2.0","id":99,"method":"inconnue"}',
                headers={"Content-Type": "application/json"})
            resp = json.loads(body.decode("utf-8"))
            check("methode inconnue -> -32601",
                  (resp.get("error") or {}).get("code") == -32601, str(resp))

            status, body, _ = client.post_raw(
                b'[{"jsonrpc":"2.0","id":1,"method":"ping"}]',
                headers={"Content-Type": "application/json"})
            resp = json.loads(body.decode("utf-8"))
            check("lot JSON-RPC -> -32600",
                  (resp.get("error") or {}).get("code") == -32600, str(resp))

            huge = (b'{"jsonrpc":"2.0","id":1,"method":"ping","pad":"'
                    + b"x" * (1024 * 1024) + b'"}')
            status, body, _ = client.post_raw(
                huge, headers={"Content-Type": "application/json"})
            check("corps > 1 Mio -> 413", status == 413, f"status={status}")
            check("serveur vivant apres 413", len(client.list_tools()) == 10)

            status, body, _ = client.raw_request(
                "POST", "/mcp",
                body=b'{"jsonrpc":"2.0","id":1,"method":"ping"}',
                headers={"Content-Type": "application/json",
                         "Origin": "http://evil.example"})
            check("Origin etrangere -> 403", status == 403, f"status={status}")

            status, body, _ = client.raw_request("GET", "/inconnu")
            check("chemin inconnu -> 404", status == 404, f"status={status}")

        with MCPTestClient(find_binary("fileMCP"), env=env,
                           token="secret-test") as client:
            status, body, _ = client.raw_request(
                "POST", "/mcp",
                body=b'{"jsonrpc":"2.0","id":1,"method":"ping"}',
                headers={"Content-Type": "application/json"})
            check("token absent -> 401", status == 401, f"status={status}")
            resp = client.request("ping")
            check("token correct -> 200", "result" in resp, str(resp))


SUITES = {
    "fileMCP": run_tests_filemcp,
    "MCP-SequentialThinking-PB": run_tests_sequential,
    "MCP-Fetch-PB": run_tests_fetch,
    "memoryMCP": run_tests_memory,
    "dbMCP": run_tests_database,
    "context7MCP": run_tests_context7,
    "gitMCP": run_tests_git,
    "githubMCP": run_tests_github,
}


def main():
    requested = sys.argv[1:] or list(SUITES)
    missing = [s for s in requested if s not in SUITES]
    if missing:
        print(f"Suites inconnues : {missing}. Disponibles : {list(SUITES)}")
        sys.exit(2)

    skipped = []
    global current_suite
    if "fileMCP" in requested:
        current_suite = "transport"
        run_tests_transport()
        current_suite = None
    for server in requested:
        binary = find_binary(server)
        if binary is None:
            skipped.append(server)
            suite_stats[server] = {"skipped": True}
            print(f"[SKIP] {server} : binaire introuvable "
                  f"(compilez avec build.bat / build.sh ou definissez "
                  f"{server.upper().replace('-', '_')}_BIN)")
            continue
        print()
        print(f"Binaire teste : {binary}")
        current_suite = server
        SUITES[server]()
        current_suite = None

    report = {
        "suites": suite_stats,
        "totals": {"passed": passed, "failed": failed, "skipped": len(skipped)},
    }
    report_path = Path(__file__).resolve().parent / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print()
    print(f"{passed} reussis, {failed} echoues, {len(skipped)} ignores")
    print(f"Rapport JSON : {report_path}")
    sys.exit(0 if failed == 0 and not skipped else 1)


if __name__ == "__main__":
    main()
