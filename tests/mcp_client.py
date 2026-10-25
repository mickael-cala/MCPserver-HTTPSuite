#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Client MCP de test (harnais externe) - transport HTTP JSON, SSE optionnel.

Lance un serveur MCP en sous-processus, attend GET /health, puis dialogue
en JSON-RPC 2.0 via POST /mcp (Content-Type: application/json). Le serveur
peut repondre en JSON direct ou en text/event-stream si le client l'accepte.

Usage :
    from mcp_client import MCPTestClient

    with MCPTestClient("build/fileMCP.exe", env={"MCP_ROOT": "/tmp/x"}) as client:
        result = client.call_tool("list_files", {"path": "."})
        assert not result["isError"]
"""

import http.client
import json
import os
import socket
import subprocess
import threading
import time
from collections import deque


class MCPError(Exception):
    """Erreur de conformite du protocole MCP cote serveur."""


def find_free_port(host="127.0.0.1"):
    """Retourne un port TCP libre (course possible mais acceptable en test)."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind((host, 0))
        return s.getsockname()[1]


class MCPTestClient:
    """Client JSON-RPC 2.0 HTTP pour tester un serveur MCP (SSE optionnel)."""

    def __init__(self, executable, env=None, timeout=20, auto_initialize=True,
                 token=None, port=None, host="127.0.0.1"):
        if executable is None:
            raise MCPError("binaire introuvable : compilez d'abord avec build.bat/build.sh")

        self.timeout = timeout
        self.host = host
        self.port = port or find_free_port(host)
        self.url = f"http://{host}:{self.port}/mcp"

        full_env = os.environ.copy()
        if env:
            full_env.update({str(k): str(v) for k, v in env.items()})
        full_env["MCP_HTTP_HOST"] = host
        full_env["MCP_HTTP_PORT"] = str(self.port)
        if token is not None:
            full_env["MCP_HTTP_TOKEN"] = token
        self.token = full_env.get("MCP_HTTP_TOKEN", "")

        self._stderr_lines = deque(maxlen=400)
        self.proc = subprocess.Popen(
            [str(executable)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=full_env,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()
        self.next_id = 0

        try:
            self._wait_ready()
            if auto_initialize:
                resp = self.request("initialize", {})
                self._validate_initialize(resp)
        except Exception:
            self.close()
            raise

    # ------------------------------------------------------------------
    # Cycle de vie
    # ------------------------------------------------------------------
    def _drain_stderr(self):
        try:
            for line in self.proc.stderr:
                self._stderr_lines.append(line.rstrip())
        except (ValueError, OSError):
            pass

    @property
    def stderr_text(self):
        return "\n".join(self._stderr_lines)

    def _wait_ready(self):
        deadline = time.time() + self.timeout
        last_error = ""
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise MCPError(
                    f"serveur termine au demarrage (code {self.proc.returncode}) : "
                    f"{self.stderr_text[-800:]}"
                )
            try:
                status, body, _ = self.raw_request("GET", "/health", timeout=1)
                if status == 200:
                    return
                last_error = f"HTTP {status} : {body[:200]!r}"
            except (OSError, http.client.HTTPException) as exc:
                last_error = str(exc)
            time.sleep(0.05)
        raise MCPError(
            f"serveur non pret apres {self.timeout}s : {last_error}; "
            f"stderr={self.stderr_text[-800:]}"
        )

    def close(self):
        """Arrete le serveur (terminate puis kill si necessaire)."""
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
        if self.proc.stderr:
            try:
                self.proc.stderr.close()
            except (ValueError, OSError):
                pass
        self._stderr_thread.join(timeout=1)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    # ------------------------------------------------------------------
    # Protocole de base
    # ------------------------------------------------------------------
    def request(self, method, params=None):
        """Envoie une requete et retourne la reponse JSON-RPC validee."""
        self.next_id += 1
        req = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            req["params"] = params
        status, data, _ = self.post_json(req)
        if status != 200:
            raise MCPError(
                f"HTTP {status} pour {method} : {data[:300]!r} ; "
                f"stderr={self.stderr_text[-400:]}"
            )
        try:
            resp = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MCPError(f"reponse non JSON ({exc}) : {data[:300]!r}")
        self._validate_response(resp, self.next_id)
        return resp

    def call_tool(self, name, arguments=None):
        """
        Appelle tools/call et retourne l'objet result complet :
            {"content": [{"type": "text", "text": "..."}], "isError": bool}
        """
        resp = self.request(
            "tools/call",
            {"name": name, "arguments": arguments or {}},
        )
        result = resp.get("result") or {}
        if "content" not in result or "isError" not in result:
            raise MCPError(f"resultat tools/call incomplet : {result!r}")
        return result

    def tool_text(self, name, arguments=None):
        """Appelle un outil et retourne (isError, texte_du_premier_contenu)."""
        result = self.call_tool(name, arguments)
        content = result.get("content") or []
        text = content[0].get("text", "") if content else ""
        return bool(result.get("isError")), text

    def list_tools(self):
        """Retourne la liste des noms d'outils du catalogue."""
        resp = self.request("tools/list")
        tools = (resp.get("result") or {}).get("tools") or []
        return [t.get("name") for t in tools]

    def notify_initialized(self):
        """Envoie notifications/initialized : HTTP 202 sans corps."""
        status, data, _ = self.post_json(
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            expect_status=202,
        )
        if data:
            raise MCPError(f"notification : corps inattendu {data[:200]!r}")
        return status

    # ------------------------------------------------------------------
    # HTTP bas niveau
    # ------------------------------------------------------------------
    def _auth_headers(self, extra=None):
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if extra:
            headers.update(extra)
        return headers

    def raw_request(self, method, path, body=None, headers=None, timeout=None):
        """Requete HTTP brute ; retourne (status, bytes, headers minuscules)."""
        conn = http.client.HTTPConnection(
            self.host, self.port, timeout=timeout or self.timeout
        )
        try:
            if isinstance(body, str):
                body = body.encode("utf-8")
            conn.request(method, path, body=body, headers=headers or {})
            resp = conn.getresponse()
            data = resp.read()
            hdrs = {k.lower(): v for k, v in resp.getheaders()}
            return resp.status, data, hdrs
        finally:
            conn.close()

    def post_json(self, obj, headers=None, expect_status=None):
        """POST /mcp avec un objet JSON ; retourne (status, bytes, headers)."""
        payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        hdrs = self._auth_headers({"Content-Type": "application/json"})
        if headers:
            hdrs.update(headers)
        status, data, resp_headers = self.raw_request(
            "POST", "/mcp", body=payload, headers=hdrs
        )
        if expect_status is not None and status != expect_status:
            raise MCPError(
                f"HTTP {status} (attendu {expect_status}) : {data[:300]!r} ; "
                f"stderr={self.stderr_text[-400:]}"
            )
        return status, data, resp_headers

    def post_raw(self, body, headers=None):
        """POST /mcp avec un corps brut (tests de robustesse)."""
        hdrs = self._auth_headers({"Content-Type": "application/json"})
        if headers:
            hdrs.update(headers)
        return self.raw_request("POST", "/mcp", body=body, headers=hdrs)

    # ------------------------------------------------------------------
    # Validations de conformite JSON-RPC 2.0
    # ------------------------------------------------------------------
    def _validate_response(self, resp, expected_id):
        if not isinstance(resp, dict):
            raise MCPError(f"reponse non objet : {resp!r}")
        if resp.get("jsonrpc") != "2.0":
            raise MCPError(f"champ jsonrpc invalide : {resp!r}")
        if resp.get("id") != expected_id:
            raise MCPError(
                f"id incoherent (attendu {expected_id}, recu {resp.get('id')})"
            )
        if ("result" in resp) == ("error" in resp):
            raise MCPError(
                f"reponse doit contenir exactement un de result/error : {resp!r}"
            )

    def _validate_initialize(self, resp):
        result = resp.get("result") or {}
        if "protocolVersion" not in result:
            raise MCPError(f"initialize sans protocolVersion : {result!r}")
        if "serverInfo" not in result:
            raise MCPError(f"initialize sans serverInfo : {result!r}")
        if result.get("protocolVersion") not in ("2025-03-26", "2025-06-18"):
            raise MCPError(
                f"protocolVersion non HTTP-compatible : {result.get('protocolVersion')!r}"
            )
