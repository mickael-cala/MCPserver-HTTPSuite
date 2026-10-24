## Description

<!-- Que fait cette pull request ? Référence l'issue : Fixes #123 -->

## Vérifications effectuées

- [ ] Compilation : `build.bat` / `./build.sh` OK
- [ ] Tests : `run_all.bat` / `./run_all.sh` → 10/10 étapes (194 unitaires,
      21 robustesse/perf, 118 intégration)
- [ ] Nouvel outil MCP éventuel : ajouté au catalogue, au dispatch, entrées assainies, testé
- [ ] Messages d'échec détectés comme erreurs (`Erreur` / `Impossible` / `Echec` / `introuvable` / `refusee` / `depasse`)
- [ ] Transport HTTP respecté : `POST /mcp`, JSON uniquement, aucun SSE,
      `GET /mcp` → 405
- [ ] Nouvelle route éventuelle : `Origin`, jeton, `Content-Length` et taille
      de corps passés par `http_server.pbi`

## Sécurité

<!-- Toute modification de ValiderChemin, change_root, de la couche HTTP
     (Origin, MCP_HTTP_TOKEN, MCP_HTTP_MAX_BODY) ou de la gestion des secrets
     a-t-elle été revue avec attention ? -->
