#!/usr/bin/env python3
"""Tests d'integration des limites 2 Mio de fileMCP."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LIMIT = 2 * 1024 * 1024


def find_binary() -> Path:
    candidates = [ROOT / "build" / "fileMCP.exe", ROOT / "build" / "fileMCP"]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise RuntimeError("fileMCP introuvable : compiler src/fileMCP.pb vers src/build/")


def rpc(port: int, method: str, params: dict) -> dict:
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/mcp",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def tool_text(port: int, name: str, arguments: dict) -> tuple[bool, str]:
    response = rpc(port, "tools/call", {"name": name, "arguments": arguments})
    result = response.get("result", {})
    is_error = bool(result.get("isError"))
    parts = result.get("content", [])
    text = "\n".join(part.get("text", "") for part in parts if part.get("type") == "text")
    return is_error, text


def main() -> int:
    binary = find_binary()
    failures = 0

    def check(condition: bool, label: str, detail: str = "") -> None:
        nonlocal failures
        if condition:
            print(f"[OK]   {label}")
        else:
            failures += 1
            print(f"[FAIL] {label} {detail[:300]}")

    with tempfile.TemporaryDirectory(prefix="filemcp-2mio-") as tmp:
        env = os.environ.copy()
        env["MCP_ROOT"] = tmp
        env["MCP_HTTP_PORT"] = "18101"
        process = subprocess.Popen(
            [str(binary)],
            cwd=ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            for _ in range(100):
                try:
                    with urllib.request.urlopen("http://127.0.0.1:18101/health", timeout=0.2):
                        break
                except Exception:
                    pass
            else:
                raise RuntimeError("fileMCP ne repond pas sur 18101")

            tools = rpc(18101, "tools/list", {})["result"]["tools"]
            descriptions = {tool["name"]: tool["description"] for tool in tools}
            check("2 Mio" in descriptions["read_file"], "catalogue read_file annonce 2 Mio")
            check("2 Mio" in descriptions["read_file_lines"], "catalogue read_file_lines annonce 2 Mio")

            exact = Path(tmp) / "exact.txt"
            exact.write_bytes(b"A" * LIMIT)
            is_error, text = tool_text(18101, "read_file", {"path": "exact.txt"})
            check(not is_error, "read_file accepte exactement 2 Mio")
            check("Tronque" not in text, "read_file exact n'est pas tronque")
            check(len(text.encode("utf-8")) >= LIMIT, "read_file contient les 2 Mio")

            too_big = Path(tmp) / "too-big.txt"
            too_big.write_bytes(b"B" * (LIMIT + 1))
            is_error, text = tool_text(18101, "read_file", {"path": "too-big.txt"})
            check(not is_error, "read_file trop grand retourne une troncature")
            check("Tronque" in text, "read_file marque la troncature")
            check("(fichier : " in text, "marqueur indique la taille reelle du fichier")
            check(str(LIMIT + 1) in text, "taille reelle exacte dans le marqueur")
            check(len(text.encode("utf-8")) <= LIMIT + 300, "read_file borne la sortie")

            is_error, text = tool_text(
                18101,
                "read_file_lines",
                {"path": "too-big.txt", "startLine": 1, "maxLines": 1},
            )
            check(is_error, "read_file_lines refuse 2 Mio + 1 octet")
            check("2 Mio" in text, "message read_file_lines mentionne 2 Mio")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()

    print(f"---\nTests 2 Mio : {'echecs=' + str(failures) if failures else 'tous reussis'}")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"SKIP: {exc}")
        raise SystemExit(2)
