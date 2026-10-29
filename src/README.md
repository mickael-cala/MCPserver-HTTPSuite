# MCPserver-HTTPSuite

Suite de serveurs MCP (Model Context Protocol) écrits en **PureBasic 6.4x**, 100 % natifs (sans DLL ni runtime externe), transport JSON-RPC 2.0 sur HTTP.

Chaque serveur est un exécutable console autonome. Tous partagent le transport et le protocole de `../mcp_common/`.

## Serveurs et ports par défaut

| Serveur | Port | Rôle |
|---|---|---|
| `fileMCP` | 8101 | Gestion de fichiers confinée à une racine |
| `MCP-Fetch-PB` | 8102 | Récupération HTTP avec garde-fous SSRF |
| `MCP-SequentialThinking-PB` | 8103 | Raisonnement séquentiel |
| `memoryMCP` | 8104 | Mémoire persistante |
| `dbMCP` | 8105 | Requêtes base de données |
| `context7MCP` | 8106 | Documentation de bibliothèques |
| `gitMCP` | 8107 | Opérations Git |
| `githubMCP` | 8108 | API GitHub |
| `fpcMCP` | 8109 | Compilation Free Pascal (6 cibles) |

> Le port 8108 était initialement prévu pour `fpcMCP`, mais il est déjà utilisé par `githubMCP`. Chaque port reste surchargeable par `MCP_HTTP_PORT`.

## Configuration commune (tous serveurs)

| Variable | Rôle | Défaut |
|---|---|---|
| `MCP_HTTP_HOST` | Interface d'écoute | 127.0.0.1 |
| `MCP_HTTP_PORT` | Port (voir tableau) | port du serveur |
| `MCP_HTTP_TOKEN` | Jeton d'authentification Bearer | aucun |
| `MCP_HTTP_MAX_BODY` | Taille maximale du corps JSON | borne du serveur |
| `MCP_HTTP_ALLOWED_ORIGINS` | Origines CORS autorisées | restrictif |
| `MCP_HTTP_LOG_REQUESTS` | Journaliser les requêtes | off |

## fileMCP

**Racine obligatoire** : `MCP_ROOT` (défaut : répertoire courant). Doit être un répertoire réel, absolu, **pas un lien symbolique/junction** — sinon le serveur refuse de démarrer. Toute opération hors racine retourne `ACCES_REFUSE`, y compris via `..` ou un lien interne.

| Variable | Rôle |
|---|---|
| `MCP_ROOT` | Racine autorisée |
| `MCP_ROOT_SECRET` | Secret pour l'outil `change_root` (désactivé si vide) |

**Limites** : lecture unique de **2 Mio** (`read_file`, `read_file_lines`, recherche). Le marqueur de troncature annonce aussi la taille réelle du fichier. Recherche bornée : profondeur 32, 10 000 entrées, 10 s.

**Outils** : `list_files`, `read_file`, `read_file_lines`, `write_file`, `create_directory`, `delete_file`, `move_file`, `get_file_info`, `search_files`, `change_root`.

## fpcMCP

Compilation Free Pascal **sans shell**, synchrone et bornée. Le client choisit une cible parmi six ; il ne choisit jamais le compilateur ni ses options.

**Cibles** : `win32`, `win64`, `linux32`, `linux64`, `linux-aarch64`, `macos-aarch64`.

| Variable | Rôle | Défaut |
|---|---|---|
| `MCP_FPC_ROOT` | Racine des sources et artefacts (défaut : cwd) | cwd |
| `MCP_FPC` | Compilateur général | `fpc` dans le `PATH` |
| `MCP_FPC_WIN32` / `MCP_FPC_WIN64` / `MCP_FPC_LINUX32` / `MCP_FPC_LINUX64` / `MCP_FPC_LINUX_AARCH64` / `MCP_FPC_MACOS_AARCH64` | Compilateur dédié par cible (prioritaire) | — |
| `MCP_FPC_TIMEOUT_MS` | Timeout de compilation (1 000–300 000) | 60 000 |

**Résolution du compilateur** : variable dédiée → `MCP_FPC` → `fpc` dans le `PATH`. L'outil `fpc_targets` affiche l'origine réelle pour chaque cible.

**Garanties** : sources confinées à `MCP_FPC_ROOT` (refus des liens), sorties du compilateur bornées à 64 Kio chacune, timeout borné, jamais d'exécution du binaire produit. Les artefacts vont dans `<racine>/build/<cible>/` (exécutable) et `<racine>/build/<cible>/units/` (unités).

**Outils** : `fpc_targets`, `fpc_version`, `fpc_compile`, `fpc_clean`.

## Compilation

Scripts parent (depuis `..`) :

```bat
build.bat    :: Windows  (pbcompiler dans le PATH)
./build.sh   :: Linux/macOS
```

Les deux compilent tous les serveurs vers `../build/`. Pour ajouter `fpcMCP` aux scripts sans les modifier à la main, appliquer `fpcMCP.build.patch` (contexte vérifié le 2026-10-29).

Compilation manuelle d'un serveur :

```bash
pbcompiler src/fileMCP.pb /EXE build/fileMCP.exe /CONSOLE /UNICODE /THREAD
pbcompiler src/fpcMCP.pb  /EXE build/fpcMCP.exe  /CONSOLE /UNICODE /THREAD
```

## Tests

Tests unitaires PureBasic (console) et tests d'intégration Python (stdlib uniquement) :

```bash
python test_file_limits.py        # fileMCP : limites 2 Mio (nécessite build/fileMCP)
python test_fpc_integration.py    # fpcMCP : chaîne complète (SKIP si FPC absent)
```

Tests PureBasic (compilables avec pbcompiler, sortie sur stderr) : `test_fs_guard.pb`, `test_fpc_core_base.pb`, `test_fpc_core_runner.pb`. Un test non exécutable (compilateur absent) affiche `SKIP` — jamais compté comme réussi.

## Notes de sécurité

- Modèle de menace : client MCP potentiellement hostile. Toute entrée est validée avant tout effet de bord.
- Confinement lexical **et** structurel : normalisation des `..`, test de préfixe avec slash final (anti `root_evil`), refus des liens symboliques composant par composant.
- `fpcMCP` n'invoque aucun shell : exécution directe via `RunProgram`, options depuis une table interne, source passée par fichier de réponse `@mcp_fpc.rsp`.
- HTTP en clair : acceptable car écoute loopback par défaut. Toute exposition réseau impose `MCP_HTTP_TOKEN` + TLS en amont.
