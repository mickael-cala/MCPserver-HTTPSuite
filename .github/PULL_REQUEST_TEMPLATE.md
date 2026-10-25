## Description

<!-- Que fait cette pull request ? Référence l'issue : Fixes #123 -->

## Vérifications effectuées

- [ ] Compilation : `build.bat` / `./build.sh` OK
- [ ] Tests : `run_all.bat` / `./run_all.sh` → 10/10 étapes (199 unitaires,
      21 robustesse/perf, 124 intégration)
- [ ] Nouvel outil MCP éventuel : ajouté au catalogue, au dispatch, entrées assainies, testé
- [ ] Messages d'échec détectés comme erreurs (`Erreur` / `Impossible` / `Echec` / `introuvable` / `refusee` / `depasse`)
- [ ] Transport HTTP respecté : `POST /mcp`, JSON par défaut, SSE optionnel
      uniquement si `Accept: text/event-stream`, `GET /mcp` → 405 sans Accept
- [ ] Nouvelle route éventuelle : `Origin`, jeton, `Content-Length` et taille
      de corps passés par `http_server.pbi`
- [ ] Confinement : symlinks/junctions et SSRF DNS vérifiés si le code touche
      `fileMCP` ou `MCP-Fetch-PB`
- [ ] Budgets conservés : fetch ≤ 2 Mo, recherche ≤ profondeur 32 / 10 000
      entrées / 10 s

## Sécurité

<!-- Toute modification de ValiderChemin, change_root, des symlinks/junctions,
     de l'anti-SSRF DNS, du plafond fetch, de la couche HTTP
     (Origin, MCP_HTTP_TOKEN, MCP_HTTP_MAX_BODY) ou de la gestion des secrets
     a-t-elle été revue avec attention ? -->
