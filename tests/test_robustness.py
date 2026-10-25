#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Phase 6 - Tests de robustesse (T6.1-T6.8), SSE non imposé (T6.15) et
performances (T6.9-T6.14) sur le transport HTTP.

Usage :
    python tests/test_robustness.py [--quick]

Variables :
    MCP_STRESS_REQUESTS  nombre de requetes tools/list de T6.1 (defaut 500,
                         passer a 10000 pour le test complet)
"""

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcp_client import MCPTestClient
from mock_github import MockGitHub

BASE = Path(__file__).resolve().parent.parent
passed = 0
failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  [OK]   {name}")
    else:
        failed += 1
        print(f"  [FAIL] {name}  {detail}")


def find_binary(server):
    exe = ".exe" if os.name == "nt" else ""
    for candidate in (f"build/{server}{exe}", f"src/{server}{exe}"):
        p = BASE / candidate
        if p.exists():
            return p
    return None


def ms(start):
    return (time.perf_counter() - start) * 1000


# ---------------------------------------------------------------------------
# T6.1 - T6.4 : robustesse HTTP / charge
# ---------------------------------------------------------------------------

def test_http_robustness():
    print("\n== T6.1-T6.4 : robustesse HTTP ==")
    binary = find_binary("fileMCP")
    n = int(os.environ.get("MCP_STRESS_REQUESTS", "500"))

    with tempfile.TemporaryDirectory(prefix="robust-http-") as tmp:
        with MCPTestClient(binary, env={"MCP_ROOT": tmp}) as client:
            latencies = []
            errors = 0
            t0 = time.perf_counter()
            for _ in range(n):
                t = time.perf_counter()
                try:
                    names = client.list_tools()
                    if len(names) != 10:
                        errors += 1
                except Exception:
                    errors += 1
                latencies.append(ms(t))
            total = ms(t0)
            first = sum(latencies[:100]) / min(100, len(latencies))
            last = sum(latencies[-100:]) / min(100, len(latencies))
            check(f"T6.1 {n} tools/list sans erreur", errors == 0, f"{errors} erreurs")
            check("T6.1 latence stable (< x5)", last <= max(first * 5, 10),
                  f"debut {first:.2f} ms, fin {last:.2f} ms, total {total:.0f} ms")

            # T6.3 : JSON malforme -> erreur -32700, serveur vivant
            status, body, _ = client.post_raw(
                b"{ceci n'est pas du json",
                headers={"Content-Type": "application/json"},
            )
            try:
                resp = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                resp = {}
            check("T6.3 JSON malforme -> 400 + -32700",
                  status == 400 and (resp.get("error") or {}).get("code") == -32700,
                  f"status={status}, body={body[:120]!r}")
            check("T6.3 serveur vivant apres erreur", len(client.list_tools()) == 10)

            # T6.2 : corps JSON de 1 Mio -> 413, pas de crash
            huge = (b'{"jsonrpc":"2.0","id":1,"method":"ping","pad":"'
                    + b"x" * (1024 * 1024) + b'"}')
            status, body, _ = client.post_raw(
                huge, headers={"Content-Type": "application/json"})
            check("T6.2 corps 1 Mio -> 413", status == 413,
                  f"status={status}, body={body[:120]!r}")
            check("T6.2 serveur vivant apres 413", len(client.list_tools()) == 10)

        # T6.4 : port deja utilise -> second processus refuse proprement
        with MCPTestClient(binary, env={"MCP_ROOT": tmp},
                           auto_initialize=False) as first:
            proc = subprocess.run(
                [str(binary)],
                capture_output=True,
                text=True,
                timeout=15,
                env={
                    **os.environ,
                    "MCP_ROOT": tmp,
                    "MCP_HTTP_HOST": "127.0.0.1",
                    "MCP_HTTP_PORT": str(first.port),
                },
            )
            check("T6.4 port deja utilise -> code non nul",
                  proc.returncode != 0, f"code={proc.returncode}")
            stderr = (proc.stderr or "").lower()
            check("T6.4 message port clair",
                  "port" in stderr or "ecouter" in stderr,
                  (proc.stderr or "")[:160])


# ---------------------------------------------------------------------------
# T6.5 - T6.7 : robustesse SQLite / Memory / Database
# ---------------------------------------------------------------------------

def test_storage_robustness():
    print("\n== T6.5-T6.7 : robustesse bases ==")
    with tempfile.TemporaryDirectory(prefix="robust-") as tmp:
        db = str(Path(tmp) / "mem.db")

        # T6.5 : kill pendant une requete -> base rouvrable et coherente
        client = MCPTestClient(find_binary("memoryMCP"), env={"MCP_MEMORY_DB": db})
        err, text = client.tool_text("create_entities", {"entities": [
            {"name": "Survivante", "entityType": "test", "observations": ["avant-kill"]}]})
        check("T6.5 entite creee avant kill", not err, text[:100])
        client.proc.kill()
        client.proc.wait(timeout=10)
        with MCPTestClient(find_binary("memoryMCP"), env={"MCP_MEMORY_DB": db}) as client2:
            err, text = client2.tool_text("read_graph", {})
            check("T6.5 base reouverte et lisible", not err and "Survivante" in text, text[:120])

            # T6.6 : deux instances sur la meme base -> comportement documente
            with MCPTestClient(find_binary("memoryMCP"), env={"MCP_MEMORY_DB": db}) as client3:
                err, text = client2.tool_text("create_entities", {"entities": [
                    {"name": "Partagee", "entityType": "test"}]})
                err2, text2 = client3.tool_text("read_graph", {})
                visible = (not err2) and "Partagee" in text2
                check("T6.6 deux instances : lecture coherente ou erreur propre",
                      (not err) and (visible or err2), f"create={err}, read={err2}")

        # T6.7 : MCP_DB_PATH invalide -> erreur claire au demarrage
        bad_path = str(Path(tmp) / "repertoire_absent_xyz" / "db.sqlite")
        proc = subprocess.run([str(find_binary("dbMCP"))], input="",
                              capture_output=True, text=True, timeout=15,
                              env={**os.environ, "MCP_DB_PATH": bad_path})
        check("T6.7 chemin DB invalide -> code non nul + message",
              proc.returncode != 0 and "Impossible" in proc.stderr,
              f"code={proc.returncode}, stderr={proc.stderr[:80]}")


# ---------------------------------------------------------------------------
# T6.8 : reseau coupe (Context7)
# ---------------------------------------------------------------------------

def test_network_cut():
    print("\n== T6.8 : reseau coupe ==")
    env = {"MCP_CONTEXT7_API_BASE": "http://127.0.0.1:9"}
    with MCPTestClient(find_binary("context7MCP"), env=env) as client:
        err, text = client.tool_text("resolve_library_id", {"query": "react"})
        check("T6.8 coupure reseau -> erreur propre", err and "reseau" in text, text[:120])
        check("T6.8 serveur vivant apres coupure", len(client.list_tools()) == 2)


# ---------------------------------------------------------------------------
# T6.15 : SSE optionnel, jamais impose sans Accept
# ---------------------------------------------------------------------------

def test_no_sse():
    print("\n== T6.15 : SSE non impose ==")
    with MCPTestClient(find_binary("fileMCP")) as client:
        status, body, headers = client.raw_request("GET", "/mcp")
        ctype = headers.get("content-type", "")
        check("T6.15 GET /mcp sans Accept -> 405", status == 405, f"status={status}")
        check("T6.15 pas de text/event-stream sans Accept",
              "text/event-stream" not in ctype.lower(), ctype)


# ---------------------------------------------------------------------------
# T6.9 - T6.14 : performances
# ---------------------------------------------------------------------------

def test_performance():
    print("\n== T6.9-T6.14 : performances ==")
    with tempfile.TemporaryDirectory(prefix="perf-") as tmp:
        # T6.9 : 100 entites creees en < 500 ms
        db = str(Path(tmp) / "perf_mem.db")
        with MCPTestClient(find_binary("memoryMCP"), env={"MCP_MEMORY_DB": db}) as client:
            entities = [{"name": f"Entite{i}", "entityType": "perf",
                         "observations": [f"obs {i}"]} for i in range(100)]
            t = time.perf_counter()
            err, text = client.tool_text("create_entities", {"entities": entities})
            elapsed = ms(t)
            check("T6.9 create_entities 100 < 500 ms", (not err) and elapsed < 500,
                  f"{elapsed:.0f} ms")

        # T6.10 : recherche sur 10 000 entites < 200 ms
        big_db = str(Path(tmp) / "perf_big.db")
        con = sqlite3.connect(big_db)
        con.executescript("""
            CREATE TABLE IF NOT EXISTS entities (name TEXT PRIMARY KEY, entityType TEXT NOT NULL DEFAULT '', created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
            CREATE TABLE IF NOT EXISTS observations (id INTEGER PRIMARY KEY AUTOINCREMENT, entity_name TEXT NOT NULL REFERENCES entities(name) ON DELETE CASCADE, content TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
            CREATE TABLE IF NOT EXISTS relations (id INTEGER PRIMARY KEY AUTOINCREMENT, from_entity TEXT NOT NULL REFERENCES entities(name) ON DELETE CASCADE, to_entity TEXT NOT NULL REFERENCES entities(name) ON DELETE CASCADE, relation_type TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE(from_entity, to_entity, relation_type));
        """)
        con.executemany("INSERT INTO entities (name, entityType) VALUES (?, 'bulk')",
                        [(f"Bulk{i}",) for i in range(10000)])
        con.commit()
        con.close()
        with MCPTestClient(find_binary("memoryMCP"), env={"MCP_MEMORY_DB": big_db}) as client:
            t = time.perf_counter()
            err, text = client.tool_text("search_nodes", {"query": "Bulk4242"})
            elapsed = ms(t)
            check("T6.10 search_nodes 10k entites < 200 ms", (not err) and elapsed < 200,
                  f"{elapsed:.0f} ms (err={err})")

        # T6.11 : SELECT simple < 50 ms
        sdb = str(Path(tmp) / "perf_db.sqlite")
        with MCPTestClient(find_binary("dbMCP"), env={"MCP_DB_PATH": sdb}) as client:
            t = time.perf_counter()
            err, text = client.tool_text("db_execute_query", {"query": "SELECT 1 AS un"})
            elapsed = ms(t)
            check("T6.11 SELECT simple < 50 ms", (not err) and elapsed < 50,
                  f"{elapsed:.0f} ms")

        # T6.12 : git log sur 1000 commits < 200 ms
        repo = Path(tmp) / "bigrepo"
        repo.mkdir()
        _fast_import_repo(repo, 1000)
        with MCPTestClient(find_binary("gitMCP")) as client:
            t = time.perf_counter()
            err, text = client.tool_text("git_log", {"repoPath": str(repo), "count": 10})
            elapsed = ms(t)
            check("T6.12 git_log (1000 commits) < 200 ms", (not err) and elapsed < 200,
                  f"{elapsed:.0f} ms")

        # T6.13 : github list_issues (mock, 30 elements) < 2 s
        mock = MockGitHub()
        base = mock.start()
        try:
            with MCPTestClient(find_binary("githubMCP"), env={
                    "MCP_GITHUB_TOKEN": "ghp_test", "MCP_GITHUB_API_BASE": base}) as client:
                t = time.perf_counter()
                err, text = client.tool_text("gh_list_issues", {"owner": "o", "repo": "r"})
                elapsed = ms(t)
                check("T6.13 gh_list_issues 30 < 2000 ms", (not err) and elapsed < 2000,
                      f"{elapsed:.0f} ms")
        finally:
            mock.stop()

        # T6.14 : context7 query_docs < 3 s (cle API requise -> sinon SKIP)
        if os.environ.get("MCP_CONTEXT7_API_KEY", "").startswith("ctx7sk"):
            with MCPTestClient(find_binary("context7MCP")) as client:
                t = time.perf_counter()
                err, text = client.tool_text("query_docs", {
                    "libraryId": "/reactjs/react.dev/latest", "query": "useState", "tokens": 500})
                elapsed = ms(t)
                check("T6.14 query_docs < 3000 ms", (not err) and elapsed < 3000,
                      f"{elapsed:.0f} ms")
        else:
            print("  [SKIP] T6.14 : definir une vraie MCP_CONTEXT7_API_KEY")


def _fast_import_repo(repo, commits):
    """Cree `commits` commits rapidement via git fast-import."""
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, check=True,
                   capture_output=True)
    lines = []
    mark = 1
    for i in range(1, commits + 1):
        lines.append(f"commit refs/heads/main")
        lines.append(f"mark :{mark}")
        lines.append(f"committer Tester <t@example.com> {1600000000 + i} +0000")
        msg = f"commit {i}"
        lines.append(f"data {len(msg)}")
        lines.append(msg)
        if mark > 1:
            lines.append(f"from :{mark - 1}")
        lines.append(f"M 644 inline file.txt")
        data = f"ligne {i}"
        lines.append(f"data {len(data)}")
        lines.append(data)
        lines.append("")
        mark += 1
    stream = "\n".join(lines) + "\n"
    subprocess.run(["git", "fast-import", "--quiet"], cwd=repo,
                   input=stream.encode("utf-8"), check=True, capture_output=True)


# ---------------------------------------------------------------------------
# Programme principal
# ---------------------------------------------------------------------------

def main():
    missing = [s for s in ("fileMCP", "memoryMCP", "dbMCP", "context7MCP",
                           "gitMCP", "githubMCP") if find_binary(s) is None]
    if missing:
        print(f"[SKIP] binaires manquants : {missing} (compilez d'abord)")
        sys.exit(1)

    test_http_robustness()
    test_storage_robustness()
    test_network_cut()
    test_no_sse()
    test_performance()

    print(f"\n{passed} reussis, {failed} echoues")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
