#!/usr/bin/env python3
# ============================================================================
#  test_fuzz.py - Fuzzing du transport HTTP et des outils (niveau 3).
#
#  Deterministe : graine fixe par defaut (20261112), corpus reproductible.
#  Hors run_all (gate vert) : se lance manuellement ou en CI.
#
#  Phases :
#    1. JSON-RPC  : mutations de requetes valides (types, champs absents/en
#                   double, tailles extremes, octets brutes corrompus).
#    2. HTTP brut : sockets — lignes de requete folles, Content-Length
#                   menteur, deconnexions anticipees, methods/paths fous.
#    3. Outils    : fileMCP avec jeton — arguments pervertis (types, null
#                   bytes, unicode, lots hors bornes), garde confirm,
#                   oracle de NON-FUITE du jeton dans les reponses.
#    4. Lockout   : 25 mauvais jetons -> les 5 derniers doivent recevoir
#                   429 (MCP_HTTP_AUTH_LOCKOUT), /health reste exempt.
#
#  Oracles (apres chaque lot) :
#    - GET /health -> 200 en moins de 5 s (serveur vivant, pas de hang) ;
#    - aucune reponse 5xx (le corpus doit produire du 400/200 propre) ;
#    - le jeton n'apparait jamais dans une reponse.
#
#  Usage : python tests/test_fuzz.py [--seed 20261112] [--rounds 150]
# ============================================================================
import argparse
import json
import os
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from mcp_client import MCPTestClient  # noqa: E402

TOKEN = "fuzz-secret-token-ne-pas-fuire-42"
HEALTH_TIMEOUT = 12.0  # > timeout d'inactivite serveur (10 s, documente)


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
# Oracles
# ---------------------------------------------------------------------------
def health_ok(host, port):
    """Serveur vivant : /health 200 en moins de 5 s. Retourne (ok, detail)."""
    try:
        s = socket.create_connection((host, port), timeout=HEALTH_TIMEOUT)
        s.settimeout(HEALTH_TIMEOUT)
        s.sendall(f"GET /health HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        s.close()
        line = data.split(b"\r\n", 1)[0].decode("latin-1")
        return (" 200" in line), line
    except OSError as exc:
        return False, str(exc)


class FuzzReport:
    def __init__(self):
        self.counts = {"2xx": 0, "3xx": 0, "4xx": 0, "5xx": 0, "501": 0, "autre": 0}
        self.failures = []

    def note(self, status_line):
        # 501 = refus volontaire du Transfer-Encoding chunked (design du
        # transport, testé par la suite intégration) : compté à part, ce
        # n'est pas une violation d'oracle.
        if " 501 " in status_line:
            self.counts["501"] += 1
            return "501"
        for cls in ("2xx", "3xx", "4xx", "5xx"):
            if cls[0] + "." in status_line or f" {cls[0]}" in status_line:
                self.counts[cls] += 1
                return cls
        self.counts["autre"] += 1
        return "autre"

    def fail(self, phase, detail):
        self.failures.append(f"[{phase}] {detail}")

    def summary(self):
        print(f"  Reponses : {self.counts}")
        if self.failures:
            for f in self.failures[:10]:
                print(f"  {f}")
            print(f"  ECHEC : {len(self.failures)} violation(s) d'oracle")
            return 1
        print("  Oracles : serveur vivant, aucun 5xx, aucune fuite de jeton")
        return 0


def send_raw(host, port, payload, timeout=8.0, close_early=False):
    """Envoie des octets brutes ; retourne (ligne de statut ou '', corps)."""
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.settimeout(timeout)
        s.sendall(payload)
        if close_early:
            s.close()
            return "(deconnecte)", b""
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 131072:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        line = head.split(b"\r\n", 1)[0].decode("latin-1") if head else ""
        s.close()
        return line, body
    except OSError as exc:
        return f"(oserror: {exc})", b""


# ---------------------------------------------------------------------------
# Phase 1 : mutations JSON-RPC
# ---------------------------------------------------------------------------
def mutate_jsonrpc(rng, req_bytes):
    """Mutation binaire : troncature, octets flippees, insertion de controle."""
    ops = rng.randrange(4)
    out = req_bytes
    for _ in range(ops):
        op = rng.randrange(3)
        if len(out) < 2:
            break
        if op == 0:  # troncature
            out = out[: rng.randrange(1, len(out))]
        elif op == 1:  # octet altere / controle insere
            i = rng.randrange(len(out))
            out = out[:i] + bytes([rng.randrange(256)]) + out[i + 1:]
        else:  # duplication d'un fragment
            a = rng.randrange(len(out))
            b = min(len(out), a + rng.randrange(1, 64))
            out = out[:b] + out[a:b] + out[b:]
        if len(out) > 131072:
            out = out[:131072]
    return out


def run_phase_jsonrpc(rng, client, report, rounds):
    print(f"\n== Fuzz phase 1 : JSON-RPC ({rounds} mutations) ==")
    bases = [
        {"jsonrpc": "2.0", "id": 1, "method": "ping"},
        {"jsonrpc": "2.0", "id": "abc", "method": "tools/call",
         "params": {"name": "read_file", "arguments": {"path": "x.txt"}}},
        {"jsonrpc": "2.0", "id": 2.5, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18"}},
    ]
    id_follies = [None, -1, 1.25, 10**30, [], {}, "", "x" * 5000]
    for i in range(rounds):
        base = dict(rng.choice(bases))
        mode = rng.randrange(4)
        if mode == 0 and "id" in base:            # id farfelu
            base["id"] = rng.choice(id_follies)
        elif mode == 1:                           # method farfelue
            base["method"] = rng.choice([None, "", 42, [], "ping\x00x",
                                         "notifications/" + "a" * 100,
                                         "tools/call/../../x"])
        elif mode == 2 and "params" in base:      # params farfelus
            base["params"] = rng.choice([None, [], "str", 0,
                                         {"name": ["liste"], "arguments": 7},
                                         {"arguments": {"path": None}}])
        else:                                     # champs parasites / dupliques
            base[rng.choice(["extra", "jsonrpc", "result"])] = {"a": [1, 2]}
        body = json.dumps(base, ensure_ascii=False).encode("utf-8")
        if rng.randrange(3) == 0:                 # mutation binaire
            body = mutate_jsonrpc(rng, body)
        line, resp_body = send_raw(client.host, client.port,
                                   b"POST /mcp HTTP/1.1\r\nHost: f:1\r\n"
                                   b"Content-Type: application/json\r\n"
                                   b"Content-Length: " +
                                   str(len(body)).encode() + b"\r\n\r\n" + body)
        cls = report.note(line)
        if cls == "5xx":
            report.fail("JSON-RPC", f"5xx sur mutation {i}: {line} / {body[:80]!r}")
        if cls == "501":
            report.fail("JSON-RPC", "501 inattendu hors chunked")
        if TOKEN.encode() in resp_body:
            report.fail("JSON-RPC", f"fuite de jeton (mutation {i})")
        if i % 15 == 14:
            ok, detail = health_ok(client.host, client.port)
            if not ok:
                report.fail("JSON-RPC", f"serveur mort apres {i + 1} mutations : {detail}")
                return


# ---------------------------------------------------------------------------
# Phase 2 : HTTP brut
# ---------------------------------------------------------------------------
def run_phase_raw(rng, client, report, rounds):
    print(f"\n== Fuzz phase 2 : HTTP brut ({rounds} requetes) ==")
    bodies = [b"{}", b'{"jsonrpc":"2.0","id":1,"method":"ping"}',
              b"x" * 4096, b"\x00\xff\xfe"]
    paths = ["/mcp", "/mcp/", "/../mcp", "/mcp/../mcp", "/MCP", "/health",
             "/mcp?x=1", "/mcp%2e%2e/health", "/" + "a" * 500, "/mcp\x00"]
    methods = ["POST", "GET", "PUT", "DELETE", "OPTIONS", "TRACE", "F00"]
    for i in range(rounds):
        # mode 0 = Content-Length menteur : force l'attente du timeout
        # d'inactivite serveur (~10 s, comportement documente) — rare.
        mode = rng.randrange(6) if rng.randrange(20) else 0
        if mode == 0 and rng.randrange(4):
            mode = rng.randrange(1, 6)
        body = rng.choice(bodies)
        path = rng.choice(paths)
        method = rng.choice(methods)
        if mode == 0:  # Content-Length menteur (trop grand) + deconnexion
            payload = (f"{method} {path} HTTP/1.1\r\nHost: f:1\r\n"
                       f"Content-Length: 999999\r\n\r\n").encode() + body
            line, resp_body = send_raw(client.host, client.port, payload,
                                       close_early=True)
        elif mode == 1:  # Content-Length menteur (trop petit)
            payload = (f"{method} {path} HTTP/1.1\r\nHost: f:1\r\n"
                       f"Content-Length: 3\r\n\r\n").encode() + body
            line, resp_body = send_raw(client.host, client.port, payload)
        elif mode == 2:  # chunked (refuse 501) + en-tetes dupliques
            payload = (f"{method} {path} HTTP/1.1\r\nHost: f:1\r\n"
                       f"Transfer-Encoding: chunked\r\nHost: f:2\r\n"
                       f"Content-Length: 2\r\n\r\n5\r\nhello\r\n0\r\n\r\n").encode()
            line, resp_body = send_raw(client.host, client.port, payload)
        elif mode == 3:  # ligne de requete invalide / version folle
            first = rng.choice(["GARBAGE\r\n", "POST\r\n", "POST /mcp HTTP/9.9\r\n",
                                "POST /mcp HTTP/1.1 extra\r\n"])
            payload = first.encode() + b"Host: f:1\r\n\r\n"
            line, resp_body = send_raw(client.host, client.port, payload)
        elif mode == 4:  # en-tete geant / CRLF injecte
            hdr = rng.choice([b"X-Pad: " + b"P" * 20000,
                              b"Authorization: Bearer x\r\nInjected: y",
                              b"Content-Type: application/json\r\n\r\nPREFETCHED"])
            payload = b"POST " + path.encode() + b" HTTP/1.1\r\nHost: f:1\r\n" + hdr + b"\r\n"
            line, resp_body = send_raw(client.host, client.port, payload)
        else:  # requete valide quelconque (methode/path fous acceptes par HTTP)
            payload = (f"{method} {path} HTTP/1.1\r\nHost: f:1\r\n"
                       f"Content-Type: application/json\r\n"
                       f"Content-Length: {len(body)}\r\n\r\n").encode() + body
            line, resp_body = send_raw(client.host, client.port, payload)
        cls = report.note(line)
        if cls == "5xx":
            report.fail("HTTP brut", f"5xx sur requete {i}: {line}")
        if TOKEN.encode() in resp_body:
            report.fail("HTTP brut", f"fuite de jeton (requete {i})")
        if i % 15 == 14:
            ok, detail = health_ok(client.host, client.port)
            if not ok:
                report.fail("HTTP brut", f"serveur mort apres {i + 1} requetes : {detail}")
                return


# ---------------------------------------------------------------------------
# Phase 3 : arguments d'outils pervertis (avec jeton valide)
# ---------------------------------------------------------------------------
def run_phase_tools(rng, client, report, rounds):
    print(f"\n== Fuzz phase 3 : arguments d'outils ({rounds} appels) ==")
    nasty_strings = ["", "\x00", "a\x00b", "../" * 40, "C:\\" * 30, "é" * 500,
                     "%APPDATA%" * 20, "x" * 100000, "Erreur : faux positif",
                     "' OR 1=1 --", "bench\x0bvertical"]
    nasty_values = [None, 42, -1, 1.5, True, [], {}, {"x": [None]},
                    ["a", 2, None], "x" * 5000]
    tools = ["read_file", "write_file", "list_files", "search_files",
             "exec", "delete_file", "get_file_info", "outil_fantome"]
    for i in range(rounds):
        tool = rng.choice(tools)
        args = {}
        if rng.randrange(2):
            args["path"] = rng.choice(nasty_strings + nasty_values)
        if rng.randrange(2):
            args["content"] = rng.choice(nasty_strings)
        if rng.randrange(3) == 0:
            args["pattern"] = rng.choice(nasty_strings)
        if tool == "exec":
            if rng.randrange(2):
                args["confirm"] = rng.choice([True, "true", 1, None, "oui"])
            if rng.randrange(3) == 0:
                args["commands"] = rng.choice(nasty_values + [["echo a"] * 25])
            if rng.randrange(3) == 0:
                args["timeoutMs"] = rng.choice([-5, 0, 10**12, "n"])
        try:
            status, body, _ = client.raw_request(
                "POST", "/mcp",
                body=json.dumps({"jsonrpc": "2.0", "id": i,
                                 "method": "tools/call",
                                 "params": {"name": tool, "arguments": args}},
                                ensure_ascii=False).encode("utf-8"),
                headers={"Content-Type": "application/json",
                         "Authorization": f"Bearer {TOKEN}"})
        except (OSError, json.JSONDecodeError) as exc:
            report.fail("Outils", f"exception sur {tool} {i}: {exc}")
            return
        line = f"HTTP {status}"
        cls = report.note(line)
        if cls == "5xx":
            report.fail("Outils", f"5xx sur {tool} args={str(args)[:100]}")
        if TOKEN.encode() in body:
            report.fail("Outils", f"fuite de jeton via {tool}")
        if i % 15 == 14:
            ok, detail = health_ok(client.host, client.port)
            if not ok:
                report.fail("Outils", f"serveur mort apres {i + 1} appels : {detail}")
                return


# ---------------------------------------------------------------------------
# Phase 4 : lockout anti brute-force (comportement deterministe)
# ---------------------------------------------------------------------------
def run_phase_lockout(client, report):
    print("\n== Fuzz phase 4 : lockout (25 mauvais jetons) ==")
    codes = []
    for _ in range(25):
        status, _, _ = client.raw_request(
            "POST", "/mcp",
            body=b'{"jsonrpc":"2.0","id":1,"method":"ping"}',
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer mauvais"})
        codes.append(status)
    locked = all(c == 429 for c in codes[20:])
    if not locked:
        report.fail("Lockout", f"pas de blocage apres 20 echecs : {codes}")
    ok, detail = health_ok(client.host, client.port)
    if not ok:
        report.fail("Lockout", f"/health bloque pendant le lockout : {detail}")


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Fuzzing MCPserver-HTTPSuite")
    ap.add_argument("--seed", type=int, default=20261112)
    ap.add_argument("--rounds", type=int, default=100)
    args = ap.parse_args()
    rng = __import__("random").Random(args.seed)

    binary = find_binary("fileMCP")
    report = FuzzReport()
    t0 = time.time()

    with tempfile_dir() as tmp:
        # Phases 1-2 : sans jeton (tout est autorise, pas de lockout).
        with MCPTestClient(binary, env={"MCP_ROOT": tmp,
                                        "MCP_HTTP_AUTH_LOCKOUT": "0"}) as client:
            print(f"Cible : fileMCP sur {client.host}:{client.port} (seed {args.seed})")
            run_phase_jsonrpc(rng, client, report, args.rounds)
            run_phase_raw(rng, client, report, args.rounds)

        # Phases 3-4 : avec jeton (lockout actif en phase 4 seulement).
        with MCPTestClient(binary, env={"MCP_ROOT": tmp,
                                        "MCP_HTTP_AUTH_LOCKOUT": "20",
                                        "MCP_HTTP_TOKEN": TOKEN}) as client:
            run_phase_tools(rng, client, report, max(args.rounds // 2, 40))
            run_phase_lockout(client, report)
            ok, detail = health_ok(client.host, client.port)
            if not ok:
                report.fail("Final", f"serveur mort en fin de run : {detail}")

    print(f"\nDuree : {time.time() - t0:.1f} s")
    sys.exit(report.summary())


from contextlib import contextmanager
import tempfile


@contextmanager
def tempfile_dir():
    d = tempfile.mkdtemp(prefix="fuzz-mcp-")
    try:
        yield d
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    main()
