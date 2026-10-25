# Errata — limitations et problèmes connus

## Couverture par serveur

| Serveur | Limitations connues |
|---|---|
| `fileMCP` | `read_file` tronqué à 20 Ko, `read_file_lines` ≤ 5 Mo, dossiers non vides non supprimés |
| `MCP-Fetch-PB` | conversion HTML→Markdown basique ; pas de JS ; hôtes privés refusés |
| `MCP-SequentialThinking-PB` | état en mémoire (perdu à l'arrêt) ; pas de persistance |
| `memoryMCP` | une instance écrit à la fois (SQLite, pas de WAL) ; pas de FTS |
| `dbMCP` | lecture seule par défaut ; PostgreSQL sans binding de paramètres |
| `context7MCP` | `query_docs` exige une clé ; hors ligne → erreur explicite |
| `gitMCP` | sous-processus git requis ; sortie plafonnée à 40 Ko |
| `githubMCP` | token requis ; écritures via `confirm=true` ; pagination manuelle |

## Limitations par design (transport HTTP)

- **SSE optionnel, jamais imposé** : `GET /mcp` avec
  `Accept: text/event-stream` ouvre un flux `text/event-stream` (commentaire
  `: connected`, puis `: keep-alive` toutes les 15 s). Sans cet en-tête,
  `GET /mcp` renvoie `405`. `POST /mcp` répond en SSE si le client l'accepte,
  sinon en JSON. `DELETE /mcp` renvoie `204`.
- **Pas de messages JSON-RPC serveur→client sur le flux SSE** : le flux sert
  uniquement de canal de compatibilité et d'acquittement (commentaires
  keep-alive). Pas de notifications serveur, pas de sampling/roots.
- **Serveur sans état** : pas de `Mcp-Session-Id`, pas de reprise de session.
  Chaque requête POST est indépendante.
- **POST : une requête par connexion** (`Connection: close`) ; **GET SSE** :
  flux persistant. Pas de pipelining HTTP.
- **Traitement séquentiel** : un seul appel d'outil à la fois par processus.
  Un outil long (fetch, git, GitHub) bloque les autres requêtes du même
  serveur, y compris `/health`.
- **Pas de streaming de résultats d'outil** : la réponse complète est envoyée
  d'un bloc (`Content-Length` en JSON, un événement `message` en SSE).
- **Pas de `Transfer-Encoding: chunked`** : le client doit envoyer
  `Content-Length` (`501` sinon).
- **Corps limité à 1 Mio** par défaut (`MCP_HTTP_MAX_BODY`) : au-delà,
  réponse `413`. Le serveur draine une partie du corps pour permettre au
  client de lire la réponse.
- **Timeout d'inactivité de 10 s** pour les en-têtes/corps : un client très
  lent reçoit `408`.
- **Pas de TLS natif** : le transport est HTTP en clair. Pour HTTPS, placer
  un reverse proxy devant le serveur (et garder l'écoute sur loopback).
- **Pas de CORS** : les origines étrangères sont refusées (`403`) ; aucun
  en-tête `Access-Control-Allow-Origin` n'est émis.
- **Une seule instance par port** : un second processus sur le même port
  échoue au démarrage (code 1, message explicite).

## Limitations métier

- **`read_file` tronque au-delà de 20 000 octets** ; utiliser `read_file_lines`
  pour les gros fichiers (limite 5 Mo).
- **Aucune gestion des fichiers binaires** : les extensions exécutables
  (`exe`, `dll`, `so`, `dylib`…) sont refusées par les outils de lecture.
- **`delete_file` ne supprime que les dossiers vides** ; pas de suppression
  récursive (voir la roadmap).

## Problèmes connus

- La détection d'erreur (`isError`) repose sur une heuristique sur le texte de
  réponse (`Erreur`, `Impossible`, `Echec`, `introuvable`, `refusee`,
  `depasse`). Un message utilisateur contenant ces mots en début de ligne
  pourrait être mal classé.
- `change_root` avec un secret incorrect renvoie `isError: true` mais le
  texte reste en français non structuré ; les clients doivent tester le
  drapeau, pas le texte.
- **Validation** : la version 2.0.0 (HTTP) est compilée et testée sous
  **Windows** et **Linux (WSL2 Ubuntu 26.04)** (10/10, 199 unitaires,
  21 robustesse/perf, 121 intégration). La validation **macOS** reste à faire.
- Aucune CI automatisée (PureBasic sous licence).

## Résultats des tests

Dernières exécutions de `run_all` (Windows et Linux/WSL2) : **10/10 étapes** — tests
unitaires 46 + 33 + 37 + 19 + 24 + 40 = **199** réussis (mcp_common, Memory,
Database, Context7, Git, GitHub), robustesse/performance **21/21**,
tests d'intégration **121/121** (8 serveurs + transport ; PostgreSQL et
Context7 live sont ignorés sans configuration/réseau, GitHub utilise un mock
local).

## Comportements documentés

- **Deux instances Memory sur la même base** : SQLite autorise plusieurs
  connexions ; les écritures sont sérialisées (verrou d'écriture), les
  lectures voient l'état validé. Aucun mode WAL n'est activé : des écritures
  concurrentes longues peuvent produire une erreur `database is locked`
  remontée proprement par l'outil.
- **Corps HTTP > 1 Mio** : réponse `413` ; le serveur lit/ignore au plus
  1 Mio supplémentaire avant de fermer pour éviter un blocage du client.
- **En-têtes HTTP hors Windows** : assurés par **curl** (config file). Si curl
  est absent, `context7MCP`/`githubMCP` retournent une erreur explicite.
- **Compilation Linux** : nécessite `libssl-dev` et `libsqlite3-dev`
  (bibliothèques liées par PureBasic) ; `curl` pour les appels HTTP avec
  en-têtes. `build.sh` et le serveur HTTP utilisent la bibliothèque réseau
  intégrée de PureBasic (aucune dépendance supplémentaire).
- **Ports par défaut** : 8101 fileMCP, 8102 Fetch, 8103 SequentialThinking,
  8104 Memory, 8105 Database, 8106 Context7, 8107 Git, 8108 GitHub. Utiliser
  `MCP_HTTP_PORT` pour un serveur isolé, pas pour `start_all`.
