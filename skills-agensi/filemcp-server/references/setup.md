# Getting fileMCP running (bootstrap)

The marketplace does not host the server: it stays on GitHub. Work through
these steps in order and stop at the first one that gives a healthy server.
Always tell the user what you are installing and where before running
anything.

## Step 0 — Is the server already running?

```bash
curl -s http://127.0.0.1:8101/health
```

If the answer is `{"server":"FileMCPServer-PureBasic","status":"ok",...}`,
skip to Step 4. If the user mentioned a custom port, probe it
(`MCP_HTTP_PORT`).

## Step 1 — Download a release binary (recommended)

fileMCP is a single native console executable, roughly 450 KB, with **zero
runtime dependencies** (no installer, no DLL). Download the asset for the
user's OS from the latest release:

```powershell
# Windows (PowerShell)
$dst = "$env:LOCALAPPDATA\MCPserver-HTTPSuite"
New-Item -ItemType Directory -Force $dst | Out-Null
Invoke-WebRequest `
  https://github.com/mickael-cala/MCPserver-HTTPSuite/releases/latest/download/fileMCP-windows-x64.exe `
  -OutFile "$dst\fileMCP.exe"
Get-FileHash "$dst\fileMCP.exe" -Algorithm SHA256
```

```bash
# Linux
mkdir -p ~/.local/bin
curl -fL -o ~/.local/bin/fileMCP \
  https://github.com/mickael-cala/MCPserver-HTTPSuite/releases/latest/download/fileMCP-linux-x64
chmod +x ~/.local/bin/fileMCP
sha256sum ~/.local/bin/fileMCP
```

Compare the hash against `SHA256SUMS.txt` published in the same release
before running anything. Expected asset names: `fileMCP-windows-x64.exe`,
`fileMCP-linux-x64`, `fileMCP-macos-arm64` (plus `SHA256SUMS.txt`).

## Step 2 — Build from source (fallback, needs PureBasic)

Only if no release asset fits the OS, or the user prefers building:

```bash
git clone https://github.com/mickael-cala/MCPserver-HTTPSuite
cd MCPserver-HTTPSuite
./build.sh        # Linux/macOS — or: build.bat on Windows
```

Requires PureBasic 6.x. Note for the user: Windows/macOS need a licensed
PureBasic; on Linux the free demo works (the sources are kept under its
800-line-per-file limit). Output lands in `build/fileMCP`.

## Step 3 — Start the server

Agree with the user on the root directory first — everything the tools touch
will be confined there. Loopback only by default; set `MCP_HTTP_TOKEN` if
anything besides the local client can reach the machine.

```powershell
# Windows — background, detached
$env:MCP_ROOT = "C:\work"
Start-Process -WindowStyle Hidden "$env:LOCALAPPDATA\MCPserver-HTTPSuite\fileMCP.exe"
```

```bash
# Linux/macOS
MCP_ROOT="$HOME/work" ~/.local/bin/fileMCP &
```

Then verify before anything else:

```bash
curl -s http://127.0.0.1:8101/health
```

## Step 4 — Declare the server in the MCP client

The client connects to a URL; it does not launch the server. Add (or ask the
user to add) the entry, then restart the client:

```json
{"mcpServers":{"file-pb":{
  "type":"http",
  "url":"http://127.0.0.1:8101/mcp",
  "headers":{"Authorization":"Bearer votre-token"}
}}}
```

Qwen: use the `httpUrl` key, never `url` (legacy SSE). The fileMCP tools then
appear alongside the client's built-in tools and the rest of this skill
applies.

## If nothing works

- No release asset for the OS and no PureBasic → say so plainly, point the
  user to the repo README (sections *Compilation*, *start_all*), and suggest
  opening an issue to request the missing asset.
- Health stays silent after a start attempt → check the port
  (`MCP_HTTP_PORT`), a leftover process on 8101, and that `MCP_ROOT` points
  to an existing real directory (a symlinked root is refused at startup).
