# Plan d’implémentation — limites fichier 2 Mio et serveur MCP Free Pascal

> **Pour l’agent d’exécution :** compétence requise : `superpowers:executing-plans`. Les étapes utilisent des cases `- [ ]` à cocher. Exécution **inline uniquement** : l’utilisateur a interdit l’usage de sous-agents.

**Objectif :** porter la lecture `fileMCP` à une limite unique de 2 Mio et ajouter un serveur `fpcMCP` synchrone, borné et sans shell pour compiler Free Pascal vers six cibles.

**Architecture :** extraire la validation de chemins dans `src/fs_guard.pbi`, la réutiliser dans `fileMCP` et `fpc_core.pbi`, puis créer `src/fpcMCP.pb` comme point d’entrée standard de la suite. `fpc_core.pbi` résout un compilateur de confiance, construit une table fixe de cibles, écrit un fichier de réponse Free Pascal et exécute `RunProgram()` directement avec stdout/stderr, timeout et sorties bornés.

**Pile technique :** PureBasic 6.4x, bibliothèque Process native PureBasic, transport MCP HTTP existant, tests PureBasic console et tests d’intégration Python standard.

## Contraintes globales

- Ne modifier aucun fichier hors de `C:\Users\micka\4QWEN\MCPserver-HTTPSuite\src`.
- Limite de lecture exacte : `2 * 1024 * 1024` octets.
- Ne jamais exécuter le binaire compilé par `fpc_compile`.
- Ne jamais assembler de commande via `cmd.exe`, `/bin/sh` ou tout autre shell dans `fpcMCP`.
- Aucun argument libre ne peut modifier le compilateur ou ses options.
- Timeout FPC : 60 000 ms par défaut, borné entre 1 000 et 300 000 ms.
- stdout et stderr FPC : borne de 64 Kio chacun.
- Port par défaut de `fpcMCP` : 8109 (8108 est déjà pris par `githubMCP`), toujours surchargeable par `MCP_HTTP_PORT`.
- Les scripts parent `../build.bat` et `../build.sh` ne sont pas modifiés ; livrer `src/fpcMCP.build.patch`.
- Si `pbcompiler` ou `fpc` est absent du `PATH`, un test peut être marqué `SKIP`, mais aucune étape ne doit présenter un test non exécuté comme réussi.
- Ne pas exécuter `git add` ou `git commit` sans validation explicite de l’utilisateur pour le lot courant.

---

### Tâche 1 : gardien commun de chemins et racine initiale stricte

**Fichiers :**
- Créer : `src/fs_guard.pbi`
- Modifier : `src/fileMCP.pb`
- Créer : `src/test_fs_guard.pb`

**Interfaces :**
- Consomme : primitives natives PureBasic `FileSize`, `GetFileAttributes_`, `GetFileAttributes`, `GetCurrentDirectory`.
- Produit pour les tâches 1, 2 et 4 :
  - `FSSeparator() -> string`
  - `FSEnsureTrailingSlash(Path) -> string`
  - `FSNormalizePath(Path) -> string`
  - `FSIsLinkOrJunction(Path) -> integer`
  - `FSPathHasLinkInRoot(FullPath, FullRoot) -> integer`
  - `FSPrepareRoot(Root) -> string` (`""` = racine invalide)
  - `FSValidatePath(CheminDemande, AllowedRoot) -> string` (`""` = refus)

- [ ] **Étape 1 : écrire le test PureBasic**

Créer `src/test_fs_guard.pb` :

```purebasic
; ============================================================================
; test_fs_guard.pb - Tests du gardien commun de chemins
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "fs_guard.pbi"

Global G_Passed.i = 0
Global G_Failed.i = 0

Procedure Check(Cond.i, Name.s)
  If Cond
    G_Passed + 1
    SendStderrLine("[OK]   " + Name)
  Else
    G_Failed + 1
    SendStderrLine("[FAIL] " + Name)
  EndIf
EndProcedure

Procedure CheckStartsWith(Actual.s, Prefix.s, Name.s)
  Check(Bool(Left(Actual, Len(Prefix)) = Prefix), Name)
EndProcedure

If Not CheckRuntime()
  End 1
EndIf

Global Root.s = GetTemporaryDirectory() + "mcp_fs_guard_test_" + Str(Date()) + "_" + Str(Random(1000000))
Global Work.s = Root + FSSeparator() + "sous" + FSSeparator() + "dossier"
; CreateDirectory ne cree qu'un seul niveau a la fois : on descend progressivement.
CreateDirectory(Root)
CreateDirectory(Root + FSSeparator() + "sous")
CreateDirectory(Work)
; PARANO PB : une comparaison passee en argument doit etre enveloppee dans Bool().
Check(Bool(FileSize(Root) = -2), "racine temporaire creee")
Check(Bool(FileSize(Work) = -2), "sous-dossier cree")

Global Prepared.s = FSPrepareRoot(Root)
Check(Bool(Prepared <> ""), "racine absolue acceptee")
Check(Bool(FSIsLinkOrJunction(Prepared) = #False), "racine ordinaire non detectee comme lien")

Global Current.s = FSPrepareRoot("")
Check(Bool(Current <> ""), "racine vide remplacee par le repertoire courant")
Check(Bool(FileSize(Current) = -2), "repertoire courant existant")

Global Valid.s = FSValidatePath("sous" + FSSeparator() + ".." + FSSeparator() + "sous" + FSSeparator() + "dossier", Root)
CheckStartsWith(Valid, Prepared, "chemin normalise sous la racine")
Check(Bool(FSValidatePath(".." + FSSeparator() + "escape.txt", Root) = ""), "traversal parent refuse")
Check(Bool(FSValidatePath("sous" + FSSeparator() + ".." + FSSeparator() + ".." + FSSeparator() + "escape.txt", Root) = ""), "double traversal refuse")
Check(Bool(FSValidatePath(Prepared + FSSeparator() + "sous" + FSSeparator() + "dossier", Root) <> ""), "chemin absolu sous la racine accepte")
Check(Bool(FSValidatePath(Prepared + "_autre" + FSSeparator() + "x.txt", Root) = ""), "prefixe voisin refuse")

DeleteDirectory(Root, "", #PB_FileSystem_Recursive)

SendStderrLine("---")
SendStderrLine("test_fs_guard : " + Str(G_Passed) + " reussis, " + Str(G_Failed) + " echoues")
If G_Failed > 0
  End 1
EndIf
```

- [ ] **Étape 2 : créer `src/fs_guard.pbi`**

```purebasic
; ============================================================================
; fs_guard.pbi - Gardien commun de chemins MCP
; ============================================================================
; INTENTION
; Garantir qu'un chemin demande reste sous une racine autorisee et ne
; traverse pas un lien symbolique/junction.
;
; CONTRAT
; FSPrepareRoot retourne une racine absolue normalisee, ou "" si elle est
; absente, non directory ou en lien. FSValidatePath retourne un chemin complet
; normalise sous la racine, ou "" sans toucher au disque metier.
;
; PARANO
; La validation est lexicale ET structurelle : les ".." sont normalises avant
; le test de prefixe, puis chaque composant sous la racine est verifie comme
; un lien potentiel. La racine elle-meme est aussi verifiee ici : accepter
; une racine en lien rendrait le reste de la validation inutile.
; ============================================================================

Procedure.s FSSeparator()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ProcedureReturn "\"
  CompilerElse
    ProcedureReturn "/"
  CompilerEndIf
EndProcedure

Procedure.s FSEnsureTrailingSlash(Path.s)
  Protected Sep.s = FSSeparator()
  If Right(Path, 1) <> "/" And Right(Path, 1) <> "\"
    ProcedureReturn Path + Sep
  EndIf
  ProcedureReturn Path
EndProcedure

Procedure.i FSPathIsAbsolute(Path.s)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If Mid(Path, 2, 1) = ":" Or Left(Path, 1) = "\" Or Left(Path, 1) = "/"
      ProcedureReturn #True
    EndIf
  CompilerElse
    If Left(Path, 1) = "/"
      ProcedureReturn #True
    EndIf
  CompilerEndIf
  ProcedureReturn #False
EndProcedure

Procedure.s FSNormalizePath(Path.s)
  Protected Sep.s = FSSeparator()
  Path = ReplaceString(ReplaceString(Path, "/", Sep), "\", Sep)

  Protected Prefix.s = ""
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If Mid(Path, 2, 1) = ":"
      Prefix = Left(Path, 2)
      Path = Mid(Path, 3)
    EndIf
  CompilerElse
    If Left(Path, 1) = "/"
      Prefix = "/"
      Path = Mid(Path, 2)
    EndIf
  CompilerEndIf

  NewList Segments.s()
  Protected i.i, Count.i = CountString(Path, Sep) + 1
  Protected Part.s

  For i = 1 To Count
    Part = Trim(StringField(Path, i, Sep))
    If Part = "" Or Part = "."
      ; Segment vide ou neutre : rien a ajouter.
    ElseIf Part = ".."
      ; Remonter sans jamais sortir par effet de bord.
      If ListSize(Segments()) > 0
        LastElement(Segments())
        DeleteElement(Segments())
      EndIf
    Else
      AddElement(Segments())
      Segments() = Part
    EndIf
  Next

  Protected Result.s = Prefix
  ForEach Segments()
    If Result = "" Or Result = "/"
      Result + Segments()
    ElseIf Right(Result, 1) = ":"
      Result + Sep + Segments()
    Else
      Result + Sep + Segments()
    EndIf
  Next

  If Result = "" And Prefix <> ""
    Result = Prefix
  EndIf

  ProcedureReturn Result
EndProcedure

Procedure.i FSIsLinkOrJunction(Path.s)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; FILE_ATTRIBUTE_REPARSE_POINT : le point d'entree peut etre une junction
    ; ou un lien symbolique. GetFileAttributesW ne suit pas ce lien ici.
    Protected Attr.i = GetFileAttributes_(Path)
    If Attr = -1 Or Attr = $FFFFFFFF : ProcedureReturn #False : EndIf
    ProcedureReturn Bool((Attr & $400) <> 0)
  CompilerElse
    Protected Attr.i = GetFileAttributes(Path)
    If Attr = -1 : ProcedureReturn #False : EndIf
    ProcedureReturn Bool((Attr & #PB_FileSystem_Link) <> 0)
  CompilerEndIf
EndProcedure

Procedure.i FSPathHasLinkInRoot(FullPath.s, FullRoot.s)
  If Len(FullPath) <= Len(FullRoot) : ProcedureReturn #False : EndIf
  Protected Rel.s = Mid(FullPath, Len(FullRoot) + 1)
  Protected Sep.s = FSSeparator()
  Protected Count.i = CountString(Rel, Sep) + 1
  Protected Prefix.s = FullRoot
  Protected i.i, Part.s

  For i = 1 To Count
    Part = StringField(Rel, i, Sep)
    If Part <> ""
      Prefix = FSEnsureTrailingSlash(Prefix) + Part
      ; Verifier le lien avant FileSize : un lien casse aurait FileSize=-1.
      If FSIsLinkOrJunction(Prefix) : ProcedureReturn #True : EndIf
      If FileSize(Prefix) = -1 : Break : EndIf
    EndIf
  Next
  ProcedureReturn #False
EndProcedure

Procedure.s FSPrepareRoot(Root.s)
  Root = Trim(Root)
  If Root = ""
    Root = GetCurrentDirectory()
  EndIf

  ; Une racine relative depend du cwd au moment de l'appel. La rendre absolue
  ; maintenant empeche toute interpretation differente plus tard.
  If Not FSPathIsAbsolute(Root)
    Root = GetCurrentDirectory() + FSSeparator() + Root
  EndIf

  Root = FSNormalizePath(Root)
  If FileSize(Root) <> -2
    ProcedureReturn ""
  EndIf
  If FSIsLinkOrJunction(Root)
    ProcedureReturn ""
  EndIf
  ProcedureReturn Root
EndProcedure

Procedure.s FSValidatePath(CheminDemande.s, AllowedRoot.s)
  CheminDemande = Trim(CheminDemande)
  If CheminDemande = ""
    ProcedureReturn ""
  EndIf

  Protected FullPath.s
  If Not FSPathIsAbsolute(CheminDemande)
    FullPath = FSNormalizePath(FSEnsureTrailingSlash(AllowedRoot) + CheminDemande)
  Else
    FullPath = FSNormalizePath(CheminDemande)
  EndIf

  Protected FullRoot.s = FSEnsureTrailingSlash(FSNormalizePath(AllowedRoot))
  Protected NormPath.s, NormRoot.s

  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ; Les chemins Windows sont insensibles a la casse.
    NormPath = UCase(FSEnsureTrailingSlash(FullPath))
    NormRoot = UCase(FullRoot)
  CompilerElse
    NormPath = FSEnsureTrailingSlash(FullPath)
    NormRoot = FullRoot
  CompilerEndIf

  ; Le slash final dans NormRoot empeche C:\root de valider C:\root_evil.
  If Left(NormPath, Len(NormRoot)) <> NormRoot
    ProcedureReturn ""
  EndIf

  ; Un lien dans n'importe quel composant sous la racine peut faire sortir le
  ; noyau filesystem de la zone logique autorisee : on refuse avant ouverture.
  If FSPathHasLinkInRoot(FullPath, FullRoot)
    ProcedureReturn ""
  EndIf

  ProcedureReturn FullPath
EndProcedure
```

- [ ] **Étape 3 : inclure le gardien dans `fileMCP.pb`**

Après les `IncludeFile` communs de `src/fileMCP.pb`, ajouter :

```purebasic
IncludeFile "fs_guard.pbi"
```

Remplacer les corps de `GetPathSeparator`, `EnsureTrailingSlash`, `NormalizePath`, `IsLinkOrJunction`, `PathHasLinkInRoot` et `ValiderChemin` par :

```purebasic
Procedure.s GetPathSeparator()
  ProcedureReturn FSSeparator()
EndProcedure

Procedure.s EnsureTrailingSlash(Path.s)
  ProcedureReturn FSEnsureTrailingSlash(Path)
EndProcedure

Procedure.s NormalizePath(Path.s)
  ProcedureReturn FSNormalizePath(Path)
EndProcedure

Procedure.i IsLinkOrJunction(Path.s)
  ProcedureReturn FSIsLinkOrJunction(Path)
EndProcedure

Procedure.i PathHasLinkInRoot(FullPath.s, FullRoot.s)
  ProcedureReturn FSPathHasLinkInRoot(FullPath, FullRoot)
EndProcedure

Procedure.s ValiderChemin(CheminDemande.s)
  ProcedureReturn FSValidatePath(CheminDemande, G_AllowedRoot)
EndProcedure
```

Conserver `NativeCreateDirectories` inchangé.

- [ ] **Étape 4 : durcir la racine initiale**

Dans le programme principal de `src/fileMCP.pb`, remplacer :

```purebasic
G_AllowedRoot = GetEnvironmentVariable("MCP_ROOT")
If G_AllowedRoot = ""
  G_AllowedRoot = GetCurrentDirectory()
EndIf
G_AllowedRoot = NormalizePath(G_AllowedRoot)
```

par :

```purebasic
; La racine vient de l'environnement, mais elle doit etre absolue et reelle :
; un lien ici contournerait toute la validation effectuee sous cette racine.
G_AllowedRoot = FSPrepareRoot(GetEnvironmentVariable("MCP_ROOT"))
If G_AllowedRoot = ""
  LogError("MCP_ROOT invalide : repertoire introuvable ou lien symbolique/junction.")
  End 1
EndIf
LogDebug("Racine autorisee : " + G_AllowedRoot)
```

- [ ] **Étape 5 : compiler et exécuter le test**

Depuis `C:\Users\micka\4QWEN\MCPserver-HTTPSuite\src` :

```bash
mkdir -p build-test
PBC="${PBCOMPILER:-}"
if [ -z "$PBC" ]; then PBC="$(command -v pbcompiler || true)"; fi
if [ -z "$PBC" ]; then
  echo "SKIP: pbcompiler absent du PATH et PBCOMPILER non defini."
else
  case "$PBC" in
    *.exe)
      "$PBC" test_fs_guard.pb /EXE build-test/test_fs_guard.exe /CONSOLE /UNICODE /THREAD
      ./build-test/test_fs_guard.exe
      ;;
    *)
      "$PBC" test_fs_guard.pb -o build-test/test_fs_guard -cl -t
      ./build-test/test_fs_guard
      ;;
  esac
fi
```

Résultat attendu : tous les tests `[OK]`, ou `SKIP` explicite si PureBasic n’est pas visible depuis le shell.

- [ ] **Étape 6 : commit**

Après validation explicite de l’utilisateur :

```bash
git add fs_guard.pbi fileMCP.pb test_fs_guard.pb
git commit -m "Refactor: gardien commun de chemins et racine stricte"
```

---

### Tâche 2 : limite unique de lecture 2 Mio dans `fileMCP`

**Fichiers :**
- Modifier : `src/fileMCP.pb`
- Créer : `src/test_file_limits.py`

**Interfaces :**
- Consomme : `FSValidatePath` de la tâche 1 et exécutable `src/build/fileMCP.exe` ou `src/build/fileMCP`.
- Produit : constante `#FILE_MAX_READ_BYTES`, catalogue annonçant 2 Mio pour `read_file`, `read_file_lines` et `search_files`.

- [ ] **Étape 1 : écrire le test d’intégration**

Créer `src/test_file_limits.py` :

```python
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
            check(len(text.encode("utf-8")) <= LIMIT + 200, "read_file borne la sortie")

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
```

- [ ] **Étape 2 : ajouter la constante**

Dans `src/fileMCP.pb`, remplacer :

```purebasic
#MAX_SEARCH_DEPTH   = 32
#MAX_SEARCH_ENTRIES = 10000
#SEARCH_TIMEOUT_MS  = 10000
```

par :

```purebasic
#FILE_MAX_READ_BYTES = 2 * 1024 * 1024
#MAX_SEARCH_DEPTH   = 32
#MAX_SEARCH_ENTRIES = 10000
#SEARCH_TIMEOUT_MS  = 10000
```

- [ ] **Étape 3 : modifier `ToolReadFile`**

Dans `src/fileMCP.pb`, remplacer le bloc de calcul/lecture actuel par :

```purebasic
  Protected Size.q = Lof(FileNum)
  Protected BytesToRead.q = Size
  Protected Truncated.i = #False

  ; Borne unique : la meme constante sert a la lecture directe, la lecture
  ; par lignes et la recherche. Ne pas laisser 20000 ici : le catalogue et le
  ; comportement divergeraient silencieusement.
  If BytesToRead > #FILE_MAX_READ_BYTES
    BytesToRead = #FILE_MAX_READ_BYTES
    Truncated = #True
  EndIf

  Protected *Buffer = AllocateMemory(BytesToRead + 1)
  Protected Content.s = ""
  If *Buffer
    ; Ne jamais decoder plus d'octets que ReadData n'en a reellement lus.
    Protected ReadBytes.q = ReadData(FileNum, *Buffer, BytesToRead)
    If ReadBytes < 0 : ReadBytes = 0 : EndIf
    PokeB(*Buffer + ReadBytes, 0)
    Content = PeekS(*Buffer, ReadBytes, #PB_UTF8 | #PB_ByteLength)
    FreeMemory(*Buffer)
  EndIf
  CloseFile(FileNum)

  If Truncated
    Content + #LF$ + "[... Tronque au-dela de " + Str(#FILE_MAX_READ_BYTES) + " octets ...]"
  EndIf
  ProcedureReturn Content
```

- [ ] **Étape 4 : modifier `ToolReadFileLines`**

Remplacer :

```purebasic
  If FileSize(SafePath) > 5 * 1024 * 1024 : ProcedureReturn "Fichier depasse la limite de 5 Mo." : EndIf
```

par :

```purebasic
  ; Lecture ligne par ligne != lecture moins couteuse : une ligne peut etre
  ; enorme. La borne de fichier reste donc identique a read_file.
  If FileSize(SafePath) > #FILE_MAX_READ_BYTES
    ProcedureReturn "Fichier depasse la limite de 2 Mio."
  EndIf
```

- [ ] **Étape 5 : modifier `SearchRecursive`**

Remplacer :

```purebasic
            If Not IsBinaryFile(Full) And DirectoryEntrySize(Dir) <= 2 * 1024 * 1024
```

par :

```purebasic
            If Not IsBinaryFile(Full) And DirectoryEntrySize(Dir) <= #FILE_MAX_READ_BYTES
```

- [ ] **Étape 6 : mettre à jour le catalogue**

Dans `BuildToolsCatalog()` de `src/fileMCP.pb`, remplacer les deux définitions concernées par :

```purebasic
  ToolDef(ToolsArr, "read_file", "Lire un fichier texte (tronque au-dela de 2 Mio)", "path|string|Chemin du fichier", "path")
  ToolDef(ToolsArr, "read_file_lines", "Lire une plage de lignes (fichier limite a 2 Mio)", "path|string|Chemin;startLine|integer|Ligne de depart (defaut:1);maxLines|integer|Nombre de lignes (defaut:50)", "path")
```

- [ ] **Étape 7 : compiler `fileMCP` vers `src/build`**

```bash
mkdir -p build
PBC="${PBCOMPILER:-}"
if [ -z "$PBC" ]; then PBC="$(command -v pbcompiler || true)"; fi
if [ -z "$PBC" ]; then
  echo "SKIP: pbcompiler absent du PATH et PBCOMPILER non defini."
else
  case "$PBC" in
    *.exe)
      "$PBC" fileMCP.pb /EXE build/fileMCP.exe /CONSOLE /UNICODE /THREAD
      ;;
    *)
      "$PBC" fileMCP.pb -o build/fileMCP -cl -t
      ;;
  esac
fi
```

- [ ] **Étape 8 : exécuter le test 2 Mio**

```bash
python test_file_limits.py
```

Résultat attendu : `Tests 2 Mio : tous reussis`. Si le binaire n’a pas pu être compilé à l’étape 7, résultat attendu : `SKIP: fileMCP introuvable...`.

- [ ] **Étape 9 : commit**

Après validation explicite :

```bash
git add fileMCP.pb test_file_limits.py
git commit -m "Feat: limite unique de lecture 2 Mio"
```

---

### Tâche 3 : cibles, configuration et validation FPC

**Fichiers :**
- Créer : `src/fpc_core.pbi`
- Créer : `src/test_fpc_core_base.pb`

**Interfaces :**
- Consomme : `FSPrepareRoot`, `FSValidatePath`, `FSIsLinkOrJunction` de `src/fs_guard.pbi`.
- Produit pour les tâches 4 et 5 :
  - `FpcConfigure(Root, DefaultCompiler, TimeoutMs)`
  - `FpcTargetIndex(TargetId) -> integer` (`-1` = inconnu)
  - `FpcResolveCompiler(TargetIndex, *Origin.Integer) -> string`
  - `FpcValidateOutputName(Name) -> integer`
  - `FpcValidateSource(SourcePath) -> string` (`""` = OK, chemin dans `G_FpcSafeSource`)
  - `FpcCreateDirectories(Path) -> integer`
  - `FpcPrepareBuildDirs(TargetIndex) -> integer` (chemins dans `G_FpcExeDir` / `G_FpcUnitDir`)
  - `FpcInitTargets()`

> **Écart de compilation 1 (obligatoire) :** PureBasic n'autorise pas une comparaison en argument de procédure ; chaque `Check(a = b, ...)` doit être écrit `Check(Bool(a = b), ...)`.
>
> **Écart de compilation 2 (obligatoire) :** un paramètre `*Out.String` écrit via `*Out\s = ...` n'est **pas** une sortie fiable (écriture perdue sur chaîne vide, segmentation fault sur buffer prédimensionné — vérifié par sonde). Les sorties chaînes passent par des globales `G_FpcSafeSource`, `G_FpcExeDir`, `G_FpcUnitDir` lues juste après l'appel. Les pointeurs typés restent valables pour les entiers (`*Origin.Integer` avec `*Origin\i`, vérifié).

- [ ] **Étape 1 : écrire le test de base**

Créer `src/test_fpc_core_base.pb` :

```purebasic
; ============================================================================
; test_fpc_core_base.pb - Tests table cibles, resolveur et validation FPC
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "fs_guard.pbi"
IncludeFile "fpc_core.pbi"

Global G_Passed.i = 0
Global G_Failed.i = 0

Procedure Check(Cond.i, Name.s)
  If Cond
    G_Passed + 1
    SendStderrLine("[OK]   " + Name)
  Else
    G_Failed + 1
    SendStderrLine("[FAIL] " + Name)
  EndIf
EndProcedure

If Not CheckRuntime()
  End 1
EndIf

Global Root.s = GetTemporaryDirectory() + "mcp_fpc_base_" + Str(Date()) + "_" + Str(Random(1000000))
CreateDirectory(Root)
FpcConfigure(Root, "fpc", 60000)
FpcInitTargets()

; PARANO PB : toute comparaison passee en argument doit etre enveloppee dans Bool().
Check(Bool(FpcTargetIndex("win32") = 0), "win32 present")
Check(Bool(FpcTargetIndex("WIN64") = 1), "win64 insensible a la casse")
Check(Bool(FpcTargetIndex("linux32") = 2), "linux32 present")
Check(Bool(FpcTargetIndex("linux64") = 3), "linux64 present")
Check(Bool(FpcTargetIndex("linux-aarch64") = 4), "linux-aarch64 present")
Check(Bool(FpcTargetIndex("macos-aarch64") = 5), "macos-aarch64 present")
Check(Bool(FpcTargetIndex("amiga-mos") = -1), "cible inconnue refusee")

Global Origin.i = 0
Global Compiler.s = FpcResolveCompiler(1, @Origin)
Check(Bool(Compiler = "fpc"), "compilateur general par defaut")
Check(Bool(Origin = 2), "origine configuration generale signalee")

SetEnvironmentVariable("MCP_FPC_WIN64", "C:\Tools\fpc-win64.exe")
Compiler = FpcResolveCompiler(1, @Origin)
Check(Bool(Compiler = "C:\Tools\fpc-win64.exe"), "variable dediee prioritaire")
Check(Bool(Origin = 1), "origine variable dediee signalee")
RemoveEnvironmentVariable("MCP_FPC_WIN64")

G_FpcCompilerDefault = "C:\Tools\fpc-custom.exe"
Compiler = FpcResolveCompiler(1, @Origin)
Check(Bool(Compiler = "C:\Tools\fpc-custom.exe"), "MCP_FPC general prioritaire sur PATH")
Check(Bool(Origin = 2), "origine MCP_FPC generale signalee")
G_FpcCompilerDefault = "fpc"

Check(FpcValidateOutputName("hello"), "nom simple accepte")
Check(FpcValidateOutputName("hello-1.2_x"), "nom avec tirets point underscore accepte")
Check(Bool(Not FpcValidateOutputName("")), "nom vide refuse")
Check(Bool(Not FpcValidateOutputName(".hidden")), "nom initial point refuse")
Check(Bool(Not FpcValidateOutputName("bad..name")), "double point refuse")
Check(Bool(Not FpcValidateOutputName("bad name")), "espace refuse")
Check(Bool(Not FpcValidateOutputName("bad/name")), "slash refuse")
Check(Bool(Not FpcValidateOutputName("bad\name")), "backslash refuse")
Check(Bool(Not FpcValidateOutputName("bad:name")), "deux-points refuse")

Global Source.s = Root + FSSeparator() + "hello world.pas"
Global F.i = CreateFile(#PB_Any, Source)
WriteString(F, "program hello;" + #LF$ + "begin end." + #LF$, #PB_UTF8)
CloseFile(F)

Global Safe.s = ""
Check(Bool(FpcValidateSource("hello world.pas") = ""), "source relative acceptee")
Safe = G_FpcSafeSource
Check(Bool(Safe = Source), "source normalisee absolue")
Check(Bool(FpcValidateSource(".."+FSSeparator()+"escape.pas") <> ""), "source hors racine refusee")
Check(Bool(FpcValidateSource("missing.pas") <> ""), "source absente refusee")

Check(FpcPrepareBuildDirs(3), "repertoires linux64 crees")
Check(Bool(FileSize(G_FpcExeDir) = -2), "repertoire executable cree")
Check(Bool(FileSize(G_FpcUnitDir) = -2), "repertoire unites cree")

DeleteDirectory(Root, "", #PB_FileSystem_Recursive)

SendStderrLine("---")
SendStderrLine("test_fpc_core_base : " + Str(G_Passed) + " reussis, " + Str(G_Failed) + " echoues")
If G_Failed > 0
  End 1
EndIf
```

- [ ] **Étape 2 : créer le socle `src/fpc_core.pbi`**

```purebasic
; ============================================================================
; fpc_core.pbi - Coeur metier du serveur MCP Free Pascal
; ============================================================================
; INTENTION
; Exposer six cibles Free Pascal sans jamais laisser le client choisir une
; commande libre.
;
; CONTRAT
; Les procedures ToolFpc* retournent du texte destiné au payload MCP. Les
; procedures Fpc* internes valident avant tout effet de bord.
;
; PARANO
; Le compilateur est un binaire de confiance choisi par configuration, pas un
; chemin envoye par le projet. Les chemins utilisateur passent par fs_guard.
; Les options sont issues d'une table interne et d'un fichier de reponse.
; ============================================================================

#FPC_STREAM_LIMIT = 65536
#FPC_TARGET_COUNT = 6

Structure FpcTarget
  Id.s
  Cpu.s
  Os.s
  Args.s
  EnvName.s
EndStructure

Structure FpcResult
  ExitCode.i
  TimedOut.i
  DurationMs.i
  StdOut.s
  StdErr.s
EndStructure

Global Dim FpcTargets.FpcTarget(5)
Global G_FpcTargetsReady.i = #False
Global G_FpcRoot.s = ""
Global G_FpcCompilerDefault.s = "fpc"
Global G_FpcTimeoutMs.i = 60000

; ---------------------------------------------------------------------------
; Variables de sortie (idempotence PureBasic)
; ---------------------------------------------------------------------------
; PARANO PB : un pointeur type *.String N'EST PAS une sortie fiable. L'affectation
; *Ptr\s = valeur copie dans le buffer existant sans le redimensionner (ecriture
; silencieusement perdue sur chaine vide) et peut meme planter. La convention
; du projet est donc : la procedure retourne un code/erreur et ecrit ses
; sorties chaines dans des globales G_Fpc* dediees, lues immediatement par
; l'appelant. Les pointeurs types restent reserves aux entiers (*p.Integer),
; dont l'ecriture par *p\i est fiable et verifiee.
; ---------------------------------------------------------------------------
Global G_FpcSafeSource.s = ""
Global G_FpcExeDir.s = ""
Global G_FpcUnitDir.s = ""

Procedure FpcInitTargets()
  If G_FpcTargetsReady : ProcedureReturn : EndIf

  FpcTargets(0)\Id = "win32"
  FpcTargets(0)\Cpu = "i386"
  FpcTargets(0)\Os = "win32"
  FpcTargets(0)\Args = "-Pi386 -Twin32"
  FpcTargets(0)\EnvName = "MCP_FPC_WIN32"

  FpcTargets(1)\Id = "win64"
  FpcTargets(1)\Cpu = "x86_64"
  FpcTargets(1)\Os = "win64"
  FpcTargets(1)\Args = "-Px86_64 -Twin64"
  FpcTargets(1)\EnvName = "MCP_FPC_WIN64"

  FpcTargets(2)\Id = "linux32"
  FpcTargets(2)\Cpu = "i386"
  FpcTargets(2)\Os = "linux"
  FpcTargets(2)\Args = "-Pi386 -Tlinux"
  FpcTargets(2)\EnvName = "MCP_FPC_LINUX32"

  FpcTargets(3)\Id = "linux64"
  FpcTargets(3)\Cpu = "x86_64"
  FpcTargets(3)\Os = "linux"
  FpcTargets(3)\Args = "-Px86_64 -Tlinux"
  FpcTargets(3)\EnvName = "MCP_FPC_LINUX64"

  FpcTargets(4)\Id = "linux-aarch64"
  FpcTargets(4)\Cpu = "aarch64"
  FpcTargets(4)\Os = "linux"
  FpcTargets(4)\Args = "-Paarch64 -Tlinux"
  FpcTargets(4)\EnvName = "MCP_FPC_LINUX_AARCH64"

  FpcTargets(5)\Id = "macos-aarch64"
  FpcTargets(5)\Cpu = "aarch64"
  FpcTargets(5)\Os = "darwin"
  FpcTargets(5)\Args = "-Paarch64 -Tdarwin"
  FpcTargets(5)\EnvName = "MCP_FPC_MACOS_AARCH64"

  G_FpcTargetsReady = #True
EndProcedure

Procedure FpcConfigure(Root.s, DefaultCompiler.s, TimeoutMs.i)
  G_FpcRoot = Root
  ; Chaine vide = aucune configuration generale explicite. FpcResolveCompiler
  ; retournera alors "fpc" avec l'origine PATH, ce qui garde l'origine honnete.
  G_FpcCompilerDefault = Trim(DefaultCompiler)
  If TimeoutMs < 1000 : TimeoutMs = 1000 : EndIf
  If TimeoutMs > 300000 : TimeoutMs = 300000 : EndIf
  G_FpcTimeoutMs = TimeoutMs
  FpcInitTargets()
EndProcedure

Procedure.i FpcTargetIndex(TargetId.s)
  FpcInitTargets()
  TargetId = LCase(Trim(TargetId))
  Protected i.i
  For i = 0 To #FPC_TARGET_COUNT - 1
    If FpcTargets(i)\Id = TargetId
      ProcedureReturn i
    EndIf
  Next
  ProcedureReturn -1
EndProcedure

Procedure.s FpcResolveCompiler(TargetIndex.i, *Origin.Integer)
  ; Ordre volontairement explicite : configuration locale d'abord, PATH ensuite.
  ; Le projet compile ne peut pas designer son propre executable.
  If TargetIndex >= 0 And TargetIndex < #FPC_TARGET_COUNT
    Protected Dedicated.s = Trim(GetEnvironmentVariable(FpcTargets(TargetIndex)\EnvName))
    If Dedicated <> ""
      *Origin\i = 1
      ProcedureReturn Dedicated
    EndIf
  EndIf

  If Trim(G_FpcCompilerDefault) <> ""
    *Origin\i = 2
    ProcedureReturn Trim(G_FpcCompilerDefault)
  EndIf

  *Origin\i = 3
  ProcedureReturn "fpc"
EndProcedure

Procedure.i FpcValidateOutputName(Name.s)
  Name = Trim(Name)
  If Name = "" Or Len(Name) > 128 : ProcedureReturn #False : EndIf
  If Left(Name, 1) = "." : ProcedureReturn #False : EndIf
  If FindString(Name, "..") > 0 : ProcedureReturn #False : EndIf

  Protected i.i, c.i
  For i = 1 To Len(Name)
    c = Asc(Mid(Name, i, 1))
    ; Lettres, chiffres, point, tiret, underscore. Aucun chemin, aucun espace.
    If Not ((c >= 48 And c <= 57) Or (c >= 65 And c <= 90) Or (c >= 97 And c <= 122) Or c = 46 Or c = 45 Or c = 95)
      ProcedureReturn #False
    EndIf
  Next
  ProcedureReturn #True
EndProcedure

; Retour : "" = OK (le chemin normalise est alors dans G_FpcSafeSource),
; sinon message d'erreur detaille. Pas de pointeur sortie : voir note globale.
Procedure.s FpcValidateSource(SourcePath.s)
  Protected SafePath.s = FSValidatePath(SourcePath, G_FpcRoot)
  If SafePath = ""
    ProcedureReturn "Erreur : acces refuse en dehors de MCP_FPC_ROOT ou via un lien."
  EndIf
  If FileSize(SafePath) = -2
    ProcedureReturn "Erreur : source est un repertoire, pas un fichier Pascal."
  EndIf
  If FileSize(SafePath) < 0
    ProcedureReturn "Erreur : source introuvable : " + SourcePath
  EndIf

  Protected Ext.s = LCase(GetExtensionPart(SafePath))
  If Ext <> "pas" And Ext <> "pp" And Ext <> "lpr"
    ProcedureReturn "Erreur : extension autorisee : pas, pp ou lpr."
  EndIf

  G_FpcSafeSource = SafePath
  ProcedureReturn ""
EndProcedure

Procedure.i FpcCreateDirectories(Path.s)
  Protected Sep.s = FSSeparator()
  Path = ReplaceString(ReplaceString(Path, "/", Sep), "\", Sep)

  Protected i.i, Count.i = CountString(Path, Sep) + 1
  Protected SubPath.s = "", Part.s

  For i = 1 To Count
    Part = StringField(Path, i, Sep)
    If Part <> ""
      If SubPath = ""
        CompilerIf #PB_Compiler_OS = #PB_OS_Windows
          SubPath = Part
        CompilerElse
          SubPath = "/" + Part
        CompilerEndIf
      Else
        SubPath + Sep + Part
      EndIf
      If FileSize(SubPath) = -1
        CreateDirectory(SubPath)
      EndIf
    EndIf
  Next

  ProcedureReturn Bool(FileSize(Path) = -2)
EndProcedure

; Sorties : G_FpcExeDir et G_FpcUnitDir (voir note sur les pointeurs string).
Procedure.i FpcPrepareBuildDirs(TargetIndex.i)
  If TargetIndex < 0 Or TargetIndex >= #FPC_TARGET_COUNT
    ProcedureReturn #False
  EndIf

  Protected Sep.s = FSSeparator()
  Protected Base.s = FSEnsureTrailingSlash(G_FpcRoot) + "build" + Sep + FpcTargets(TargetIndex)\Id
  Protected ExePath.s = Base
  Protected UnitPath.s = Base + Sep + "units"

  If Not FpcCreateDirectories(UnitPath)
    ProcedureReturn #False
  EndIf

  G_FpcExeDir = ExePath
  G_FpcUnitDir = UnitPath
  ProcedureReturn #True
EndProcedure
```

- [ ] **Étape 3 : compiler et exécuter le test de base**

```bash
PBC="${PBCOMPILER:-}"
if [ -z "$PBC" ]; then PBC="$(command -v pbcompiler || true)"; fi
if [ -z "$PBC" ]; then
  echo "SKIP: pbcompiler absent du PATH et PBCOMPILER non defini."
else
  case "$PBC" in
    *.exe)
      "$PBC" test_fpc_core_base.pb /EXE build-test/test_fpc_core_base.exe /CONSOLE /UNICODE /THREAD
      ./build-test/test_fpc_core_base.exe
      ;;
    *)
      "$PBC" test_fpc_core_base.pb -o build-test/test_fpc_core_base -cl -t
      ./build-test/test_fpc_core_base
      ;;
  esac
fi
```

Résultat attendu : tous les tests `[OK]`, ou `SKIP` explicite.

- [ ] **Étape 4 : commit**

Après validation explicite :

```bash
git add fpc_core.pbi test_fpc_core_base.pb
git commit -m "Feat: socle cibles et validation FPC"
```

---

### Tâche 4 : exécution directe, outils MCP et dispatch `fpcMCP`

**Fichiers :**
- Modifier : `src/fpc_core.pbi`
- Créer : `src/test_fpc_core_runner.pb`

**Interfaces :**
- Consomme : tout le socle de la tâche 3.
- Produit pour la tâche 5 :
  - `ToolFpcTargets() -> string`
  - `ToolFpcVersion(Target) -> string`
  - `ToolFpcCompile(SourcePath, TargetId, BuildMode, OutputName) -> string`
  - `FpcBuildCatalog() -> JSON handle`
  - `FpcDispatch(ToolName, ArgsObj, *IsError.Integer) -> string`
  - `FpcRunProgram(Program, Parameters, WorkingDirectory, TimeoutMs, *R.FpcResult) -> integer`

- [ ] **Étape 1 : écrire le test du runner**

Créer `src/test_fpc_core_runner.pb` :

```purebasic
; ============================================================================
; test_fpc_core_runner.pb - Tests capture stdout/stderr et borne de flux
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "fs_guard.pbi"
IncludeFile "fpc_core.pbi"

Global G_Passed.i = 0
Global G_Failed.i = 0

Procedure Check(Cond.i, Name.s)
  If Cond
    G_Passed + 1
    SendStderrLine("[OK]   " + Name)
  Else
    G_Failed + 1
    SendStderrLine("[FAIL] " + Name)
  EndIf
EndProcedure

If Not CheckRuntime()
  End 1
EndIf

; Borne de flux : on accumule dans un champ de structure FpcResult.
; PARANO PB : toute comparaison passee en argument doit etre enveloppee dans Bool().
Global R0.FpcResult
Global Big.s = ""
Global i.i
For i = 1 To 7000
  Big + "AAAAAAAAAA"
Next
FpcAppendLimited(@R0, Big, #False)
Check(Bool(Len(R0\StdOut) <= #FPC_STREAM_LIMIT + 64), "sortie bornee")
Check(Bool(FindString(R0\StdOut, "[... tronque ...]") > 0), "marqueur de tronquage present")

Global Root.s = GetTemporaryDirectory() + "mcp_fpc_runner_" + Str(Date()) + "_" + Str(Random(1000000))
CreateDirectory(Root)
FpcConfigure(Root, "fpc", 60000)
FpcInitTargets()

Global R.FpcResult

CompilerIf #PB_Compiler_OS = #PB_OS_Windows
  Global Fake.s = Root + "\fake-fpc.bat"
  Global F.i = CreateFile(#PB_Any, Fake)
  WriteString(F, "@echo off" + #CRLF$)
  WriteString(F, "echo FAKE-STDOUT" + #CRLF$)
  WriteString(F, "echo FAKE-STDERR 1>&2" + #CRLF$)
  WriteString(F, "exit /b 7" + #CRLF$)
  CloseFile(F)
  Check(Bool(FpcRunProgram("cmd.exe", "/c " + Chr(34) + Fake + Chr(34), "", 3000, @R) = 7), "fake compiler code 7")
CompilerElse
  Global Fake.s = Root + "/fake-fpc.sh"
  Global F.i = CreateFile(#PB_Any, Fake)
  WriteString(F, "#!/bin/sh" + #LF$)
  WriteString(F, "echo FAKE-STDOUT" + #LF$)
  WriteString(F, "echo FAKE-STDERR 1>&2" + #LF$)
  WriteString(F, "exit 7" + #LF$)
  CloseFile(F)
  Global OldCwd.s = GetCurrentDirectory()
  SetCurrentDirectory(Root)
  Check(Bool(FpcRunProgram("/bin/sh", "fake-fpc.sh", "", 3000, @R) = 7), "fake compiler code 7")
  SetCurrentDirectory(OldCwd)
CompilerEndIf

Check(Bool(R\TimedOut = #False), "pas de timeout")
Check(Bool(FindString(R\StdOut, "FAKE-STDOUT") > 0), "stdout capture")
Check(Bool(FindString(R\StdErr, "FAKE-STDERR") > 0), "stderr capture separee")
Check(Bool(R\ExitCode = 7), "ProgramExitCode conserve")

Global Targets.s = ToolFpcTargets()
Check(Bool(FindString(Targets, "win32") > 0), "targets contient win32")
Check(Bool(FindString(Targets, "macos-aarch64") > 0), "targets contient macos-aarch64")
Check(Bool(FindString(Targets, "MCP_FPC") > 0), "targets indique l'origine generale")

DeleteDirectory(Root, "", #PB_FileSystem_Recursive)

SendStderrLine("---")
SendStderrLine("test_fpc_core_runner : " + Str(G_Passed) + " reussis, " + Str(G_Failed) + " echoues")
If G_Failed > 0
  End 1
EndIf
```

- [ ] **Étape 2 : remplacer `src/fpc_core.pbi` par la version complète**

Conserver intégralement le socle de la tâche 3, puis ajouter après `FpcPrepareBuildDirs` :

```purebasic
; Ajoute Addition au flux StdOut (ToErr = #False) ou StdErr (ToErr = #True)
; du resultat, en bornant la longueur totale a #FPC_STREAM_LIMIT caracteres.
; PARANO PB : on ecrit dans un CHAMP de structure (*R\StdOut) via pointeur,
; operation verifiee fiable ; ecrire @VariableString\s serait perdu ou plante.
Procedure FpcAppendLimited(*R.FpcResult, Addition.s, ToErr.i)
  Protected Current.s
  If ToErr
    Current = *R\StdErr
  Else
    Current = *R\StdOut
  EndIf

  If Len(Current) >= #FPC_STREAM_LIMIT
    If Not FindString(Current, "[... tronque ...]")
      Current + "[... tronque ...]"
    EndIf
  Else
    Protected Room.i = #FPC_STREAM_LIMIT - Len(Current)
    If Len(Addition) > Room
      Addition = Left(Addition, Room)
    EndIf
    Current + Addition
    ; Marqueur unique, ajoute une seule fois, des la borne atteinte.
    If Len(Current) >= #FPC_STREAM_LIMIT And Not FindString(Current, "[... tronque ...]")
      Current + "[... tronque ...]"
    EndIf
  EndIf

  If ToErr
    *R\StdErr = Current
  Else
    *R\StdOut = Current
  EndIf
EndProcedure

Procedure.i FpcRunProgram(Program.s, Parameters.s, WorkingDirectory.s, TimeoutMs.i, *R.FpcResult)
  *R\ExitCode = -1
  *R\TimedOut = #False
  *R\DurationMs = 0
  *R\StdOut = ""
  *R\StdErr = ""

  If Trim(Program) = ""
    *R\StdErr = "Erreur : executable vide."
    ProcedureReturn -1
  EndIf
  If WorkingDirectory <> "" And FileSize(WorkingDirectory) <> -2
    *R\StdErr = "Erreur : repertoire de travail introuvable : " + WorkingDirectory
    ProcedureReturn -1
  EndIf
  If TimeoutMs < 1000 : TimeoutMs = 1000 : EndIf

  ; Aucun shell ici : RunProgram recoit un executable et une chaine d'arguments
  ; fixes. Le but est de reduire l'interpreteur disponible pour l'attaquant.
  Protected Prog.i = RunProgram(Program, Parameters, WorkingDirectory,
                                #PB_Program_Open | #PB_Program_Read |
                                #PB_Program_Error | #PB_Program_Hide)
  If Prog = 0
    *R\StdErr = "Erreur : impossible de lancer " + Program
    ProcedureReturn -1
  EndIf

  Protected StartMs.i = ElapsedMilliseconds()
  Protected Deadline.i = StartMs + TimeoutMs
  Protected ErrLine.s

  While ProgramRunning(Prog)
    If AvailableProgramOutput(Prog)
      FpcAppendLimited(*R, ReadProgramString(Prog, #PB_UTF8) + #LF$, #False)
    EndIf

    ; ReadProgramError est non bloquant : lire stderr empeche un processus
    ; verbeux de mourir sur un pipe plein.
    ErrLine = ReadProgramError(Prog, #PB_UTF8)
    If ErrLine <> ""
      FpcAppendLimited(*R, ErrLine + #LF$, #True)
    EndIf

    If ElapsedMilliseconds() > Deadline
      *R\TimedOut = #True
      KillProgram(Prog)
      Break
    EndIf
    Delay(5)
  Wend

  While AvailableProgramOutput(Prog)
    FpcAppendLimited(*R, ReadProgramString(Prog, #PB_UTF8) + #LF$, #False)
  Wend
  Repeat
    ErrLine = ReadProgramError(Prog, #PB_UTF8)
    If ErrLine <> ""
      FpcAppendLimited(*R, ErrLine + #LF$, #True)
    EndIf
  Until ErrLine = ""

  WaitProgram(Prog)
  *R\ExitCode = ProgramExitCode(Prog)
  *R\DurationMs = ElapsedMilliseconds() - StartMs
  CloseProgram(Prog)

  If *R\TimedOut
    FpcAppendLimited(*R, "Erreur : compilation arretee apres timeout." + #LF$, #True)
  EndIf

  ProcedureReturn *R\ExitCode
EndProcedure

Procedure.s FpcListFilesLimited(Dir.s, Label.s)
  Protected Res.s = Label + " :" + #LF$
  Protected Count.i = 0
  Protected D.i = ExamineDirectory(#PB_Any, Dir, "*")
  If D
    While NextDirectoryEntry(D)
      Protected Name.s = DirectoryEntryName(D)
      If Name <> "." And Name <> ".." And DirectoryEntryType(D) = #PB_DirectoryEntry_File
        Count + 1
        Res + "  " + Name + " (" + Str(DirectoryEntrySize(D)) + " octets)" + #LF$
        If Count >= 20
          Res + "  [... liste limitee a 20 fichiers ...]" + #LF$
          Break
        EndIf
      EndIf
    Wend
    FinishDirectory(D)
  EndIf
  If Count = 0
    Res + "  (aucun fichier)" + #LF$
  EndIf
  ProcedureReturn Res
EndProcedure

Procedure.s FpcResultText(TargetId.s, SourcePath.s, Compiler.s, *R.FpcResult, ExeDir.s, UnitDir.s)
  Protected Res.s = "Statut    : "
  If *R\TimedOut
    Res + "Echec (timeout)" + #LF$
  ElseIf *R\ExitCode = 0
    Res + "Reussi" + #LF$
  Else
    Res + "Echec" + #LF$
  EndIf

  Res + "Cible     : " + TargetId + #LF$
  Res + "Compilateur : " + Compiler + #LF$
  Res + "Source    : " + SourcePath + #LF$
  Res + "Code      : " + Str(*R\ExitCode) + #LF$
  Res + "Duree     : " + Str(*R\DurationMs) + " ms" + #LF$ + #LF$

  Res + "Sortie compilateur" + #LF$
  Res + "------------------" + #LF$
  If *R\StdOut = ""
    Res + "(vide)" + #LF$
  Else
    Res + *R\StdOut
  EndIf
  Res + #LF$

  Res + "Erreurs compilateur" + #LF$
  Res + "-------------------" + #LF$
  If *R\StdErr = ""
    Res + "(vide)" + #LF$
  Else
    Res + *R\StdErr
  EndIf
  Res + #LF$

  Res + "Artefacts" + #LF$
  Res + "---------" + #LF$
  Res + FpcListFilesLimited(ExeDir, "Executables")
  Res + FpcListFilesLimited(UnitDir, "Unites")
  ProcedureReturn Res
EndProcedure

Procedure.s ToolFpcTargets()
  FpcInitTargets()
  Protected Res.s = "Cibles Free Pascal :" + #LF$
  Protected i.i, Origin.i
  For i = 0 To #FPC_TARGET_COUNT - 1
    Origin = 0
    Protected Compiler.s = FpcResolveCompiler(i, @Origin)
    Protected OriginText.s = "PATH"
    If Origin = 1
      OriginText = FpcTargets(i)\EnvName
    ElseIf Origin = 2
      OriginText = "MCP_FPC"
    EndIf

    Res + "- " + FpcTargets(i)\Id + " : CPU=" + FpcTargets(i)\Cpu +
          ", OS=" + FpcTargets(i)\Os + ", args=" + FpcTargets(i)\Args +
          ", compilateur=" + Compiler + " (" + OriginText + ")" + #LF$
  Next
  ProcedureReturn Res
EndProcedure

Procedure.s ToolFpcVersion(TargetId.s)
  Protected Compiler.s = Trim(G_FpcCompilerDefault)
  If Compiler = ""
    Compiler = "fpc"
  EndIf

  If Trim(TargetId) <> ""
    Protected Index.i = FpcTargetIndex(TargetId)
    If Index < 0
      ProcedureReturn "Erreur : cible inconnue : " + TargetId
    EndIf
    Protected Origin.i
    Compiler = FpcResolveCompiler(Index, @Origin)
  EndIf

  Protected R.FpcResult
  FpcRunProgram(Compiler, "-iV", "", 10000, @R)

  Protected Res.s = "Compilateur : " + Compiler + #LF$
  If Trim(TargetId) <> ""
    Res + "Cible       : " + LCase(Trim(TargetId)) + #LF$
  EndIf
  Res + "Code        : " + Str(R\ExitCode) + #LF$
  Res + "Version     :" + #LF$
  If R\StdOut = ""
    Res + "(aucune sortie)" + #LF$
  Else
    Res + R\StdOut
  EndIf
  If R\StdErr <> ""
    Res + "Stderr      :" + #LF$ + R\StdErr
  EndIf
  ProcedureReturn Res
EndProcedure

Procedure.s ToolFpcCompile(SourcePath.s, TargetId.s, BuildMode.s, OutputName.s)
  Protected Index.i = FpcTargetIndex(TargetId)
  If Index < 0
    ProcedureReturn "Erreur : cible inconnue : " + TargetId
  EndIf

  BuildMode = LCase(Trim(BuildMode))
  If BuildMode = ""
    BuildMode = "debug"
  EndIf
  If BuildMode <> "debug" And BuildMode <> "release"
    ProcedureReturn "Erreur : buildMode doit etre debug ou release."
  EndIf

  OutputName = Trim(OutputName)
  If Not FpcValidateOutputName(OutputName)
    ProcedureReturn "Erreur : outputName invalide (nom simple : lettres, chiffres, point, tiret, underscore ; pas de chemin)."
  EndIf

  ; Interface sans pointeur sortie : "" = OK, chemin dans G_FpcSafeSource.
  Protected Bad.s = FpcValidateSource(SourcePath)
  If Bad <> ""
    ProcedureReturn Bad
  EndIf
  Protected SafeSource.s = G_FpcSafeSource

  ; Repertoires de sortie dans G_FpcExeDir / G_FpcUnitDir.
  If Not FpcPrepareBuildDirs(Index)
    ProcedureReturn "Erreur : impossible de creer les repertoires de sortie."
  EndIf
  Protected ExeDir.s = G_FpcExeDir
  Protected UnitDir.s = G_FpcUnitDir

  Protected Origin.i
  Protected Compiler.s = FpcResolveCompiler(Index, @Origin)

  ; Repertoire temporaire nomme de facon simple : l'argument passe a FPC est
  ; seulement "@mcp_fpc.rsp", donc il ne contient ni espace ni chemin projet.
  Protected TempDir.s = GetTemporaryDirectory() + "mcp_fpc_" + Str(Date()) + "_" + Str(Random(1000000))
  CreateDirectory(TempDir)
  If FileSize(TempDir) <> -2
    ProcedureReturn "Erreur : impossible de creer le repertoire temporaire."
  EndIf

  Protected Response.s = TempDir + FSSeparator() + "mcp_fpc.rsp"
  Protected F.i = CreateFile(#PB_Any, Response)
  If F = 0
    DeleteDirectory(TempDir, "", #PB_FileSystem_Recursive)
    ProcedureReturn "Erreur : impossible de creer le fichier de reponse FPC."
  EndIf

  ; Chaque option vient de la table ou d'une validation stricte. Le chemin
  ; source complet vit dans le fichier de reponse, pas dans un shell.
  WriteString(F, FpcTargets(Index)\Args + #LF$, #PB_UTF8)
  If BuildMode = "debug"
    WriteString(F, "-g" + #LF$ + "-gl" + #LF$, #PB_UTF8)
  Else
    WriteString(F, "-O2" + #LF$ + "-Xs" + #LF$, #PB_UTF8)
  EndIf
  WriteString(F, "-FE" + ExeDir + #LF$, #PB_UTF8)
  WriteString(F, "-FU" + UnitDir + #LF$, #PB_UTF8)
  If OutputName <> ""
    WriteString(F, "-o" + OutputName + #LF$, #PB_UTF8)
  EndIf
  WriteString(F, SafeSource + #LF$, #PB_UTF8)
  CloseFile(F)

  Protected R.FpcResult
  FpcRunProgram(Compiler, "@mcp_fpc.rsp", TempDir, G_FpcTimeoutMs, @R)

  Protected Res.s = FpcResultText(FpcTargets(Index)\Id, SafeSource, Compiler, @R, ExeDir, UnitDir)
  DeleteFile(Response)
  DeleteDirectory(TempDir, "", #PB_FileSystem_Recursive)
  ProcedureReturn Res
EndProcedure

Procedure.i FpcBuildCatalog()
  Protected RootJSON.i = CreateJSON(#PB_Any)
  Protected RootVal.i = SetJSONObject(JSONValue(RootJSON))
  Protected ToolsArr.i = AddJSONMember(RootVal, "tools")
  SetJSONArray(ToolsArr)

  ToolDef(ToolsArr, "fpc_targets", "Liste les six cibles Free Pascal et la resolution du compilateur", "", "")
  ToolDef(ToolsArr, "fpc_version", "Version du compilateur Free Pascal resolu", "target|string|Cible optionnelle (ex. linux64)", "")
  ToolDef(ToolsArr, "fpc_compile", "Compile un source Pascal confine dans MCP_FPC_ROOT", "sourcePath|string|Chemin du source;target|string|Cible (win32, win64, linux32, linux64, linux-aarch64, macos-aarch64);buildMode|string|debug ou release (defaut: debug);outputName|string|Nom de sortie simple (optionnel)", "sourcePath;target")

  ProcedureReturn RootJSON
EndProcedure

Procedure.s FpcDispatch(ToolName.s, ArgsObj.i, *IsError.Integer)
  Protected Result.s
  Select ToolName
    Case "fpc_targets"
      Result = ToolFpcTargets()
    Case "fpc_version"
      Result = ToolFpcVersion(GetArgString(ArgsObj, "target"))
    Case "fpc_compile"
      Result = ToolFpcCompile(GetArgString(ArgsObj, "sourcePath"),
                              GetArgString(ArgsObj, "target"),
                              GetArgString(ArgsObj, "buildMode"),
                              GetArgString(ArgsObj, "outputName"))
    Default
      *IsError\i = #True
      ProcedureReturn "Outil inconnu : " + ToolName
  EndSelect

  If FindString(Result, "Erreur :") = 1 Or FindString(Result, "Statut    : Echec") = 1
    *IsError\i = #True
  EndIf
  ProcedureReturn Result
EndProcedure
```

- [ ] **Étape 3 : compiler et exécuter le test runner**

```bash
PBC="${PBCOMPILER:-}"
if [ -z "$PBC" ]; then PBC="$(command -v pbcompiler || true)"; fi
if [ -z "$PBC" ]; then
  echo "SKIP: pbcompiler absent du PATH et PBCOMPILER non defini."
else
  case "$PBC" in
    *.exe)
      "$PBC" test_fpc_core_runner.pb /EXE build-test/test_fpc_core_runner.exe /CONSOLE /UNICODE /THREAD
      ./build-test/test_fpc_core_runner.exe
      ;;
    *)
      "$PBC" test_fpc_core_runner.pb -o build-test/test_fpc_core_runner -cl -t
      ./build-test/test_fpc_core_runner
      ;;
  esac
fi
```

Résultat attendu : tous les tests `[OK]`, ou `SKIP` explicite.

- [ ] **Étape 4 : commit**

Après validation explicite :

```bash
git add fpc_core.pbi test_fpc_core_runner.pb
git commit -m "Feat: execution FPC bornee et outils MCP"
```

---

### Tâche 5 : point d’entrée `fpcMCP.pb` et intégration réelle

**Fichiers :**
- Créer : `src/fpcMCP.pb`
- Créer : `src/test_fpc_integration.py`

**Interfaces :**
- Consomme : `FpcConfigure`, `FpcBuildCatalog`, `FpcDispatch` de la tâche 4 et transport HTTP commun.
- Produit : exécutable `src/build/fpcMCP.exe` ou `src/build/fpcMCP`.

- [ ] **Étape 1 : créer le serveur**

Créer `src/fpcMCP.pb` :

```purebasic
; ============================================================================
; SERVEUR MCP - Free Pascal (PureBasic HTTP)
; Compilation Pascal confinee a MCP_FPC_ROOT, sans shell et sans execution
; du binaire produit.
; ============================================================================
; Configuration :
;   MCP_FPC_ROOT         racine des sources/artefacts (defaut: cwd)
;   MCP_FPC              compilateur general (defaut: fpc dans le PATH)
;   MCP_FPC_WIN32        compilateur dedie win32
;   MCP_FPC_WIN64        compilateur dedie win64
;   MCP_FPC_LINUX32      compilateur dedie linux32
;   MCP_FPC_LINUX64      compilateur dedie linux64
;   MCP_FPC_LINUX_AARCH64    compilateur dedie linux-aarch64
;   MCP_FPC_MACOS_AARCH64    compilateur dedie macos-aarch64
;   MCP_FPC_TIMEOUT_MS   timeout 60000 par defaut, borne 1000..300000
; ============================================================================

EnableExplicit

IncludeFile "../mcp_common/runtime.pbi"
IncludeFile "../mcp_common/logging.pbi"
IncludeFile "../mcp_common/json_helpers.pbi"
IncludeFile "../mcp_common/protocol.pbi"
IncludeFile "../mcp_common/jsonrpc.pbi"
IncludeFile "../mcp_common/http_server.pbi"

IncludeFile "fs_guard.pbi"
IncludeFile "fpc_core.pbi"

; ---------------------------------------------------------------------------
; Configuration
; ---------------------------------------------------------------------------

; La racine est absolue et non symbolique des le demarrage. Sinon toute la
; validation faite ensuite sous cette racine pourrait commencer deja hors zone.
Global FpcRoot.s = FSPrepareRoot(GetEnvironmentVariable("MCP_FPC_ROOT"))
If FpcRoot = ""
  LogError("MCP_FPC_ROOT invalide : repertoire introuvable ou lien symbolique/junction.")
  End 1
EndIf

; Laisser la chaine vide lorsque MCP_FPC est absent : le resolveur pourra
; alors signaler honnetement que l'origine est le PATH.
Global FpcCompiler.s = Trim(GetEnvironmentVariable("MCP_FPC"))

Global TimeoutText.s = Trim(GetEnvironmentVariable("MCP_FPC_TIMEOUT_MS"))
Global TimeoutMs.i = 60000
If TimeoutText <> ""
  TimeoutMs = Val(TimeoutText)
  If TimeoutMs < 1000 : TimeoutMs = 1000 : EndIf
  If TimeoutMs > 300000 : TimeoutMs = 300000 : EndIf
EndIf

FpcConfigure(FpcRoot, FpcCompiler, TimeoutMs)

; ---------------------------------------------------------------------------
; Programme principal
; ---------------------------------------------------------------------------
G_ServerName = "FpcMCPServer-PureBasic"
G_ServerVersion = "2.0.0"
*G_ToolHandler = @FpcDispatch()
*G_CatalogBuilder = @FpcBuildCatalog()

If Not CheckRuntime()
  End 1
EndIf

LogDebug("Racine FPC : " + G_FpcRoot)
LogDebug("Compilateur FPC par defaut : " + G_FpcCompilerDefault)
LogDebug("Timeout FPC : " + Str(G_FpcTimeoutMs) + " ms")

If Not MCPHttpMainLoop(8108)
  End 1
EndIf

End
```

- [ ] **Étape 2 : créer le test d’intégration FPC**

Créer `src/test_fpc_integration.py` :

```python
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
            check(names == {"fpc_targets", "fpc_version", "fpc_compile"}, "catalogue fpcMCP")

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
```

- [ ] **Étape 3 : compiler `fpcMCP`**

```bash
mkdir -p build
PBC="${PBCOMPILER:-}"
if [ -z "$PBC" ]; then PBC="$(command -v pbcompiler || true)"; fi
if [ -z "$PBC" ]; then
  echo "SKIP: pbcompiler absent du PATH et PBCOMPILER non defini."
else
  case "$PBC" in
    *.exe)
      "$PBC" fpcMCP.pb /EXE build/fpcMCP.exe /CONSOLE /UNICODE /THREAD
      ;;
    *)
      "$PBC" fpcMCP.pb -o build/fpcMCP -cl -t
      ;;
  esac
fi
```

- [ ] **Étape 4 : exécuter l’intégration FPC**

```bash
python test_fpc_integration.py
```

Résultats acceptés :

- `tous reussis` si FPC et le binaire sont présents ;
- `SKIP: Free Pascal introuvable...` si FPC n’est pas installé ;
- `SKIP: fpcMCP introuvable...` si PureBasic n’a pas pu compiler ;
- tout autre résultat est un échec à corriger.

- [ ] **Étape 5 : commit**

Après validation explicite :

```bash
git add fpcMCP.pb test_fpc_integration.py
git commit -m "Feat: serveur MCP Free Pascal synchrone"
```

---

### Tâche 6 : patch des scripts parent et contrôle final

**Fichiers :**
- Créer : `src/fpcMCP.build.patch`
- Modifier : aucun fichier hors de `src`

**Interfaces :**
- Consomme : tâches 1 à 5.
- Produit : patch applicable aux scripts parent sans violer la contrainte de workspace.

- [ ] **Étape 1 : créer le patch à appliquer plus tard**

Créer `src/fpcMCP.build.patch` avec ce contenu exact :

```diff
--- a/build.bat
+++ b/build.bat
@@ -23,7 +23,7 @@
 
 if not exist build mkdir build
 
-for %%S in (fileMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP) do (
+for %%S in (fileMCP fpcMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP) do (
     echo Compilation de src\%%S.pb ...
     "%PBC%" "src\%%S.pb" /EXE "build\%%S.exe" /CONSOLE /UNICODE /THREAD
     if errorlevel 1 (
--- a/build.sh
+++ b/build.sh
@@ -22,7 +22,7 @@
 
 mkdir -p build
 
-for SRC in fileMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP; do
+for SRC in fileMCP fpcMCP MCP-Fetch-PB MCP-SequentialThinking-PB memoryMCP dbMCP context7MCP gitMCP githubMCP; do
     echo "Compilation de src/$SRC.pb ..."
     "$PBC" "src/$SRC.pb" -o "build/$SRC" -cl -t
 done
```

- [ ] **Étape 2 : vérifier qu’aucun fichier hors `src` n’a été modifié**

```bash
git status --short -- .. ':!src'
```

Résultat attendu : aucune ligne. Sous Git Bash, si le chemin pathspec n’est pas accepté, utiliser :

```bash
git status --short
```

puis vérifier manuellement que seuls les fichiers voulus sous `src/` sont modifiés.

- [ ] **Étape 3 : lancer les tests disponibles dans l’ordre**

```bash
python test_file_limits.py
python test_fpc_integration.py
```

Puis compiler/exécuter les tests PureBasic des tâches 1, 3 et 4 avec les commandes exactes déjà fournies. Un `SKIP` explicite est acceptable ; un échec ne l’est pas.

- [ ] **Étape 4 : contrôle statique final**

Vérifier dans `src/fpc_core.pbi` :

```bash
python - <<'PY'
from pathlib import Path
text = Path("fpc_core.pbi").read_text(encoding="utf-8")
lines = text.splitlines()
for needle in ("RunProgram(", "cmd.exe", "/bin/sh", "fpc_run"):
    hits = [f"{i + 1}: {line}" for i, line in enumerate(lines) if needle in line]
    print(f"{needle} -> {len(hits)} occurrence(s)")
    for hit in hits:
        print(hit)
PY
```

Résultat attendu :

- un seul `RunProgram(`, dans `FpcRunProgram` ;
- zéro occurrence de `cmd.exe` ;
- zéro occurrence de `/bin/sh` dans le code de production ;
- zéro occurrence de `fpc_run`.

- [ ] **Étape 5 : commit final**

Après validation explicite :

```bash
git add fpcMCP.build.patch
git commit -m "Build: patch d'ajout de fpcMCP aux scripts"
```

## Point d’attention d’exécution

Le shell actuel n’expose ni `pbcompiler` ni `fpc` dans le `PATH`. Les commandes ci-dessus traitent ce cas par `SKIP`, mais il est interdit de déclarer les tests PureBasic ou FPC réussis sans les avoir réellement exécutés. Si `PBCOMPILER` est défini dans l’environnement de l’IDE PureBasic mais pas dans Git Bash, relancer les mêmes commandes avec `PBCOMPILER` exporté.
