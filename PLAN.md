# Suivi du plan de développement

État des phases du plan (mise à jour : 2026-10-24).

| Phase | Sujet | Statut | Livrables |
|---|---|---|---|
| **0** | Infrastructure commune et harnais de test | ✅ Terminée | `mcp_common/` (runtime, logging, json_helpers, protocol, jsonrpc, http, http_server), `tests/mcp_client.py`, `tests/unit_test.pbi`, `run_all.bat/.sh`, serveur de démo `examples/minimal_server.pb` |
| **1** | Memory (SQLite) | ✅ Terminée | `memoryMCP` (9 outils), 33 tests unitaires, 18 tests d'intégration |
| **2** | Database (SQLite + PostgreSQL) | ✅ Terminée | `dbMCP` (5 outils, garde-fou lecture seule, PostgreSQL optionnel), 37 tests unitaires, 12 tests d'intégration |
| **3** | Context7 | ✅ Terminée | `context7MCP` (2 outils), WinHTTP + en-têtes, 19 tests unitaires, 7 tests d'intégration (live conditionnel) |
| **4** | Git | ✅ Terminée | `gitMCP` (7 outils, validation anti-injection), 24 tests unitaires, 12 tests d'intégration |
| **5** | GitHub | ✅ Terminée | `githubMCP` (10 outils, `confirm=true`, mock local), 40 tests unitaires, 25 tests d'intégration |
| **6** | Consolidation et tests transverses | ✅ Terminée | `tests/test_robustness.py` (T6.1–T6.15), rapport HTML par serveur, `examples/mcp.json` |
| **7** | Transport HTTP (sans SSE) | ✅ Terminée | `mcp_common/http_server.pbi`, `runtime.pbi`, `start_all`/`stop_all`, 8 serveurs HTTP, tests transport, v2.0.0 |

## Définition de « terminé » (état actuel)

| Critère | État |
|---|---|
| Tests unitaires des modules et serveurs | ✅ 41 + 33 + 37 + 19 + 24 + 40 = **194** (Windows ; 2.0.0 à revalider sous Linux) |
| Tests d'intégration (8 serveurs + transport) | ✅ **118/118** |
| `run_all.bat` / `run_all.sh` vert | ✅ **10/10 étapes** |
| Robustesse / performances | ✅ **21/21** (T6.14 conditionnel à une clé Context7) |
| Transport | ✅ HTTP JSON (`POST /mcp`), **aucun SSE** |
| Erreurs MCP en `isError: true` avec message clair | ✅ heuristique `DetectIsError` + refus explicites |
| Aucun secret loggé ni renvoyé | ✅ tokens/clés jamais inclus dans les réponses ; logs stderr |
| Documentation README complète | ✅ (outils, transport, env, build, tests, config client) |
| Release publiée | ⏳ v2.0.0 à publier |
| Validation Windows | ✅ 2.0.0 (10/10, 194 unitaires, 21 robustesse/perf, 118 intégration) |
| Validation Linux | ✅ version 1.0.0 (WSL2 Ubuntu 26.04) ; ⏳ version 2.0.0 à revalider |
| Validation macOS | ⏳ à faire (prérequis : `curl`) |
| Sécurité réseau | ✅ bind loopback, Origin, jeton optionnel, corps borné |

## Serveurs livrés (8)

| Serveur | Port | Outils | Tests unitaires | Tests d'intégration | Documentation |
|---|---:|---:|---|---|---|
| `fileMCP` | 8101 | 10 | — (intégration) | 17 | README, SECURITY |
| `MCP-Fetch-PB` | 8102 | 1 | — (intégration) | 3 | README |
| `MCP-SequentialThinking-PB` | 8103 | 1 | — (intégration) | 6 | README |
| `memoryMCP` | 8104 | 9 | 33 | 18 | README, SECURITY, ERRATA |
| `dbMCP` | 8105 | 5 | 37 | 12 | README, SECURITY, ERRATA |
| `context7MCP` | 8106 | 2 | 19 | 7 | README, SECURITY, ERRATA |
| `gitMCP` | 8107 | 7 | 24 | 12 | README, SECURITY, ERRATA |
| `githubMCP` | 8108 | 10 | 40 | 25 | README, SECURITY, ERRATA |

Total : **45 outils**, **194 tests unitaires**, **118 tests d'intégration**
(dont 18 tests de transport HTTP), **21 vérifications de robustesse/perf**.

## Détail des phases

### Phase 0 — Infrastructure (terminée)
- Modules partagés : `mcp_common/{runtime,logging,json_helpers,protocol,jsonrpc,http,http_server}.pbi`.
- Harnais Python `tests/mcp_client.py` (HTTP, `GET /health`, validation JSON-RPC 2.0, timeout).
- Framework de tests PureBasic `tests/unit_test.pbi` (asserts, rapport, code de sortie).
- `run_all` : compilation → tests unitaires → intégration → `tests/report.html`.
- Preuve : `examples/minimal_server.pb` (initialize + tools/list via HTTP, port 8090).

### Phase 1 — Memory (terminée)
- Schéma : `entities` / `observations` / `relations`, FK `ON DELETE CASCADE`.
- Outils : `create_entities`, `create_relations`, `add_observations`,
  `delete_entities`, `delete_observations`, `delete_relations`, `read_graph`,
  `search_nodes`, `open_nodes`.
- Tests : T1.1–T1.18 (création, doublons, cascade, recherche insensible à la
  casse, injection SQL, contenu 100 Ko). Bug corrigé : boucle infinie dans
  `BuildGraphJSON` (curseur `ForEach` partagé).

### Phase 2 — Database (terminée)
- Outils : `db_list_schemas`, `db_list_tables`, `db_describe_table`,
  `db_execute_query`, `db_explain` ; moteurs `sqlite` (défaut) et `postgres`.
- Garde-fou lecture seule `IsReadOnlyQuery` + `MCP_DB_ALLOW_WRITE`.
- Tests : T2.1–T2.8 (+ batterie de 19 cas sur le garde-fou) ; T2.9–T2.12
  PostgreSQL conditionnels (`MCP_DB_POSTGRES_TEST_DSN`).
- Écart documenté : driver PostgreSQL intégré à PureBasic (pas de
  `PQexecParams`), whitelist lecture seule en compensation.

### Phase 3 — Context7 (terminée)
- Outils : `resolve_library_id` (sans clé), `query_docs` (`MCP_CONTEXT7_API_KEY`).
- API réelle : GET (le POST renvoie 405) ; 400 trompeur sans clé intercepté.
- HTTP : WinHTTP sous Windows, curl ailleurs (clé supportée).
- Tests : T3.1–T3.2 live (skip hors ligne), T3.4/T3.5 (clé absente/invalide),
  T3.8 (`max_length`), plus 19 tests unitaires hors ligne.

### Phase 4 — Git (terminée)
- Outils : `git_is_repo`, `git_status`, `git_log`, `git_diff`, `git_show`,
  `git_branches`, `git_blame`.
- `GitRun()` : shell + `2>&1`, lecture jusqu'à fin de processus, sortie 40 Ko.
- Sécurité : `GitSafeParam` sur tous les paramètres (injection testée).
- Tests : T4.1–T4.18 (fixture réelle : 4 commits, 2 branches, espaces,
  injections, git absent).

### Phase 5 — GitHub (terminée)
- Outils : 10 outils repos/issues/PR/commits/recherches.
- `confirm=true` obligatoire pour les écritures ; mock local `tests/mock_github.py`.
- Tests : T5.1–T5.15 via mock + `T5.4` sans token ; 40 tests unitaires.

### Phase 6 — Consolidation (terminée)
- `tests/test_robustness.py` : T6.1 charge HTTP (500 par défaut, 10 000 via
  `MCP_STRESS_REQUESTS`), T6.2 corps 1 Mio → 413, T6.3 JSON malformé,
  T6.4 port déjà utilisé, T6.5 `kill` pendant une requête (base rouverte),
  T6.6 deux instances sur la même base, T6.7 chemin DB invalide,
  T6.8 coupure réseau Context7, T6.15 absence de SSE.
- Performances : T6.9 100 entités (< 500 ms, transaction SQLite),
  T6.10 recherche 10 000 entités (< 200 ms), T6.11 SELECT (< 50 ms),
  T6.12 `git log` 1 000 commits (< 200 ms), T6.13 GitHub mock (< 2 s),
  T6.14 Context7 (< 3 s, conditionnel).
- `tests/report.json` + `tests/make_report.py` → `tests/report.html` par
  serveur ; `examples/mcp.json` (8 serveurs) ; `MCP_CONTEXT7_API_BASE`
  ajouté pour les tests de coupure réseau.

### Phase 7 — Transport HTTP (terminée)
- **`mcp_common/runtime.pbi`** : remplace `stdio.pbi` ; stderr uniquement,
  `CheckRuntime()`. Le mode stdin/stdout est supprimé.
- **`mcp_common/jsonrpc.pbi`** : `ProcessRequestToJSON()` indépendant du
  transport ; notifications sans réponse ; `-32700` / `-32600` / `-32601` /
  `-32603` ; `initialize` négocie `2025-06-18` / `2025-03-26`.
- **`mcp_common/http_server.pbi`** : serveur HTTP/1.1 natif
  (`CreateNetworkServer`, `NetworkServerEvent`), `POST /mcp`, `GET /health`,
  `405` sur `GET`/`DELETE /mcp`, **aucun SSE** ; accumulation multi-paquets,
  `Content-Length`, corps max 1 Mio, timeout d'inactivité, `Origin`, jeton
  Bearer optionnel, `MCP-Protocol-Version`, réponses JSON.
- **8 serveurs** : ports 8101–8108, `MCPHttpMainLoop()`, version 2.0.0.
- **Scripts** : `start_all` / `stop_all` (Windows/Linux), correction du bug de
  syntaxe de `run_all.sh`.
- **Tests** : `tests/mcp_client.py` réécrit en HTTP ; 18 tests de transport
  ajoutés (118 au total) ; robustesse adaptée (21 vérifications) ;
  `test_common.pb` couvre le noyau JSON-RPC (41 tests).
- **Documentation** : README, AGENTS, PLAN, ROADMAP, CHANGELOG, ERRATA,
  CONTRIBUTING, SECURITY et modèles GitHub alignés sur HTTP.
