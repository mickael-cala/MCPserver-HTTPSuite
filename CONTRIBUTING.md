# Contribuer au projet

Merci de votre intérêt ! Ce dépôt est un projet personnel, mais les
signalements de bugs et les suggestions sont les bienvenus.

Le dépôt contient **8 serveurs MCP** (45 outils) exposés en **HTTP JSON-RPC**
(`POST /mcp`, SSE optionnel) ; voir la liste, les ports et les variables
d'environnement dans [README.md](README.md).

## Signaler un bug ou proposer une fonctionnalité

Utilisez les [issues GitHub](https://github.com/mickael-cala/MCPserver-HTTPSuite/issues)
avec les modèles fournis (bug, fonctionnalité). Incluez si possible :

- le système d'exploitation et la version de PureBasic ;
- le serveur concerné, l'URL/le port, la requête JSON-RPC envoyée et la
  réponse HTTP/JSON obtenue ;
- le résultat de `python tests/test_mcp.py` (124 tests) et/ou
  `run_all.bat` / `./run_all.sh`.

## Soumettre une modification

1. Forkez le dépôt et créez une branche depuis `main`.
2. Modifiez le code source concerné dans `src/` (le cœur métier d'un serveur
   est dans `src/<serveur>_core.pbi`, le `.pb` ne contient que le `main`).
   Prérequis Linux : `sudo apt install libssl-dev libsqlite3-dev curl`.
3. Vérifiez que tout passe :
   ```bash
   build.bat            # ou ./build.sh : compile les 8 serveurs
   run_all.bat          # ou ./run_all.sh : unitaires + intégration + rapport
   ```
4. Ouvrez une pull request vers `main` en remplissant le modèle.

## Conventions de code

- **PureBasic** avec `EnableExplicit` obligatoire.
- Commentaires et messages d'erreur en **français**, comme le code existant.
- Sélection multi-OS par `CompilerIf #PB_Compiler_OS = #PB_OS_Windows`, jamais
  par hacks runtime. Ne pas mélanger les options de compilation : `build.bat`
  = options Windows (`/EXE`, `/CONSOLE`), `build.sh` = options POSIX
  (`-o`, `-cl`, `-t`).
- Fins de ligne : `.gitattributes` impose LF aux scripts et sources
  (un shebang en CRLF casse l'exécution sous Linux/WSL), CRLF aux `.bat`.
- **Transport HTTP uniquement** : ne pas réintroduire `stdin`/`stdout`,
  `ReadStdinLine`, `SendRawLine` ou `MCPMainLoop`. Utiliser
  `mcp_common/http_server.pbi` et `MCPHttpMainLoop()`. **SSE optionnel** :
  `GET /mcp` n'ouvre un flux que si le client envoie
  `Accept: text/event-stream` ; `POST` répond en JSON par défaut. Ne jamais
  imposer SSE.
- **Architecture** : un serveur inclut `mcp_common/` dans l'ordre :
  `runtime`, `logging`, `json_helpers`, `http` si besoin, `protocol`,
  `jsonrpc`, `http_server` ; renseigne `G_ServerName`/`G_ServerVersion`, les
  hooks `*G_ToolHandler` et `*G_CatalogBuilder`, puis appelle
  `MCPHttpMainLoop(<port>)`. Modèle : `examples/minimal_server.pb`.
- **Aucune duplication** de code console/JSON-RPC/HTTP dans un serveur.
- Toute nouvelle route HTTP doit passer par les contrôles de
  `http_server.pbi` : `Origin`, jeton Bearer si `MCP_HTTP_TOKEN`, taille de
  corps, `Content-Length`, timeout.
- Tout nouvel outil MCP doit :
  - être ajouté au catalogue (`BuildToolsCatalog` / `XxxBuildCatalog`) ;
  - avoir son `Case` dans le dispatch ;
  - assainir ses entrées (chemins, refs, segments d'URL) avant usage ;
  - commencer ses messages d'échec par `Erreur` / `ERREUR` / `Impossible` /
    `Echec` ou contenir `introuvable` / `refusee` / `depasse` pour que
    `isError` soit positionné ;
  - être couvert par un test (unitaire `.pb` et/ou intégration Python).
- Les écritures destructrices ou externes (fichiers, SQL, API GitHub) doivent
  être explicitement protégées (confinement `MCP_ROOT`, `MCP_DB_ALLOW_WRITE`,
  `confirm=true`).

## Tests

- Unitaires PureBasic : `tests/test_<module>.pb` (framework `tests/unit_test.pbi`).
- Intégration : `tests/test_mcp.py` (harnais HTTP `tests/mcp_client.py` ;
  mock GitHub dans `tests/mock_github.py` ; PostgreSQL et Context7 live sont
  conditionnels).
- Robustesse/performance : `tests/test_robustness.py` (charge HTTP, corps
  1 Mio, JSON malformé, port occupé, SSE non imposé, perf).
- Compteurs de référence : **199 unitaires**, **21 robustesse/perf**,
  **124 intégration**, `run_all` **10/10**.
- `run_all` doit être **vert (10/10)** avant toute pull request.
- PureBasic Free : garder chaque fichier source sous ~800 lignes (le serveur
  HTTP est scindé en `http_server.pbi` + `http_sse.pbi`).

## Sécurité

Voir [SECURITY.md](SECURITY.md). Toute modification touchant au confinement
des chemins (symlinks/junctions), à l'anti-SSRF (résolution DNS), au plafond
de réponse fetch, aux garde-fous d'écriture, à la couche HTTP (Origin, jeton,
taille de corps) ou à la gestion des secrets exige une revue attentive.
