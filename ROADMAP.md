# Feuille de route

Les 8 serveurs MCP (phases 0 à 7, voir [PLAN.md](PLAN.md)) sont livrés en
**version 2.0.0** avec un transport **HTTP JSON-RPC** et **SSE optionnel**.

## Court terme

- Publier une release **v2.0.0** avec les binaires **Windows**, **Linux** et
  **macOS** (si validé) et un `SHA256SUMS`.
- **Valider macOS** (le code et `build.sh` sont prêts ; prérequis : `curl`).
- Ajouter une **CI GitHub Actions** (matrice Windows/Linux) si un runner avec
  PureBasic sous licence devient disponible.
- Compléter les tests de transport : `Expect: 100-continue`, en-têtes
  dupliqués, requêtes partielles volontairement fragmentées.

## Moyen terme

- **Sécurité restante** : rate limiting, comparaison constante-time du secret,
  validation de schéma côté serveur, assainissement des liens Markdown,
  et réduction de la fenêtre TOCTOU symlink/DNS.
- **SSE avancé** : notifications serveur→client, progression d'outils et
  reprise de flux (`Last-Event-ID`) ; aujourd'hui le flux SSE sert de canal de
  compatibilité avec keep-alive.
- **TLS natif optionnel** (`MCP_HTTP_TLS_CERT` / `MCP_HTTP_TLS_KEY`) via
  `UseNetworkTLS()` ; en attendant, recommander un reverse proxy HTTPS.
- **Concurrence** : traiter plusieurs requêtes en parallèle (threads ou
  multiplexage) sans bloquer `/health` pendant un appel long.
- **Limites de débit** par client (protections anti-abus) et journalisation
  structurée optionnelle.
- **Fetch/SequentialThinking** : extraction HTML→Markdown plus riche (tableaux,
  code), persistance optionnelle de l'historique de raisonnement.
- **FileMCP** : `copy_file`, suppression récursive optionnelle, pagination de
  `list_files`/`search_files`, lecture binaire base64.
- **Memory** : recherche plein texte (FTS5), export/import JSON du graphe.
- **Database** : PostgreSQL avec binding de paramètres, `db_explain` formaté.
- **Git** : `git_log` avec plage de dates, `git_diff --stat`, `--no-color`.
- **GitHub** : commentaires d'issues, review de PR, pagination automatique.
- **Context7** : cache local des réponses par bibliothèque.
- Fichier de configuration JSON commun en alternative aux variables
  d'environnement.

## Hors périmètre

- **SSE obligatoire** : le transport ne force jamais SSE ; un client qui
  refuse à la fois JSON et SSE n'est pas supporté.
- **Transport stdio** : remplacé en 2.0.0 ; non maintenu.
- Sessions persistantes et streaming de résultats d'outils : non prévus dans
  l'immédiat (serveur sans état, une requête POST par connexion).
