# MCPserver-HTTPSuite — 8 serveurs MCP en PureBasic (HTTP + SSE optionnel)

[![Release](https://img.shields.io/github/v/release/mickael-cala/MCPserver-HTTPSuite)](https://github.com/mickael-cala/MCPserver-HTTPSuite/releases) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Huit serveurs [MCP](https://modelcontextprotocol.io) (Model Context Protocol)
écrits en **PureBasic**, 100 % natifs, qui exposent **45 outils** à un client IA
via **JSON-RPC 2.0 sur HTTP**. Le serveur répond en **JSON direct par défaut**
et propose **SSE (`text/event-stream`) en option** lorsque le client l'accepte.
Aucun flux n'est imposé : le client choisit via l'en-tête `Accept`.

Cette version **2.0.0** est une réécriture du transport : les serveurs qui
parlaient JSON-RPC sur stdin/stdout exposent désormais un endpoint HTTP
`POST /mcp` (et un flux SSE optionnel). Le mode stdio n'est plus fourni.

## Démarrage rapide

```bash
build.bat                  # Windows : compile les 8 serveurs -> build\*.exe
./build.sh                 # Linux/macOS : compile les 8 serveurs -> build/

start_all.bat              # Windows : lance les 8 serveurs en arrière-plan
./start_all.sh             # Linux/macOS : idem

curl http://127.0.0.1:8101/health
curl -s -X POST http://127.0.0.1:8101/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

stop_all.bat               # Windows
./stop_all.sh              # Linux/macOS
```

Chaque serveur écoute par défaut sur `127.0.0.1` et un port distinct :

| Serveur | Source | Port | Outils | Description |
|---|---|---:|---:|---|
| **fileMCP** | `src/fileMCP.pb` | 8101 | 10 | Gestion de fichiers confinée à une racine (`MCP_ROOT`) |
| **MCP-Fetch-PB** | `src/MCP-Fetch-PB.pb` | 8102 | 1 | Récupération de pages web, conversion HTML → Markdown |
| **MCP-SequentialThinking-PB** | `src/MCP-SequentialThinking-PB.pb` | 8103 | 1 | Raisonnement séquentiel structuré |
| **memoryMCP** | `src/memoryMCP.pb` + `src/memory_core.pbi` | 8104 | 9 | Graphe d'entités persistant en SQLite (`MCP_MEMORY_DB`) |
| **dbMCP** | `src/dbMCP.pb` + `src/db_core.pbi` | 8105 | 5 | Exploration SQL lecture seule : SQLite + PostgreSQL optionnel |
| **context7MCP** | `src/context7MCP.pb` + `src/context7_core.pbi` | 8106 | 2 | Documentation de bibliothèques via l'API Context7 |
| **gitMCP** | `src/gitMCP.pb` + `src/git_core.pbi` | 8107 | 7 | Exploration de dépôts git locaux |
| **githubMCP** | `src/githubMCP.pb` + `src/github_core.pbi` | 8108 | 10 | API REST GitHub : repos, issues, PR, commits, recherches |

Le port de chaque serveur est surchargeable individuellement avec
`MCP_HTTP_PORT`. Ne définissez pas cette variable globalement lorsque vous
lancez les 8 serveurs avec `start_all` : ils entreraient en conflit sur le même
port.

## Transport HTTP

| Élément | Valeur |
|---|---|
| Endpoint MCP | `POST /mcp` ; `GET /mcp` pour un flux SSE optionnel |
| Santé | `GET /health` |
| Version HTTP | HTTP/1.1 |
| TLS | Non fourni nativement : reverse proxy HTTPS devant le serveur |
| Content-Type requis | `application/json` (un `charset` est accepté) |
| Réponse JSON-RPC | `200 application/json` ou `200 text/event-stream` selon `Accept` |
| Notification JSON-RPC | `202 Accepted`, corps vide |
| SSE | **Optionnel** : `GET /mcp` + `Accept: text/event-stream` ouvre un flux ; sans cet en-tête, `405`. `POST /mcp` répond en SSE si `Accept` le demande |
| Sessions | Aucune : pas de `Mcp-Session-Id`, serveur sans état |
| Version MCP | `2025-06-18` par défaut ; `2025-03-26` acceptée en négociation |
| Connexions | POST : une requête par connexion ; GET SSE : flux persistant |
| Corps maximal | 1 Mio par défaut (`MCP_HTTP_MAX_BODY`) |
| Traitement | Séquentiel : un appel d'outil à la fois par processus |

Exemple d'appel d'outil :

```bash
curl -s -X POST http://127.0.0.1:8101/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_files","arguments":{"path":"."}}}'
```

Codes HTTP :

- `200` : réponse JSON-RPC (y compris les erreurs JSON-RPC `-32700`,
  `-32600`, `-32601`, `-32603`) ou flux `text/event-stream` ;
- `202` : notification acceptée, sans corps ;
- `204` : `DELETE /mcp` accepté sans effet (serveur sans état) ;
- `400` / `401` / `403` / `405` / `408` / `411` / `413` / `415` / `431` / `500`
  / `501` / `503` : erreurs de transport ou de sécurité, corps JSON
  `{"error": "..."}` ;
- `404` : chemin inconnu.

Le serveur refuse `Transfer-Encoding: chunked` (utilisez `Content-Length`).
Le SSE n'est **jamais imposé** : `GET /mcp` sans `Accept: text/event-stream`
renvoie `405`, et `POST /mcp` répond en JSON si le client n'accepte pas SSE.
Les flux SSE ouverts reçoivent un commentaire `: connected` puis des
`: keep-alive` toutes les 15 secondes.

## Outils MCP exposés

### fileMCP — gestion de fichiers

| Outil | Description | Paramètres |
|---|---|---|
| `list_files` | Lister le contenu d'un répertoire (confiné à la racine autorisée) | `path` |
| `read_file` | Lire un fichier texte (tronqué au-delà de 20 000 octets) | `path` |
| `read_file_lines` | Lire une plage de lignes (fichier limité à 5 Mo) | `path`, `startLine` (défaut 1), `maxLines` (défaut 50) |
| `write_file` | Écrire/créer un fichier texte | `path`, `content` |
| `create_directory` | Créer un répertoire | `path` |
| `delete_file` | Supprimer un fichier ou dossier vide | `path` |
| `move_file` | Déplacer ou renommer un fichier | `oldPath`, `newPath` |
| `get_file_info` | Infos détaillées fichier/dossier | `path` |
| `search_files` | Rechercher du texte (récursif) | `path`, `pattern` |
| `change_root` | Changer la zone autorisée | `newRoot`, `secret` |

### MCP-Fetch-PB — récupération web

| Outil | Description | Paramètres |
|---|---|---|
| `fetch` | Récupère une URL et retourne son contenu en Markdown (ou HTML brut si `raw=true`) | `url`, `max_length` (défaut 5000), `start_index` (défaut 0), `raw` (défaut false) |

Les URLs non HTTP/HTTPS et les IPs littérales sont refusées (SSRF) ; un timeout
plafonne la durée de chaque requête.

### MCP-SequentialThinking-PB — raisonnement séquentiel

| Outil | Description | Paramètres |
|---|---|---|
| `sequential_thinking` | Enregistre une étape de raisonnement et retourne l'état courant | `thought`, `thoughtNumber`, `totalThoughts`, `nextThoughtNeeded`, `isRevision` (défaut false), `revisesThought` (défaut 0), `branchFromThought` (défaut 0), `branchId` |

### memoryMCP — mémoire persistante (SQLite)

| Outil | Description | Paramètres |
|---|---|---|
| `create_entities` | Crée des entités avec leurs observations (doublons ignorés) | `entities[]` : `{name, entityType, observations[]}` |
| `create_relations` | Crée des relations entre entités existantes | `relations[]` : `{from, to, relationType}` |
| `add_observations` | Ajoute des observations à des entités existantes | `observations[]` : `{entityName, contents[]}` |
| `delete_entities` | Supprime des entités (cascade observations + relations) | `entityNames[]` |
| `delete_observations` | Supprime des observations précises | `observations[]` : `{entityName, contents[]}` |
| `delete_relations` | Supprime des relations précises | `relations[]` : `{from, to, relationType}` |
| `read_graph` | Retourne tout le graphe en JSON | — |
| `search_nodes` | Recherche insensible à la casse (nom, type, observations) | `query` |
| `open_nodes` | Retourne des entités par nom avec relations internes | `names[]` |

La base est un fichier SQLite créé automatiquement (chemin : `MCP_MEMORY_DB`,
défaut `memory.db`). Les noms sont échappés (pas d'injection SQL) et les
suppressions d'entités cascadent via les clés étrangères.

### dbMCP — exploration SQL (SQLite + PostgreSQL)

| Outil | Description | Paramètres |
|---|---|---|
| `db_list_schemas` | Liste les schémas (`["main"]` pour SQLite, `information_schema.schemata` pour PostgreSQL) | `engine` (défaut `sqlite`) |
| `db_list_tables` | Liste les tables de la base / du schéma | `engine`, `schema` (PostgreSQL, défaut `public`) |
| `db_describe_table` | Décrit les colonnes (`PRAGMA table_info` / `information_schema.columns`) | `table`, `engine`, `schema` |
| `db_execute_query` | Exécute une requête — lecture seule par défaut, résultat limité à 1000 lignes | `query`, `engine` |
| `db_explain` | Plan d'exécution (`EXPLAIN QUERY PLAN` / `EXPLAIN`) | `query`, `engine` |

Garde-fou lecture seule : seuls `SELECT`/`WITH` (sans verbe d'écriture)/`SHOW`/
`EXPLAIN`/`DESCRIBE` passent ; toute écriture exige `MCP_DB_ALLOW_WRITE=1` et
est journalisée sur stderr en cas de refus. La connexion PostgreSQL impose
`statement_timeout=30s`. Les résultats JSON préservent les NULL
(`CheckDatabaseNull`) et typent entiers/flottants.

### context7MCP — documentation de bibliothèques

| Outil | Description | Paramètres |
|---|---|---|
| `resolve_library_id` | Recherche une bibliothèque, retourne les identifiants `/owner/repo` (fonctionne sans clé) | `query`, `libraryType` (défaut `oss`) |
| `query_docs` | Retourne la documentation d'une bibliothèque (clé API requise) | `libraryId`, `query`, `tokens` (défaut 5000), `topic` (optionnel), `max_length` (troncature locale, défaut 10000) |

HTTP : couche **WinHTTP** native sous Windows ; **curl** sous Linux/macOS
(en-têtes `Authorization` supportés, `curl` requis). Erreurs mappées proprement :
401 clé, 429 quota, 5xx indisponible, échec réseau. Les tests live sont ignorés
hors ligne.

### gitMCP — dépôts git locaux

| Outil | Description | Paramètres |
|---|---|---|
| `git_is_repo` | Vérifie qu'un répertoire est un dépôt git | `repoPath` |
| `git_status` | État du working tree (format porcelain) | `repoPath` |
| `git_log` | Historique oneline (N derniers commits) | `repoPath`, `count` (défaut 10, max 1000) |
| `git_diff` | Différences entre deux refs, filtre de chemin optionnel | `repoPath`, `refA`, `refB`, `path` |
| `git_show` | Contenu d'un fichier à une ref | `repoPath`, `ref`, `path` |
| `git_branches` | Branches locales ou distantes | `repoPath`, `remote` |
| `git_blame` | Annotations de lignes | `repoPath`, `path`, `startLine`, `endLine` |

Sécurité : tous les paramètres (chemins, refs) sont validés avant exécution —
les métacaractères shell (`;` `&` `|` `<` `>` `` ` `` `$` `(` `)` guillemets,
retours ligne) sont rejetés. `MCP_GIT_EXE` permet de pointer un `git` hors PATH ;
le serveur refuse de démarrer si git est introuvable.

### githubMCP — API REST GitHub

| Outil | Description | Paramètres |
|---|---|---|
| `gh_get_repo` | Métadonnées d'un dépôt | `owner`, `repo` |
| `gh_list_issues` | Liste paginée des issues | `owner`, `repo`, `state`, `page`, `per_page` |
| `gh_get_issue` | Détail d'une issue | `owner`, `repo`, `number` |
| `gh_create_issue` | Crée une issue — `confirm=true` requis | `owner`, `repo`, `title`, `body`, `confirm` |
| `gh_list_pull_requests` | Liste paginée des PR | `owner`, `repo`, `state`, `page`, `per_page` |
| `gh_get_pull_request` | Détail d'une PR | `owner`, `repo`, `number` |
| `gh_create_pull_request` | Crée une PR — `confirm=true` requis | `owner`, `repo`, `title`, `head`, `base`, `body`, `confirm` |
| `gh_list_commits` | Commits paginés (filtre `sha`) | `owner`, `repo`, `sha`, `page`, `per_page` |
| `gh_search_code` | Recherche de code | `query`, `page`, `per_page` |
| `gh_search_repositories` | Recherche de dépôts | `query`, `page`, `per_page` |

Sécurité : token jamais renvoyé dans les messages ; écritures refusées sans
`confirm=true` ; pagination bornée (`per_page` max 100) ; erreurs mappées
(401 token, 403 quota, 404 introuvable, 422 validation, 5xx). Les tests
d'intégration utilisent un **serveur GitHub mock local** (`tests/mock_github.py`),
sans réseau.

Attention : `write_file`, `delete_file`, `move_file` et `change_root` sont des
opérations destructrices ou sensibles. Ne connectez `fileMCP` qu'à un répertoire
dont la perte de contenu serait acceptable.

## Configuration

### Transport et sécurité HTTP

| Variable | Rôle | Défaut |
|---|---|---|
| `MCP_HTTP_HOST` | Adresse d'écoute (`127.0.0.1`, `::1`, `0.0.0.0`…) | `127.0.0.1` |
| `MCP_HTTP_PORT` | Port d'écoute du serveur courant | 8101 à 8108 selon le serveur |
| `MCP_HTTP_TOKEN` | Jeton Bearer exigé sur `POST /mcp` (`Authorization: Bearer …`) | vide = pas d'auth |
| `MCP_HTTP_MAX_BODY` | Taille maximale du corps JSON (octets, borné 1 Kio–16 Mio) | `1048576` |
| `MCP_HTTP_ALLOWED_ORIGINS` | Origines supplémentaires autorisées (liste séparée par virgules) | vide |
| `MCP_HTTP_LOG_REQUESTS` | `1` = journaliser chaque requête HTTP sur stderr | désactivé |

Les origines loopback du port courant (`http://127.0.0.1:<port>`,
`http://localhost:<port>`, `http://[::1]:<port>`) sont toujours autorisées.
Une origine étrangère est refusée (`403`), ce qui protège contre le DNS
rebinding et les requêtes navigateur non désirées.

`/health` reste public. Si `MCP_HTTP_HOST` n'est pas une adresse loopback et que
`MCP_HTTP_TOKEN` est vide, le serveur journalise un avertissement au démarrage.

### Variables métier

| Variable | Rôle | Serveur |
|---|---|---|
| `MCP_ROOT` | Répertoire racine autorisé. Si absent, le répertoire courant du serveur est utilisé. | fileMCP |
| `MCP_ROOT_SECRET` | Mot de passe requis par `change_root`. | fileMCP |
| `MCP_MEMORY_DB` | Chemin du fichier SQLite de la mémoire (créé automatiquement). Défaut : `memory.db`. | memoryMCP |
| `MCP_DB_PATH` | Fichier SQLite exploré par dbMCP (créé si absent). Défaut : `database.db`. | dbMCP |
| `MCP_DB_POSTGRES_DSN` | Chaîne de connexion PostgreSQL. Si absente, l'engine `postgres` retourne une erreur claire. | dbMCP |
| `MCP_DB_ALLOW_WRITE` | `1` = autorise les requêtes d'écriture. Défaut : lecture seule. | dbMCP |
| `MCP_CONTEXT7_API_KEY` | Clé API Context7 (préfixe `ctx7sk`). Requise par `query_docs`. | context7MCP |
| `MCP_CONTEXT7_API_BASE` | Base de l'API Context7 (défaut `https://context7.com/api/v1`). | context7MCP |
| `MCP_GIT_EXE` | Chemin de l'exécutable git si absent du PATH. | gitMCP |
| `MCP_GITHUB_TOKEN` | Token GitHub (PAT). Requis par tous les outils githubMCP. | githubMCP |
| `MCP_GITHUB_API_BASE` | Base de l'API (défaut `https://api.github.com`). | githubMCP |

Tous les chemins passés aux outils fileMCP sont normalisés et bloqués s'ils
tentent de sortir de la racine autorisée. Voir [SECURITY.md](SECURITY.md).

## Compilation

Requiert [PureBasic](https://www.purebasic.com) (testé en 6.41) et un format
d'exécutable **Console**.

Prérequis système :

- **Windows** : rien de plus (WinHTTP est natif).
- **Linux** : `libssl-dev`, `libsqlite3-dev`, `curl`
  (`sudo apt install libssl-dev libsqlite3-dev curl`).
- **macOS** : `curl` (fourni par le système).

### Avec les scripts de build (recommandé)

```bash
build.bat      # Windows   -> build\fileMCP.exe, ...
./build.sh     # Linux/macOS -> build/fileMCP, ...
```

Les scripts compilent les 8 serveurs. Le compilateur est cherché dans la
variable d'environnement `PBCOMPILER`, puis dans les chemins par défaut
(`C:\Program Files\PureBasic\Compilers`, `C:\PureBasic\Compilers`), puis dans
le `PATH`. Les exécutables sont générés dans `build/` (non versionné).

`build.bat` utilise les options Windows (`/EXE`, `/CONSOLE`) ; `build.sh`
utilise les options Linux/macOS (`-o`, `-cl`, `-t`).

Pour lancer les 8 serveurs : `start_all.bat` / `./start_all.sh`. Pour les
arrêter : `stop_all.bat` / `./stop_all.sh`. Les logs sont écrits dans
`build/logs/`.

### Via l'IDE PureBasic

Ouvrez le `.pb` du serveur voulu (ex. `src/fileMCP.pb`), puis :

1. **Options du compilateur** → Format d'exécutable : **Console**
2. Nom de l'exécutable : `build/<nom>.exe`
3. **Compilation → Compiler** (`F5`)

Aucun fichier `.pbp` n'est fourni : les scripts `build.bat`/`build.sh` couvrent
la compilation reproductible (mêmes options), et l'IDE fait foi pour les
options. Les fichiers `.pbi` du dépôt sont uniquement les **modules d'inclusion**
(`mcp_common/`, `tests/unit_test.pbi`), pas des projets.

## Tests

Trois niveaux de tests, lancés d'un coup par `run_all.bat` / `./run_all.sh`
(compilation + tests unitaires + robustesse/performance + intégration +
`tests/report.html` avec le détail par serveur) :

```bash
run_all.bat        # ou ./run_all.sh : tout vérifier
```

- **Unitaires (PureBasic)** : `tests/unit_test.pbi` (micro-framework) +
  6 suites (`tests/test_common.pb` 41, `test_memory.pb` 33, `test_database.pb`
  37, `test_context7.pb` 19, `test_git.pb` 24, `test_github.pb` 40 — soit
  **194 tests** hors réseau). Chaque futur module ajoute un
  `tests/test_<module>.pb`.
- **Intégration (Python)** : `tests/mcp_client.py` (harnais client MCP HTTP
  avec validation de conformité JSON-RPC 2.0) + `tests/test_mcp.py`
  (**120 tests** qui exercent les outils, le transport HTTP et les cas de
  sécurité) :

```bash
python tests/test_mcp.py                 # les 8 serveurs + transport
python tests/test_mcp.py memoryMCP       # un seul serveur
```

- **Robustesse et performances (Phase 6)** : `tests/test_robustness.py` —
  **21 vérifications** (charge `tools/list`, corps de 1 Mio → 413, JSON
  malformé, port déjà utilisé, kill pendant une requête, deux instances
  Memory, chemin DB invalide, coupure réseau Context7, SSE non imposé,
  performances T6.9–T6.14) :

```bash
python tests/test_robustness.py
MCP_STRESS_REQUESTS=10000 python tests/test_robustness.py   # charge complète
```

Le binaire de chaque serveur est cherché dans `build/`, puis `src/` ; la
variable `<NOM>_BIN` (ex. `FILEMCP_BIN`, `MEMORYMCP_BIN`) force un chemin.

Résultat de référence : `run_all` **10/10 étapes**, **194 tests unitaires**,
**21 vérifications de robustesse/performance** (T6.14 conditionnel à une clé
Context7), **120 tests d'intégration**. Validé sous **Windows** et
**Linux (WSL2 Ubuntu 26.04)** ; macOS reste à valider.

## Configuration d'un client MCP

Avec le transport HTTP, c'est le client qui se connecte à une URL ; il ne lance
pas les serveurs. Démarrez-les d'abord avec `start_all` (ou un par un), puis
déclarez les URLs. Exemple (configuration complète : `examples/mcp.json`) :

```json
{
  "mcpServers": {
    "file-pb": {
      "type": "http",
      "url": "http://127.0.0.1:8101/mcp",
      "headers": {
        "Authorization": "Bearer votre-token-mcp"
      }
    },
    "fetch-pb": {
      "type": "http",
      "url": "http://127.0.0.1:8102/mcp"
    },
    "sequential-thinking-pb": {
      "type": "http",
      "url": "http://127.0.0.1:8103/mcp"
    },
    "memory-pb": {
      "type": "http",
      "url": "http://127.0.0.1:8104/mcp"
    },
    "db-pb": {
      "type": "http",
      "url": "http://127.0.0.1:8105/mcp"
    },
    "context7-pb": {
      "type": "http",
      "url": "http://127.0.0.1:8106/mcp"
    },
    "git-pb": {
      "type": "http",
      "url": "http://127.0.0.1:8107/mcp"
    },
    "github-pb": {
      "type": "http",
      "url": "http://127.0.0.1:8108/mcp"
    }
  }
}
```

Le champ `headers` n'est utile que si `MCP_HTTP_TOKEN` est défini sur le
serveur ; dans ce cas, répétez le bloc `headers` sur **chacun** des huit
serveurs (`examples/mcp.json` le fait). Si aucun jeton n'est configuré, les
en-têtes sont ignorés. Selon le client, la syntaxe exacte peut être
`"type": "http"` + `"url"`, ou `"transport": "http"` ; reportez-vous à sa
documentation. Un client qui ne supporte que stdio ne peut pas se connecter
directement à cette version : utilisez un client compatible HTTP (Claude
Desktop récent, Kimi Code, etc.) ou un pont stdio→HTTP externe.

## Structure du dépôt

```
mcp_common/               Modules partagés par tous les serveurs MCP
├── runtime.pbi           Console : écriture stderr, CheckRuntime()
├── logging.pbi           LogDebug/LogError sur stderr
├── json_helpers.pbi      Lecture d'arguments + construction de schémas
├── http.pbi              Client HTTP GET/POST (WinHTTP / curl)
├── protocol.pbi          Identité serveur + réponse initialize
├── jsonrpc.pbi           Noyau JSON-RPC 2.0 transport-agnostique
├── http_server.pbi       Serveur HTTP/1.1 (POST/GET /mcp, /health)
└── http_sse.pbi          SSE optionnel (inclus par http_server.pbi)

src/
├── fileMCP.pb                    # Serveur gestion de fichiers
├── MCP-Fetch-PB.pb               # Serveur fetch web (HTML -> Markdown)
├── MCP-SequentialThinking-PB.pb  # Serveur raisonnement séquentiel
├── memoryMCP.pb                  # Serveur mémoire (main)
├── memory_core.pbi               # Cœur métier Memory (SQLite, testable)
├── dbMCP.pb                      # Serveur Database (main)
├── db_core.pbi                   # Cœur métier Database (SQLite/PostgreSQL)
├── context7MCP.pb                # Serveur Context7 (main)
├── context7_core.pbi             # Cœur métier Context7 (WinHTTP / curl)
├── gitMCP.pb                     # Serveur Git (main)
├── git_core.pbi                  # Cœur métier Git (sous-processus git)
├── githubMCP.pb                  # Serveur GitHub (main)
└── github_core.pbi               # Cœur métier GitHub (API REST)

examples/minimal_server.pb  # Serveur MCP HTTP minimal de démonstration (port 8090)
examples/mcp.json           # Configuration client HTTP complète (8 serveurs)
build.bat / build.sh        # Compilation des 8 serveurs (sortie dans build/)
start_all.bat / start_all.sh # Lancement des 8 serveurs en arrière-plan
stop_all.bat / stop_all.sh  # Arrêt des serveurs
clean.bat / clean.sh        # Suppression des artefacts de compilation
run_all.bat / run_all.sh    # Compilation + tests + rapport
.gitattributes              # Fins de ligne (LF scripts/sources, CRLF .bat)
tests/
├── mcp_client.py           # Harnais de test externe (client MCP HTTP)
├── mock_github.py          # Mock local de l'API GitHub (intégration)
├── test_mcp.py             # Tests fonctionnels + transport (120 tests)
├── unit_test.pbi           # Micro-framework de tests unitaires PureBasic
├── test_common.pb          # Tests unitaires des modules mcp_common (41 tests)
├── test_memory.pb          # Tests unitaires du serveur Memory (33 tests)
├── test_database.pb        # Tests unitaires du serveur Database (37 tests)
├── test_context7.pb        # Tests unitaires du serveur Context7 (19 tests)
├── test_git.pb             # Tests unitaires du serveur Git (24 tests)
├── test_github.pb          # Tests unitaires du serveur GitHub (40 tests)
├── test_robustness.py      # Robustesse T6.1-T6.15 + performances T6.9-T6.14
├── make_report.py          # Génère report.html depuis report.json
└── report.json             # Stats par serveur (généré, ignoré par git)
```

Nouveau serveur ? Incluez `mcp_common/` (voir `examples/minimal_server.pb`),
renseignez les hooks `*G_ToolHandler` / `*G_CatalogBuilder`, vérifiez
`CheckRuntime()` et appelez `MCPHttpMainLoop(<port>)`.

## Documentation

- [PLAN.md](PLAN.md) — suivi des phases du plan (état, livrables)
- [CHANGELOG.md](CHANGELOG.md) — journal des versions
- [ROADMAP.md](ROADMAP.md) — feuille de route
- [ERRATA.md](ERRATA.md) — limitations et problèmes connus
- [CONTRIBUTING.md](CONTRIBUTING.md) — contribuer (conventions, tests)
- [SECURITY.md](SECURITY.md) — signalement de vulnérabilités, modèle de sécurité
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — code de conduite
- [AGENTS.md](AGENTS.md) — reprise du développement, checklist de mise à jour des `.md` avant commit, pièges PureBasic

## Licence

[MIT](LICENSE)
