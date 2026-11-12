# fileMCP tools — arguments and examples

All tools answer via `result.content[0].text` (French) + `result.isError`.
Paths are relative to the allowed root unless stated otherwise.

## list_files(path)

Lists a directory with sizes.

```json
{"name":"list_files","arguments":{"path":"."}}
```

```
C:\work (3 elements) :
[DIR]  build
[FILE] notes.txt  (1204 octets)
```

## read_file(path)

Reads a text file (UTF-8). Truncates beyond 2 MiB and appends
`[... Tronque au-dela de 2097152 octets (fichier : N octets ...]`.

## read_file_lines(path, startLine=1, maxLines=50)

Pages through large files (file itself limited to 2 MiB). Output lines are
prefixed with their number: `    2: seconde ligne`.

## write_file(path, content) — sensitive

Creates or overwrites a text file (UTF-8). No atomic write: overwriting an
existing file replaces it directly.

## create_directory(path)

Creates a directory and any missing parents.

## delete_file(path) — destructive

Deletes a file, or a directory **recursively**. Always confirm with the user
when the target is a directory.

## move_file(oldPath, newPath)

Moves/renames, with a copy+delete fallback across drives.

## get_file_info(path)

Returns path, size, modified timestamp (`%YYYY-%MM-%DD %HH:%II:%SS`), and
whether the target is a directory.

## search_files(path, pattern)

Case-insensitive text search, recursive: `path:line: text`, max 100 results,
depth 32, 10 000 entries, 10 s budget. Binary-looking extensions (exe, dll,
so, dylib, o, ppu, obj, bin, a, lib) are skipped.

## change_root(newRoot, secret) — sensitive

Switches the allowed root at runtime. Requires the server to be started with
`MCP_ROOT_SECRET`, and refuses a root that is itself a symlink/junction.
Typical use: point the session at another project directory.

## exec(command | commands, workdir?, timeoutMs?, confirm) — human-gated

Runs a shell command: `cmd.exe` on Windows, `bash` (fallback `/bin/sh`)
elsewhile, in a temporary script, working directory confined under the root.

- `command` (string) XOR `commands` (array, max 20 lines, one shared shell).
- `workdir`: optional, must resolve under the root (default: the root).
- `timeoutMs`: default 10000, clamped to 1000–60000. Timeout kills the
  process and returns `Echec : commande interrompue apres N ms (timeout).`
- `confirm`: must be `true`, and must come from a human approval — see the
  workflow in SKILL.md.

Success output:

```
Commande executee.
Repertoire : C:\work
Code de sortie : 0
Duree : 45 ms
--- Sortie (stdout+stderr) ---
<merged output>
```

Non-zero exit code → `Echec : commande terminee avec le code N.` and
`isError: true`. Output is capped at 64 KiB (`[... sortie tronquee ...]`).

Batch example (one approval for the whole lot):

```json
{"name":"exec","arguments":{
  "commands":["cd build","dir /b","echo lot termine"],
  "confirm":true}}
```
