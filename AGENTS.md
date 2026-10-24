# AGENTS.md — Instructions pour les agents IA

Ce fichier guide les agents de codage (Kimi Code, Claude Code, Copilot…) qui
travaillent sur ce dépôt. **À lire en premier à chaque reprise.**

## Reprise du développement (bootstrap)

1. **Lire l'état du plan** : [PLAN.md](PLAN.md) (phases 0→7, statut et
   livrables) et [ROADMAP.md](ROADMAP.md) (suite).
2. **Vérifier l'environnement** :
   - PureBasic 6.x (testé avec 6.41) — `pbcompiler` cherché via `PBCOMPILER`,
     `C:\Program Files\PureBasic\Compilers\pbcompiler.exe`,
     `C:\PureBasic\Compilers\pbcompiler.exe`, puis le `PATH` ;
   - Python 3 (tests d'intégration uniquement, aucune dépendance externe) ;
   - `git` dans le PATH (serveur `gitMCP` et workflow de commit) ;
   - Linux : `libssl-dev`, `libsqlite3-dev`, `curl` ; macOS : `curl`.
3. **Synchroniser et vérifier la base** :
   ```bash
   git pull
   build.bat                  # ou ./build.sh : compile les 8 serveurs
   run_all.bat                # ou ./run_all.sh : unitaires + intégration + rapport
   ```
   Attendu : **10/10 étapes**, **194 tests unitaires**
   (41+33+37+19+24+40), **21/21 robustesse/performance** (T6.14 conditionnel)
   et **118/118 tests d'intégration**. Si ce n'est pas le cas, corriger avant
   toute nouvelle fonctionnalité.
4. **Choisir la suite** : voir [ROADMAP.md](ROADMAP.md). Ne jamais démarrer
   une phase sans avoir vert `run_all`.

### Validation Linux (WSL2)

```bash
# dans WSL : installer les dependances
sudo apt install -y libssl-dev libsqlite3-dev curl
# pointer PBCOMPILER vers le compilateur Linux (licence ou demo)
export PBCOMPILER=$HOME/purebasic-demo/purebasic_demo/compilers/pbcompiler
export PUREBASIC_HOME=$HOME/purebasic-demo/purebasic_demo
./build.sh && ./run_all.sh
```
Attendu : 10/10 étapes (194 unitaires, 21 robustesse/perf, 118 intégration).
Attention : `build/` est partagé avec Windows si le dépôt est sur `/mnt/c` —
relancer `build.bat` après une validation Linux.

## Règle absolue : documentation synchronisée AVANT chaque commit

Aucun commit ne doit partir sans que **tous les fichiers `.md` concernés**
soient à jour. Avant `git commit`, passer cette checklist :

| Fichier | À mettre à jour quand… |
|---|---|
| `README.md` | nouvel outil, nouvelle variable d'environnement, changement de build/tests, nouveau serveur, ports HTTP, compteurs de tests |
| `PLAN.md` | début/fin de phase, changement de statut, nouvel écart au plan |
| `CHANGELOG.md` | **tout changement notable** (ajout/correction/sécurité) sous `## [Non publié]` avec le détail des fichiers |
| `ROADMAP.md` | ce qui est terminé et ce qui devient prioritaire |
| `ERRATA.md` | limitation, bug connu, résultat des tests de référence |
| `AGENTS.md` | changement d'architecture, de commandes, de conventions, de pièges |
| `CONTRIBUTING.md` | conventions, workflow de tests, périmètre des contributions |
| `SECURITY.md` | nouvelle surface d'attaque, nouveau secret, nouvelle protection |
| `docs`/`.github/*.md` | modèles d'issues/PR, compteurs cités |

Règle de cohérence : **tous les compteurs cités** (nombre de serveurs, de
tests, d'étapes, ports) doivent correspondre à la réalité du moment. Vérifier
avec :

```bash
grep -rnE "[0-9]+ tests|[0-9]+ serveurs|/9 étapes|/10 étapes" README.md PLAN.md ERRATA.md AGENTS.md CONTRIBUTING.md
```

Les chiffres historiques du `CHANGELOG.md` sont la seule exception : ils
décrivent chaque version à sa date et ne se réécrivent pas.

## Workflow de commit

```bash
run_all.bat                    # obligatoire, doit être vert
git add -A
git commit -m "Phase N: resume court

- points cles du changement
- tests: X/Y, run_all N/N"
git push                       # uniquement si l'utilisateur le demande
```

- Un commit = un sujet cohérent (une phase ou une correction).
- **Ne jamais pousser sans demande explicite** de l'utilisateur.
- Ne jamais committer `build/`, `tests/report.html`, `tmp-test/` (gitignorés).

## Vue d'ensemble

**8 serveurs MCP** écrits en **PureBasic** (sources dans `src/`) :

- `fileMCP.pb` — gestion de fichiers confinée (`MCP_ROOT`/`MCP_ROOT_SECRET`)
- `MCP-Fetch-PB.pb` — fetch web (HTML → Markdown, protection SSRF)
- `MCP-SequentialThinking-PB.pb` — raisonnement séquentiel
- `memoryMCP.pb` + `memory_core.pbi` — mémoire SQLite (`MCP_MEMORY_DB`)
- `dbMCP.pb` + `db_core.pbi` — exploration SQL (SQLite + PostgreSQL optionnel, lecture seule par défaut)
- `context7MCP.pb` + `context7_core.pbi` — documentation Context7 (`MCP_CONTEXT7_API_KEY`)
- `gitMCP.pb` + `git_core.pbi` — exploration de dépôts git locaux (sous-processus git)
- `githubMCP.pb` + `github_core.pbi` — API REST GitHub (`MCP_GITHUB_TOKEN`, mock pour les tests)

Transport **JSON-RPC 2.0 sur HTTP**, endpoint `POST /mcp`, réponse
`application/json`. **Aucun SSE** : pas de `text/event-stream`, pas de flux
d'événements, pas de session `Mcp-Session-Id`. `GET /mcp` et `DELETE /mcp`
renvoient `405` (`Allow: POST`). Chaque processus écoute par défaut sur
`127.0.0.1` avec un port distinct (8101 à 8108, surchargeable via
`MCP_HTTP_PORT`). `GET /health` expose l'état.

Exécutables **console**, 100 % natifs, multi-OS (Windows / Linux / macOS).
Le cœur métier d'un serveur va dans `src/<serveur>_core.pbi` (testable), le
`.pb` ne contient que le `main` (lecture d'env + hooks + `MCPHttpMainLoop()`).

## Transport HTTP : règles non négociables

- **Pas de SSE.** Ne jamais répondre `text/event-stream`, ne jamais ouvrir de
  flux d'événements. Le client envoie un POST JSON et reçoit un JSON.
- **Une requête par connexion** (`Connection: close`), pas de keep-alive.
- **`Content-Length` obligatoire** pour POST ; `Transfer-Encoding: chunked`
  est refusé (`501`).
- **Corps maximal** 1 Mio par défaut (`MCP_HTTP_MAX_BODY`), réponse `413`.
- **Notifications** JSON-RPC : `202 Accepted`, corps vide.
- **Erreurs JSON-RPC** (`-32700`, `-32600`, `-32601`, `-32603`) : HTTP `200`
  avec un objet `error` ; les erreurs de transport utilisent les codes 4xx/5xx.
- **Sécurité réseau** : bind loopback par défaut, validation `Origin`, jeton
  Bearer optionnel (`MCP_HTTP_TOKEN`). Toute nouvelle route doit passer par
  ces contrôles.
- **Traitement séquentiel** : un seul appel d'outil à la fois par processus.
  Ne pas introduire de threads sans revoir la sécurité et les tests.

## Commandes essentielles

```bash
build.bat              # Windows : compile les 8 serveurs -> build\*.exe
./build.sh             # Linux/macOS : compile les 8 serveurs -> build/
start_all.bat          # Windows : lance les 8 serveurs en arrière-plan
./start_all.sh         # Linux/macOS : idem
stop_all.bat           # Windows : arrête les 8 serveurs
./stop_all.sh          # Linux/macOS : idem
run_all.bat            # compilation + 6 suites unitaires + robustesse/perf + intégration + report.html
./run_all.sh           # idem sous Linux/macOS
python tests/test_mcp.py [serveur]   # intégration seule (118 tests)
./clean.sh             # nettoie build/
```

## Architecture (mcp_common/)

Ordre d'inclusion dans un serveur HTTP :

```purebasic
IncludeFile "../mcp_common/runtime.pbi"        ; stderr, CheckRuntime
IncludeFile "../mcp_common/logging.pbi"        ; LogDebug / LogError (stderr)
IncludeFile "../mcp_common/json_helpers.pbi"   ; GetArg*, AddProp*, ToolDef
IncludeFile "../mcp_common/http.pbi"           ; client HTTP (API web, optionnel)
IncludeFile "../mcp_common/protocol.pbi"       ; identité + initialize
IncludeFile "../mcp_common/jsonrpc.pbi"        ; noyau JSON-RPC
IncludeFile "../mcp_common/http_server.pbi"    ; serveur HTTP + MCPHttpMainLoop
```

Puis : renseigner `G_ServerName`/`G_ServerVersion`, affecter
`*G_ToolHandler` et `*G_CatalogBuilder`, vérifier `CheckRuntime()`, appeler
`MCPHttpMainLoop(<port>)` et propager l'échec (`End 1`). Modèle complet :
`examples/minimal_server.pb`.

`http_server.pbi` gère : parsing HTTP, `Content-Length`, accumulation des
paquets, timeout d'inactivité, `Origin`, jeton, taille de corps, `/health`,
routage et réponses. **Ne pas dupliquer** cette logique dans un serveur.

## Règles à respecter impérativement

1. **`EnableExplicit`** : toute variable doit être déclarée.
2. **Transport HTTP uniquement** : ne pas réintroduire `stdin`/`stdout`,
   `ReadStdinLine`, `SendRawLine`, `MCPMainLoop` ni de boucle stdio. Logs
   uniquement sur **stderr**.
3. Sélection OS par `CompilerIf #PB_Compiler_OS = #PB_OS_Windows` /
   `CompilerElse` — le code doit compiler sur les 3 plateformes.
4. Commentaires et messages d'erreur en **français**, style du fichier.
5. Aucune duplication de code HTTP/JSON-RPC/console dans un serveur : tout va
   dans `mcp_common/`.
6. Tout nouvel outil MCP doit :
   - être ajouté au catalogue (`BuildToolsCatalog` / `XxxBuildCatalog`) ;
   - avoir son `Case` dans le dispatch ;
   - assainir ses entrées (chemins, refs, segments d'URL) avant usage ;
   - commencer ses messages d'échec par `Erreur` / `ERREUR` / `Impossible` /
     `Echec` ou contenir `introuvable` / `refusee` / `depasse` pour que
     `isError` soit positionné (heuristique `DetectIsError`) ;
   - être couvert par un test unitaire (`tests/test_<serveur>.pb`) et/ou
     d'intégration (`tests/test_mcp.py`).
7. Protections obligatoires : confinement `MCP_ROOT` (fileMCP), écritures SQL
   derrière `MCP_DB_ALLOW_WRITE`, écritures GitHub derrière `confirm=true`,
   validation anti-injection (`GitSafeParam`, `GhSafeSegment`).
8. Ne jamais élargir le périmètre de sécurité sans demande explicite.
9. Les exécutables vont dans `build/` (gitignoré) — jamais de binaire commité.
10. **Pas de SSE** : toute contribution qui ajoute un flux d'événements ou un
    endpoint `text/event-stream` est hors périmètre.

## Pièges PureBasic rencontrés (ne pas les réintroduire)

- **Mots réservés** : `Args`, `To`, `Result` ne peuvent pas être des noms de
  variables/paramètres. Renommer (`GitArgs`, `Dest`, `R`).
- **Paramètres structure** : passage **par pointeur uniquement** —
  `Procedure Foo(*P.MaStructure)` + appel `Foo(@MaVar)`.
  `Procedure Foo(P.MaStructure)` est une erreur de syntaxe.
- **Piège `Protected Status.Integer`** : `Integer` est une *structure* ;
  l'utiliser comme scalaire (`Str(Status)`, comparaisons) donne l'adresse de la
  structure. Déclarer `Status.i` et passer `@Status` au pointeur typé
  `*Status.Integer`.
- **Curseur `ForEach`** : un `ForEach` imbriqué déplace le curseur du `ForEach`
  externe → boucle infinie. Utiliser une map de membership ou un index.
- **`Trim()` PureBasic** ne retire pas `#CR$`/`#LF$` (seulement espaces/tabs) :
  utiliser `TrimOut()` (git_core) ou `ReplaceString`.
- **Chaînes JSON en PureBasic** : `~"{\"cle\":\"valeur\"}"` (préfixe `~`) ;
  un `\"` dans une chaîne normale est une erreur de compilation.
  Utiliser `EscapeString(..., #PB_String_EscapeJSON)` pour un id JSON.
- **`OpenDatabase`** (SQLite) exige un fichier existant : créer le fichier vide
  avant ouverture.
- **PRAGMA / EXPLAIN** : colonnes sans type déclaré ; utiliser
  `CheckDatabaseNull` pour distinguer un vrai NULL.
- **Sous-processus (RunProgram)** : `ReadProgramString` doit être lu dans une
  boucle jusqu'à `ProgramRunning() = 0` (sinon sortie vide). stderr n'est pas
  lisible de façon fiable → passer par le shell avec `2>&1`
  (`cmd.exe /c ""exe" args 2>&1"`) après validation stricte des entrées.
- **HTTP client avec en-têtes** : WinHTTP sous Windows ; sous Linux/macOS, le
  HTTP intégré n'offre pas d'en-têtes → `mcp_common/http.pbi` passe par
  **curl** (fichier de configuration, pas de quoting shell).
- **Serveur réseau PureBasic** :
  - `InitNetwork()` **n'existe pas** : ne pas l'appeler ; `CreateNetworkServer`
    initialise la couche réseau ;
  - `CreateNetworkServer(#PB_Any, Port, #PB_Network_TCP | #PB_Network_IPv4, HostIP$)` ;
  - `NetworkServerEvent()` + `EventClient()` + `Delay()` dans une boucle
    console ; pas de fenêtre nécessaire ;
  - `ReceiveNetworkData()` peut retourner `0` ou `-1` quand la suite du corps
    n'est pas encore arrivée : retenter avec `Delay(1)` (voir
    `HttpReadBody`), ne pas conclure à une erreur ;
  - `SendNetworkData()` peut envoyer partiellement : boucler jusqu'à
    épuisement (voir `HttpSendBytes`) ;
  - fermer avec `Connection: close` et `CloseNetworkConnection()` ;
  - ne pas oublier `FreeMemory()` de l'état de connexion.
- **RunProgram sous Linux** ne gère pas les guillemets dans les arguments :
  écrire un script temporaire (`git_core.pbi` le fait) ou passer par curl -K.
- **Fins de ligne** : `.gitattributes` impose LF aux `.sh/.py/.pb/.pbi/.md`
  (un shebang en CRLF casse l'exécution sous WSL) ; `.bat` en CRLF.
- **IDE/projets** : `.pbi` = module d'inclusion ; un projet IDE est un `.pbp`
  (non fourni, voir README). Ne pas inventer de format de projet.

## Protocole MCP (rappel HTTP)

- Requête : `POST /mcp` avec
  `{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"...","arguments":{...}}}`.
- Réponse : HTTP `200`, `result.content[0].text` + `result.isError`.
- `initialize` : renvoie `protocolVersion` (`2025-06-18` par défaut) et
  `serverInfo`.
- `tools/list` : renvoie le catalogue.
- `notifications/initialized` : pas de réponse JSON-RPC ; HTTP `202`.
- `GET /mcp` : `405`, **jamais** de SSE.
- Variables d'environnement par serveur : voir README et SECURITY.md.

## Structure

```
mcp_common/                       modules partages (runtime, logging, json_helpers, http, protocol, jsonrpc, http_server)
src/fileMCP.pb                    gestion de fichiers
src/MCP-Fetch-PB.pb               fetch web
src/MCP-SequentialThinking-PB.pb  raisonnement sequentiel
src/memoryMCP.pb + memory_core.pbi      memoire SQLite
src/dbMCP.pb + db_core.pbi              exploration SQL (sqlite + postgres)
src/context7MCP.pb + context7_core.pbi  documentation Context7
src/gitMCP.pb + git_core.pbi            exploration git locale
src/githubMCP.pb + github_core.pbi      API REST GitHub
examples/minimal_server.pb        serveur MCP HTTP minimal de demo (port 8090)
examples/mcp.json                 configuration client HTTP complete (8 serveurs)
.gitattributes                    fins de ligne (LF scripts/sources, CRLF .bat)
build.bat/build.sh                compilation des 8 serveurs ; clean.* : nettoyage
start_all.bat/.sh                 lancement des 8 serveurs en arriere-plan
stop_all.bat/.sh                  arret des serveurs
run_all.bat/run_all.sh            compilation + tests unitaires + integration + rapport
tests/mcp_client.py               harnais de test externe (client MCP HTTP)
tests/mock_github.py              mock local de l'API GitHub
tests/test_mcp.py                 tests d'integration + transport (118 tests)
tests/unit_test.pbi               framework de tests unitaires PureBasic
tests/test_common.pb              tests unitaires mcp_common (41 tests)
tests/test_memory.pb              tests unitaires Memory (33 tests)
tests/test_database.pb            tests unitaires Database (37 tests)
tests/test_context7.pb            tests unitaires Context7 (19 tests)
tests/test_git.pb                 tests unitaires Git (24 tests)
tests/test_github.pb              tests unitaires GitHub (40 tests)
tests/test_robustness.py          robustesse T6.1-T6.15 + perf T6.9-T6.14
tests/make_report.py              rapport HTML depuis report.json
```

Voir aussi : [PLAN.md](PLAN.md), [README.md](README.md),
[CONTRIBUTING.md](CONTRIBUTING.md), [ROADMAP.md](ROADMAP.md),
[ERRATA.md](ERRATA.md), [SECURITY.md](SECURITY.md).
