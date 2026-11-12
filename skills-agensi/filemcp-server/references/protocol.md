# fileMCP transport — JSON-RPC 2.0 over HTTP

Endpoint: `POST http://127.0.0.1:8101/mcp` (override port with
`MCP_HTTP_PORT`). Health: `GET /health`. The server is stateless: no session
id, one request per connection (`Connection: close`).

## Requirements per request

- Header `Content-Type: application/json` (charset allowed) — else `415`.
- Body = one JSON-RPC 2.0 object with `Content-Length` — chunked transfer
  encoding is refused with `501`.
- Body max 1 MiB by default (`413` beyond; server setting `MCP_HTTP_MAX_BODY`,
  1 KiB–16 MiB).
- `Authorization: Bearer <token>` when the server runs with `MCP_HTTP_TOKEN`
  (else `401`). Browsers/foreign origins get `403` (loopback-only Origin
  policy).

## Lifecycle

```bash
curl -s http://127.0.0.1:8101/health
# {"server":"FileMCPServer-PureBasic","status":"ok","sse":true,...}

curl -s -X POST http://127.0.0.1:8101/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# -> result.protocolVersion "2025-06-18", serverInfo FileMCPServer-PureBasic 2.0.0

curl -s -X POST http://127.0.0.1:8101/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
# -> HTTP 202, empty body (no JSON-RPC response for notifications)

curl -s -X POST http://127.0.0.1:8101/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
        "name":"read_file","arguments":{"path":"notes.txt"}}}'
```

Header `Mcp-Protocol-Version` is validated when present (`2025-03-26` /
`2025-06-18`); if absent the request is treated as `2025-03-26`.

## Error mapping

| HTTP | JSON-RPC | Meaning |
|---|---|---|
| 400 | `-32700` | Invalid JSON |
| 400 | `-32600` | Batch, response object, or missing method |
| 200 | `-32601` | Unknown method (valid request) |
| 200 | `result.isError: true` | Tool-level failure — read `content[0].text` |
| 401 | — | Missing/invalid Bearer token |
| 403 | — | Origin not allowed |
| 405 | — | `GET /mcp` without `Accept: text/event-stream` |
| 413 | — | Body over the limit |
| 415 | — | Wrong Content-Type |
| 501 | — | `Transfer-Encoding: chunked` |

## SSE (optional, never required)

`GET /mcp` with `Accept: text/event-stream` opens a `text/event-stream` flow
(`: connected`, then `: keep-alive` every 15 s). `POST /mcp` replies as one
SSE `event: message` if the client Accepts it, else plain JSON. Everything in
this skill works with plain JSON POSTs.

## Client configuration

```json
{"mcpServers":{"file-pb":{
  "type":"http",
  "url":"http://127.0.0.1:8101/mcp",
  "headers":{"Authorization":"Bearer votre-token"}
}}}
```

Qwen: use the `httpUrl` key (Streamable HTTP). The `url` key means legacy SSE
and expects an `endpoint` event — do not use it with this server.

## Server-side environment

| Variable | Role |
|---|---|
| `MCP_ROOT` | Allowed root (absolute, real dir, not a link). Default: cwd |
| `MCP_ROOT_SECRET` | Password enabling `change_root` |
| `MCP_HTTP_PORT` / `MCP_HTTP_HOST` | Listen port / address (default loopback) |
| `MCP_HTTP_TOKEN` | Bearer token requirement |
| `MCP_HTTP_MAX_BODY` | Max JSON body (1 KiB–16 MiB) |

No secrets are ever returned in responses or logs; logs go to stderr only.
