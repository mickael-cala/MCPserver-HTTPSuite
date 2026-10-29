#!/usr/bin/env python3
"""Integration fpcMCP : ignore proprement si Free Pascal n'est pas installe."""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def find_binary() -> Path:
    candidates = [ROOT / "build" / "fpcMCP.exe", ROOT / "build" / "fpcMCP"]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise RuntimeError("fpcMCP introuvable : compiler src/fpcMCP.pb vers src/build/")


def rpc(port: int, method: str, params: dict) -> dict:
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/mcp",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def tool_text(port: int, name: str, arguments: dict) -> tuple[bool, str]:
    response = rpc(port, "tools/call", {"name": name, "arguments": arguments})
    result = response.get("result", {})
    text = "\n".join(
        part.get("text", "") for part in result.get("content", []) if part.get("type") == "text"
    )
    return bool(result.get("isError")), text


def native_target() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    if system == "windows":
        return "win64" if "64" in machine else "win32"
    if system == "darwin":
        return "macos-aarch64" if machine in {"arm64", "aarch64"} else "linux64"
    if machine in {"arm64", "aarch64"}:
        return "linux-aarch64"
    return "linux64" if "64" in machine else "linux32"


def main() -> int:
    fpc = os.environ.get("MCP_FPC") or shutil.which("fpc")
    if not fpc:
        print("SKIP: Free Pascal introuvable (MCP_FPC ou PATH).")
        return 2

    binary = find_binary()
    failures = 0

    def check(condition: bool, label: str, detail: str = "") -> None:
        nonlocal failures
        if condition:
            print(f"[OK]   {label}")
        else:
            failures += 1
            print(f"[FAIL] {label} {detail[:500]}")

    with tempfile.TemporaryDirectory(prefix="fpcmcp-int-") as tmp:
        root = Path(tmp)
        source_dir = root / "projet avec espaces"
        source_dir.mkdir()
        source = source_dir / "hello.pas"
        source.write_text("program hello;\nbegin\n  Writeln('ok');\nend.\n", encoding="utf-8")

        env = os.environ.copy()
        env["MCP_FPC_ROOT"] = str(root)
        env["MCP_FPC"] = fpc
        env["MCP_HTTP_PORT"] = "18108"
        process = subprocess.Popen(
            [str(binary)], cwd=ROOT, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            for _ in range(100):
                try:
                    with urllib.request.urlopen("http://127.0.0.1:18108/health", timeout=0.2):
                        break
                except Exception:
                    pass
            else:
                raise RuntimeError("fpcMCP ne repond pas sur 18108")

            tools = rpc(18108, "tools/list", {})["result"]["tools"]
            names = {tool["name"] for tool in tools}
            check(names == {"fpc_targets", "fpc_version", "fpc_compile", "fpc_clean"}, "catalogue fpcMCP")

            is_error, text = tool_text(18108, "fpc_targets", {})
            check(not is_error, "fpc_targets reussi")
            for target in ("win32", "win64", "linux32", "linux64", "linux-aarch64", "macos-aarch64"):
                check(target in text, f"fpc_targets expose {target}")

            is_error, text = tool_text(18108, "fpc_version", {})
            check(not is_error, "fpc_version reussi")
            check(len(text.strip()) > 0, "fpc_version retourne une sortie")

            target = native_target()
            is_error, text = tool_text(
                18108,
                "fpc_compile",
                {
                    "sourcePath": "projet avec espaces/hello.pas",
                    "target": target,
                    "buildMode": "debug",
                },
            )
            check(not is_error, f"compilation native {target}")
            check("Statut    : Reussi" in text, "statut Reussi present", text)
            check("Sortie compilateur" in text, "section stdout presente", text)
            check("Erreurs compilateur" in text, "section stderr presente", text)
            check("Artefacts" in text, "section artefacts presente", text)

            is_error, text = tool_text(18108, "fpc_clean", {"target": target})
            check(not is_error, f"fpc_clean accepte la cible {target}")
            check("Nettoyage termine" in text, "fpc_clean confirme le nettoyage", text)
            check((root / "build" / target).is_dir(), "repertoire de build recree")

            is_error, text = tool_text(18108, "fpc_clean", {"target": "amiga-mos"})
            check(is_error, "fpc_clean refuse une cible inconnue")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()

    print(f"---\nIntegration fpcMCP : {'echecs=' + str(failures) if failures else 'tous reussis'}")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"SKIP: {exc}")
        raise SystemExit(2)
