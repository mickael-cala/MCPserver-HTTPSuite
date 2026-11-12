---
name: filemcp-server
description: Operate files through a local fileMCP server (MCP over HTTP) with a confined root, and run shell commands that require human confirmation. Read, write, search, move and delete files inside MCP_ROOT, run confirmed cmd.exe/bash commands (single or batch), and switch the allowed root with a secret. Use when the user mentions fileMCP, MCPserver-HTTPSuite, sandboxed file management, a local MCP file server, or asks to run a shell command that needs explicit approval.
license: MIT
compatibility: Requires the fileMCP server from github.com/mickael-cala/MCPserver-HTTPSuite running locally (default http://127.0.0.1:8101/mcp) and an MCP client supporting Streamable HTTP (type "http" / "httpUrl").
metadata:
  author: mickael-cala
  version: "1.0"
  server: fileMCP
  homepage: https://github.com/mickael-cala/MCPserver-HTTPSuite
---

# fileMCP — sandboxed file operations over MCP/HTTP

fileMCP is a self-contained MCP server (single native binary, no runtime) that
confines every file operation to a root directory (`MCP_ROOT`), and can run
shell commands only after explicit human confirmation. All tool messages are
in **French**; error results carry `isError: true`.

## When to use this skill

- Managing files that must stay inside a designated directory (workspace,
  scratch area, build folder).
- Reading or searching files without risking escapes via `..`, absolute paths,
  symlinks or junctions — fileMCP refuses them all.
- Running shell commands (`cmd.exe` on Windows, `bash`/`sh` elsewhere) where a
  human must approve each command or batch before execution.

## Prerequisites — check before anything else

1. The server runs locally (it is **not** hosted by any marketplace). If it
   is not installed yet, bootstrap it with
   [references/setup.md](references/setup.md): probe `/health`, else download
   the release binary from GitHub (single native executable, no installer —
   verify its SHA256), or build from source, then start it with a root
   directory, e.g. `MCP_ROOT=C:\work`. Default listen address is
   `http://127.0.0.1:8101/mcp`; override with `MCP_HTTP_PORT`.
2. Probe health: `GET /health` must return `{"status":"ok",...}`. If nothing
   answers, the server is not running — help the user start it (see the repo
   README, sections *Compilation* and *start_all*).
3. If the server was started with `MCP_HTTP_TOKEN`, send
   `Authorization: Bearer <token>` on every request, else you get `401`.
4. In client config use the Streamable HTTP key: `httpUrl` (Qwen) or
   `"type": "http"` (Claude and others). Do **not** use the legacy SSE `url`
   key.

## Tools at a glance

`list_files`, `read_file`, `read_file_lines`, `write_file`, `create_directory`,
`delete_file` (recursive), `move_file`, `get_file_info`, `search_files`,
`change_root` (needs `MCP_ROOT_SECRET`), `exec` (needs `confirm=true`).

Full arguments and response examples: [references/tools.md](references/tools.md).

## Standing rules

- **Always pass relative paths** (e.g. `src/main.c`). Absolute paths and `..`
  traversals are refused with `Erreur : Acces refuse en dehors de la zone
  autorisee.` Symlinks/junctions under the root are refused too — never try to
  work around it; ask the user to move the file inside the root instead.
- `read_file` truncates beyond 2 MiB and appends a marker with the real file
  size; switch to `read_file_lines` with ranges to page through large files.
- `delete_file` deletes directories **recursively** — confirm with the user
  before deleting anything non-trivial.
- Tool errors are French sentences starting with `Erreur`/`Echec`/`Impossible`
  or containing `introuvable`; check `isError` first, translate the message
  for the user second.

## The exec workflow (human confirmation, one per command or batch)

`exec` runs a shell command but is gated: an unconfirmed call is **refused by
design**. Follow this exact loop — never fabricate approval:

1. **Do not** include `confirm` on the first call. Send the command:
   ```json
   {"name":"exec","arguments":{"command":"dir /b"}}
   ```
   Expect the refusal `Erreur : commande non confirmee (confirm=true requis).`
2. **Show the exact command(s) to the human** and ask for approval. For a
   batch, show every line — a batch (`commands`, max 20) runs in **one**
   shell, so lines share `cd` and environment variables.
3. Only on explicit approval, re-send the **identical** command(s) with
   `"confirm": true`. If the user hesitates or edits the command, start the
   loop again with the new text.
4. Read the result: `Code de sortie : N` (exit code), `Duree : N ms`, then the
   merged stdout+stderr. Non-zero exit codes and timeouts (default 10 s, max
   60 s via `timeoutMs`) set `isError: true`. Output is capped at 64 KiB with
   a `[... sortie tronquee ...]` marker.
5. `workdir` (optional) must stay under the root. Remember: the confined
   working directory does **not** limit what the command itself can touch —
   that is exactly why confirmation is mandatory.

## Quick protocol reminder

JSON-RPC 2.0 on `POST /mcp` with `Content-Type: application/json`
(`415` otherwise). One JSON object per POST, `Content-Length` required
(chunked transfer is refused with `501`), body capped at 1 MiB (`413`).
`GET /mcp` returns `405` unless `Accept: text/event-stream` is sent; SSE is
optional and never required. `DELETE /mcp` returns `204`.

Details, error codes and curl examples: [references/protocol.md](references/protocol.md).

## Common pitfalls

| Symptom | Meaning / fix |
|---|---|
| `401` on every call | Server has `MCP_HTTP_TOKEN`; add the Bearer header |
| `403` | `Origin` not allowed — send no Origin, or a loopback one |
| `405` on `GET /mcp` | Normal without `Accept: text/event-stream`; POST instead |
| `-32700` with HTTP 400 | Malformed JSON — fix the payload |
| `Commande executee.` but empty output | Command produced nothing; that is success, exit code 0 |
| `Echec : commande interrompue ... (timeout)` | Raise `timeoutMs` (max 60000) or simplify the command |
