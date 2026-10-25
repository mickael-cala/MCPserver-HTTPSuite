# Journal des versions

Ce projet suit [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) et le [versionnage sémantique](https://semver.org/lang/fr/).

## [2.0.0] - 2026-10-24

### Modifié (rupture : transport HTTP JSON + SSE optionnel)
- **Transport** : les 8 serveurs passent de JSON-RPC sur stdin/stdout à
  **JSON-RPC sur HTTP** (`POST /mcp`), avec des réponses `application/json`
  par défaut. **SSE optionnel** : `GET /mcp` + `Accept: text/event-stream`
  ouvre un flux ; `POST /mcp` répond en SSE si le client l'accepte. Aucune
  session `Mcp-Session-Id`. `DELETE /mcp` renvoie `204`.
- **Conformité transport stricte** : JSON invalide (`-32700`), lot JSON-RPC,
  réponse JSON-RPC envoyée par le client (`-32600`) renvoient désormais
  **HTTP 400** ; une requête valide avec méthode inconnue reste HTTP 200.
  Sans en-tête `MCP-Protocol-Version`, la requête est traitée comme
  `2025-03-26` (fallback de la spec).
- **Nouveau `mcp_common/runtime.pbi`** : remplace `stdio.pbi` ; écriture
  stderr multi-OS et `CheckRuntime()`. Le code stdin/stdout est supprimé.
- **Nouveau `mcp_common/http_server.pbi`** : serveur HTTP/1.1 natif
  (`CreateNetworkServer` / `NetworkServerEvent`), endpoint `POST /mcp`,
  `GET /health`, flux SSE optionnel (`text/event-stream`, keep-alive 15 s),
  parsing `Content-Length`, accumulation multi-paquets, timeout d'inactivité,
  corps maximal 1 Mio, validation `Origin`, jeton Bearer optionnel,
  `MCP-Protocol-Version`, réponses JSON ou SSE et journalisation stderr.
  Le code SSE est dans **`mcp_common/http_sse.pbi`** (inclus par
  `http_server.pbi`) pour rester sous la limite de 800 lignes/fichier de
  PureBasic Free.
- **`mcp_common/jsonrpc.pbi`** : `ProcessRequestToJSON()` indépendant du
  transport ; notifications sans réponse ; erreurs `-32700`, `-32600`,
  `-32601`, `-32603` ; `initialize` négocie `2025-06-18` / `2025-03-26`.
- **8 serveurs** : ports par défaut 8101–8108, `MCPHttpMainLoop()`, version
  `2.0.0`, en-têtes et commentaires alignés sur HTTP.
- **Scripts** : ajout de `start_all.bat/.sh` et `stop_all.bat/.sh` ; correction
  du bug de syntaxe de `run_all.sh` (lignes HTML orphelines).
- **Tests** : `tests/mcp_client.py` réécrit en client HTTP (`GET /health`,
  `POST /mcp`, SSE optionnel) ; 21 tests de transport ajoutés
  (**121 tests d'intégration**) ; robustesse adaptée au HTTP
  (**21 vérifications**) ; `test_common.pb` couvre le noyau JSON-RPC
  (**199 tests unitaires** au total).
- **Documentation** : README, AGENTS, PLAN, ROADMAP, ERRATA, CONTRIBUTING,
  SECURITY, CODE_OF_CONDUCT et modèles GitHub alignés sur
  **MCPserver-HTTPSuite** et le transport HTTP. Ajout de
  `examples/qwen-settings.json` (clé `httpUrl`, Streamable HTTP).
- **Validation** : compilation et suite complète vertes sous **Windows** et
  **Linux (WSL2 Ubuntu 26.04)** (10/10, 199 unitaires, 21 robustesse/perf,
  121 intégration). Validation macOS de la version 2.0.0 à faire.

### Corrigé (validation Linux/WSL2, 1.0.x)
- **`build.sh` / `run_all.sh`** utilisaient les options Windows (`/EXE`,
  `/CONSOLE`, `/UNICODE`) : remplacées par les options Linux/macOS
  (`-o`, `-cl`, `-t`).
- **HTTP avec en-têtes sous Linux/macOS** : implémentation via **curl**
  (fichier de configuration, aucun quoting shell) → `githubMCP` et
  `context7MCP` fonctionnent hors Windows ; `curl` requis.
- **`gitMCP` sous Linux** : `RunProgram` n'interprète pas les guillemets →
  exécution via un script `sh` temporaire ; validation explicite de
  `repoPath` (un répertoire inexistant ne fait plus exécuter git dans le
  répertoire courant).
- **`.gitattributes`** : LF forcé pour `.sh/.py/.pb/.pbi/.md/.json`
  (un shebang CRLF casse l'exécution sous WSL), CRLF pour `.bat`.
- Tests de contexte : message `-2` mis à jour (curl).
- **Suite complète validée sous WSL2 Ubuntu 26.04** : 8 serveurs compilés,
  `run_all` 10/10, 177 unitaires, 17 robustesse/perf, 100 intégration.

## [1.0.0] - 2026-10-24

### Ajouté (Phase 6 — consolidation)
- **`tests/test_robustness.py`** : T6.1 charge stdio (500 requêtes par
  défaut, 10 000 via `MCP_STRESS_REQUESTS`, stabilité de latence), T6.2 JSON
  1 Mo, T6.3 JSON malformé, T6.4 EOF brutal, T6.5 `kill` pendant une requête,
  T6.6 deux instances sur la même base, T6.7 chemin DB invalide, T6.8 coupure
  réseau Context7 ; performances T6.9–T6.14 (17 vérifications).
- **`tests/make_report.py`** + `tests/report.json` : rapport HTML par serveur.
- **`examples/mcp.json`** : configuration client complète des 8 serveurs.
- `MCP_CONTEXT7_API_BASE` : base API configurable (tests de coupure réseau).
- **Optimisation** : `create_entities` exécute une transaction SQLite unique
  (100 entités : ~900 ms → < 500 ms ; rollback sur erreur).
- `run_all` : **10/10 étapes** (ajout robustesse/perf, rapport par serveur).

### Documentation
- `AGENTS.md` restructuré : section **« Reprise du développement »**
  (bootstrap), **règle absolue de synchronisation des `.md` avant chaque
  commit** (checklist fichier par fichier), workflow de commit/push,
  architecture `mcp_common/` complète (dont `http.pbi`), et catalogue des
  pièges PureBasic rencontrés (mots réservés, structures par pointeur,
  `Status.Integer`, curseur ForEach, Trim/CRLF, JSON `~`, OpenDatabase,
  sous-processus, HTTP, formats `.pbi`/`.pbp`).
- **`PLAN.md`** : suivi des phases 0-6 (statut, livrables, définition de
  « terminé », tests par phase).
- `ROADMAP.md` réécrite (phases 0-5 terminées, reliquats par serveur).
- `CONTRIBUTING.md` : architecture `mcp_common/`, workflow `run_all`,
  conventions d'outils et de sécurité.
- `SECURITY.md` : tableau des surfaces/protections des 8 serveurs, secrets
  et recommandations de déploiement.
- `README.md` : lien vers le suivi de plan et compteurs actualisés.
- Compteurs de tests actualisés (177 unitaires, 100 intégration) dans README,
  ERRATA, AGENTS, modèles d'issues/PR.

### Ajouté (Phase 5 — GitHub)
- **`githubMCP`** : serveur MCP de l'API REST GitHub (`src/githubMCP.pb` +
  `src/github_core.pbi`) — 10 outils : `gh_get_repo`, `gh_list_issues`,
  `gh_get_issue`, `gh_create_issue`, `gh_list_pull_requests`,
  `gh_get_pull_request`, `gh_create_pull_request`, `gh_list_commits`,
  `gh_search_code`, `gh_search_repositories`.
- **`mcp_common/http.pbi`** : couche HTTP GET/POST avec en-tetes (WinHTTP
  sous Windows, timeout, HTTPS/HTTP), extraite de Context7 et partagee.
- Securite : `confirm=true` obligatoire pour toute ecriture (refus = erreur
  MCP), token jamais renvoye, pagination bornee (`per_page` max 100),
  erreurs mappees (401/403 quota/404/422/429/5xx), validation des segments
  d'URL (owner/repo/ref).
- `MCP_GITHUB_API_BASE` permet de pointer un mock ; `tests/mock_github.py`
  simule l'API (200/401/403/404/422/JSON invalide, echo des parametres).
- `tests/test_github.pb` : 40 tests unitaires hors ligne.
- Integration : 25 tests GitHub contre le mock — **100 tests au total**.
- `build`/`run_all` : 8 serveurs, 6 suites de tests unitaires (9 etapes).
- Context7 refactore sur `mcp_common/http.pbi` (code WinHTTP deduplique).

### Corrige (Phase 5)
- `SqlQuoteDb`-style : `Protected Status.Integer` (structure) utilisee comme
  scalaire dans `github_core` — remplace par `Status.i` (statut HTTP correct).
- `GhErrorText` : les statuts 2xx ne sont plus transformes en erreur.

### Corrigé (conformité PureBasic)
- **Suppression de `src/fileMCP_{Windows,Linux,macOS}.pbi`** : ces fichiers
  n'étaient pas conformes — en PureBasic, `.pbi` est l'extension des fichiers
  d'inclusion, un projet IDE est un `.pbp` ; leur contenu (sections `[PROJECT]`
  / `[X]` / `[FILE]` avec clés inventées, commentaires `;` dans les valeurs,
  chemins de sortie obsolètes) n'était pas vérifiable et ne couvrait qu'un
  serveur. Le workflow IDE est désormais documenté dans le README (ouvrir le
  `.pb`, format Console) et reste couvert par `build.bat`/`build.sh`.
  Les `.pbi` restants (`mcp_common/*`, `tests/unit_test.pbi`) sont de vrais
  modules d'inclusion, compilés et validés par les tests.

### Ajouté (Phase 4 — Git)
- **`gitMCP`** : serveur MCP d'exploration de dépôts git locaux
  (`src/gitMCP.pb` + `src/git_core.pbi`) — 7 outils : `git_is_repo`,
  `git_status`, `git_log`, `git_diff`, `git_show`, `git_branches`,
  `git_blame`.
- `GitRun()` : sous-processus git via shell avec `2>&1` (l'API Process de
  PureBasic ne lit pas stderr de façon fiable), lecture en boucle jusqu'à
  fin du processus, sortie plafonnée à 40 Ko.
- **Sécurité** : `GitSafeParam()` rejette les métacaractères shell
  (`; & | < > \` $ ( )` guillemets, retours ligne) sur tous les paramètres
  (repoPath, refs, chemins) avant exécution ; injection testée.
- `MCP_GIT_EXE` pour un git hors PATH ; arrêt propre si git absent.
- `tests/test_git.pb` : 24 tests unitaires (fixture : 4 commits, 2 branches,
  fichier modifié, chemin avec espaces, cas d'injection).
- Suite d'intégration Git dans `tests/test_mcp.py` : **75 tests au total**.
- `build`/`run_all` : 7 serveurs, 5 suites de tests unitaires (9 étapes).

### Corrigé (Phase 4)
- `cmd.exe /c` : forme `""exe" args"` requise quand la commande commence par
  un chemin entre guillemets ; arguments en guillemets doubles (validés sans
  guillemet) pour les chemins avec espaces. `TrimOut()` retire les fins de
  ligne des sorties git.

### Ajouté (Phase 3 — Context7)
- **`context7MCP`** : serveur MCP Context7 (`src/context7MCP.pb` +
  `src/context7_core.pbi`) — outils `resolve_library_id` (recherche,
  fonctionne sans cle) et `query_docs` (documentation, exige
  `MCP_CONTEXT7_API_KEY`, prefixe `ctx7sk`).
- Couche HTTP GET avec en-tetes : **WinHTTP natif** sous Windows
  (winhttp.dll, `Authorization: Bearer`), HTTP integre PureBasic sous
  Linux/macOS (cle non supportee -> message explicite).
- Mapping d'erreurs : 401 cle, 429 quota, 5xx indisponible, echec reseau,
  sans cle -> consigne explicite avant tout appel (l'API renvoie un 400
  trompeur sinon). Troncature locale `max_length`, `tokens` upstream.
- `tests/test_context7.pb` : 19 tests unitaires hors ligne.
- Suite d'integration live dans `tests/test_mcp.py` (skip propre hors
  ligne, 401 avec fausse cle) : **63 tests au total**.
- `build`/`run_all` : 6 serveurs, 4 suites de tests unitaires (8 etapes).

### Corrigé
- **Bug latent pre-existant** : `Protected Status.Integer` (structure) utilise
  comme scalaire dans `ToolFetch` (MCP-Fetch-PB) — `Str(Status)` imprimait
  l'adresse de la structure, et les comparaisons de statut HTTP etaient
  fausses (toujours vraies). Corrige en `Protected Status.i` avec passage
  `@Status` au pointeur type `*OutStatus.Integer`.

### Ajouté (Phase 2 — Database)
- **`dbMCP`** : serveur MCP d'exploration SQL (`src/dbMCP.pb` + `src/db_core.pbi`)
  — 5 outils : `db_list_schemas`, `db_list_tables`, `db_describe_table`,
  `db_execute_query`, `db_explain`. SQLite integre (`MCP_DB_PATH`) +
  PostgreSQL optionnel (`MCP_DB_POSTGRES_DSN`, `statement_timeout=30s`),
  selection par parametre `engine`.
- Garde-fou lecture seule : `IsReadOnlyQuery` (whitelist SELECT/WITH/SHOW/
  EXPLAIN/DESCRIBE, commentaires sautés, verbes d'ecriture rejetes dans les
  CTE) ; ecriture reservee a `MCP_DB_ALLOW_WRITE=1` ; refus journalises sur
  stderr. Resultats JSON <= 1000 lignes, NULL preserves via `CheckDatabaseNull`.
- `tests/test_database.pb` : 37 tests unitaires (T2.1-T2.8 + batterie
  IsReadOnlyQuery). Tests PostgreSQL T2.9-T2.12 conditionnels
  (`MCP_DB_POSTGRES_TEST_DSN`), sinon [SKIP] explicite.
- Suite d'integration Database dans `tests/test_mcp.py` : **56 tests au total**.
- `build`/`run_all` : 5 serveurs, 3 suites de tests unitaires (7 etapes).

### Notes / ecarts au plan
- PostgreSQL via `UsePostgreSQLDatabase()` (driver integre PB) au lieu de
  prototypes libpq bruts : pas de `PQexecParams` (pas de binding de
  parametres dans l'API Database PB) — l'injection est contenue par la
  whitelist lecture seule et l'echappement des chaines internes.
- T2.12 (binding) remplace par un test de requete information_schema.

### Ajouté (Phase 1 — Memory/SQLite)
- **`memoryMCP`** : serveur MCP de mémoire persistante (`src/memoryMCP.pb` +
  `src/memory_core.pbi`) — 9 outils : `create_entities`, `create_relations`,
  `add_observations`, `delete_entities`, `delete_observations`,
  `delete_relations`, `read_graph`, `search_nodes`, `open_nodes`.
  SQLite embarque (bibliotheque PureBasic, 0 dependance), chemin via
  `MCP_MEMORY_DB` (defaut `memory.db`), schema auto-cree, cascades FK
  activees, echappement SQL (doublage des apostrophes).
- `tests/test_memory.pb` : 33 tests unitaires (T1.1-T1.18 du plan).
- Suite d'integration Memory dans `tests/test_mcp.py` (cycle complet +
  securite injection SQL) : **44 tests au total**.
- `build.bat`/`build.sh` compilent 4 serveurs ; `run_all` ajoute l'etape
  des tests unitaires Memory.

### Corrigé
- `memory_core.pbi` : boucle infinie dans `BuildGraphJSON` (un `ForEach`
  interne deplacait le curseur du `ForEach` externe) — remplace par une
  map de membership.
- `mcp_common/json_helpers.pbi` : ajout de `GetArgArray` (membres tableau).

### Ajouté (Phase 0 — infrastructure commune et harnais de test)
- **`mcp_common/`** : modules partages par tous les serveurs —
  `stdio.pbi` (E/S stdio multi-OS), `logging.pbi` (logs sur stderr),
  `json_helpers.pbi` (arguments + schémas d'outils), `protocol.pbi`
  (identité + réponse `initialize`), `jsonrpc.pbi` (noyau JSON-RPC 2.0
  générique : dispatch par hooks `*G_ToolHandler`/`*G_CatalogBuilder`,
  boucle `MCPMainLoop()`).
- **`examples/minimal_server.pb`** : serveur MCP minimal de démo
  (validation de la Phase 0, < 200 lignes).
- **`tests/mcp_client.py`** : harnais de test externe (client MCP Python
  avec validation de conformité JSON-RPC 2.0).
- **`tests/unit_test.pbi` + `tests/test_common.pb`** : micro-framework de
  tests unitaires PureBasic + 24 tests sur les modules communs.
- **`run_all.bat` / `run_all.sh`** : compilation + tests unitaires +
  tests d'intégration + rapport `tests/report.html`.

### Modifié
- Refactor des 3 serveurs (`fileMCP`, `MCP-Fetch-PB`,
  `MCP-SequentialThinking-PB`) sur `mcp_common/` : suppression de toute
  la duplication (couche stdio, JSON-RPC, helpers JSON). Comportement
  inchangé, validé par les 26 tests d'intégration.

### Ajouté (serveurs)
- **MCP-Fetch-PB** : serveur MCP de récupération web (`src/MCP-Fetch-PB.pb`) —
  outil `fetch` (URL → Markdown, HTML brut en option), protection SSRF
  (HTTP/HTTPS uniquement, IPs littérales refusées), timeout.
- **MCP-SequentialThinking-PB** : serveur MCP de raisonnement séquentiel
  (`src/MCP-SequentialThinking-PB.pb`) — outil `sequential_thinking`
  (étapes, révisions, branches, état courant en JSON).
- `build.bat` / `build.sh` compilent désormais les 3 serveurs.
- Tests étendus à 26 (catalogues et outils des 3 serveurs, cas d'erreur
  fetch hors ligne).

### Corrigé
- Compilation PureBasic 6.41 des nouveaux serveurs : retrait d'`InitNetwork()`
  (réseau auto-initialisé), remplacement de `RepeatString()` inexistant,
  déclarations anticipées (`Declare`) pour `GetArgString`/`GetArgInt`/`GetArgBool`.

### Version initiale (fileMCP, 2026-10-23)

### Ajouté (version initiale)
- Serveur MCP (Model Context Protocol) de gestion de fichiers en PureBasic :
  transport JSON-RPC 2.0 sur stdin/stdout, 100 % natif, multi-plateforme
  (Windows, Linux, macOS).
- 10 outils MCP : `list_files`, `read_file`, `read_file_lines`, `write_file`,
  `create_directory`, `delete_file`, `move_file`, `get_file_info`,
  `search_files`, `change_root`.
- Sécurité par confinement : toutes les opérations limitées à la racine
  `MCP_ROOT`, avec normalisation des chemins (protection contre les
  traversées `..`) ; `change_root` protégé par `MCP_ROOT_SECRET`.
- Réponse `initialize` conforme au protocole (protocolVersion 2024-11-05).
- Scripts de build : `build.bat` / `build.sh` (sortie dans `build/`),
  `clean.bat` / `clean.sh`.
- Harnais de tests fonctionnels `tests/test_mcp.py` (17 tests : outils +
  cas de sécurité).

### Corrigé (version initiale)
- Compilation Windows : couche E/S stdio via kernel32
  (`ReadFile` / `WriteFile` / `FlushFileBuffers` chargés dynamiquement).
- `isError` MCP fiable : détection étendue (`introuvable`, `refusee`,
  `depasse`).

[2.0.0]: https://github.com/mickael-cala/MCPserver-HTTPSuite/releases/tag/v2.0.0
[1.0.0]: https://github.com/mickael-cala/MCPserver-HTTPSuite/releases/tag/v1.0.0
