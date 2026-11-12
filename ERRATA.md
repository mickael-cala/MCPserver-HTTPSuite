# Errata — limitations et problèmes connus

## Couverture par serveur

| Serveur | Limitations connues |
|---|---|
| `fileMCP` | `read_file`/`read_file_lines` limités à 2 Mio, symlinks/junctions sous la racine refusés, `exec` exige `confirm=true` (sortie 64 Kio, timeout ≤ 60 s) |
| `MCP-Fetch-PB` | conversion HTML→Markdown basique ; pas de JS ; hôtes privés/loopback/ULA/link-local refusés via DNS ; ports limités à 80 (http) / 443 (https) ; redirections suivies manuellement (≤ 5 sauts, chacun revalidé) ; IP validée épinglée (anti DNS rebinding) ; réponse ≤ 2 Mo |
| `MCP-SequentialThinking-PB` | état en mémoire (perdu à l'arrêt) ; pas de persistance |
| `memoryMCP` | une instance écrit à la fois (SQLite, pas de WAL) ; pas de FTS ; jokers `%`/`_` de `search_nodes` échappés (recherche littérale) ; bornes d'entrées (≤ 100 items/appel, noms ≤ 256, observations ≤ 128 Kio) |
| `dbMCP` | lecture seule par défaut (applicative **et** moteur : `PRAGMA query_only` / `default_transaction_read_only`, fixée à l'ouverture) ; `;` refusé ; `EXPLAIN` exclu de la whitelist ; PostgreSQL sans binding de paramètres |
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

## Durcissement sécurité (Phase 8)

- **fileMCP** : les symlinks/junctions situés **sous** `MCP_ROOT` sont
  refusés. La racine elle-même peut être un lien (choix de l'utilisateur),
  mais `change_root` refuse une nouvelle racine qui est un lien/junction.
  Résiduel : un attaquant local avec un accès écriture à la racine pourrait
  permuter un composant entre la validation et l'opération (TOCTOU).
- **search_files** : profondeur max 32, 10 000 entrées, timeout 10 s ; les
  liens sont ignorés. Une recherche très profonde est donc tronquée.
- **fetch** : la résolution DNS utilise `getent` (Linux), `nslookup`
  (Windows) ou `dscacheutil` (macOS), avec un timeout de 5 s. Si l'outil de
  résolution est absent, échoue ou dépasse le délai, la requête est
  **refusée** (fail closed). Toute IP privée, loopback, ULA, link-local ou de
  documentation est refusée.
  Résiduel : la résolution est faite avant la connexion HTTP ; un DNS
  malveillant peut changer la réponse entre les deux (DNS rebinding).
- **fetch** : la réponse est plafonnée à **2 Mo** avant conversion Markdown.
  Un serveur qui envoie plus est rejeté (`reponse trop volumineuse`).
- Les liens `javascript:` présents dans le HTML source peuvent encore
  apparaître dans le Markdown généré ; les clients doivent assainir le rendu.

## Limitations métier

- **`read_file`/`read_file_lines` limitent les fichiers à 2 Mio** (troncation
  annoncée avec la taille réelle pour `read_file`).
- **Aucune gestion des fichiers binaires** : les extensions exécutables
  (`exe`, `dll`, `so`, `dylib`…) sont refusées par les outils de lecture.
- **`exec` (fileMCP)** : exécution shell exigeant `confirm=true` par commande
  ou par lot. Le répertoire de travail est confiné sous `MCP_ROOT` mais la
  commande elle-même peut toucher tout le système (chemins absolus, `cd ..`).
  Sortie stdout+stderr fusionnée, bornée à 64 Kio (`[... sortie tronquee ...]`) ;
  timeout `timeoutMs` (défaut 10 s, borné 1–60 s) au-delà duquel le processus
  est tué ; lot `commands` (≤ 20) exécuté dans **un seul** shell (état partagé
  entre les commandes) ; code de sortie non nul → `isError: true`. Sous
  Windows, le script `.cmd` est écrit en ASCII : les accents d'une commande
  peuvent être dégradés par la page de code de `cmd.exe` (la sortie est lue
  en UTF-8).

## Problèmes connus

- La détection d'erreur (`isError`) repose sur le **préfixe** du texte de
  réponse (`Erreur`, `ERREUR`, `Impossible`, `Echec`) — depuis le niveau 3,
  les anciennes règles « contient » (`introuvable`, `refusee`, `depasse`)
  sont supprimées : un contenu réussi contenant ces mots (sortie de grep,
  fichier lu) n'est plus marqué en erreur. Tous les messages d'échec des
  serveurs commencent par un marqueur ; les clients doivent tester le
  drapeau `isError`, pas le texte. Outil inconnu → erreur JSON-RPC
  `-32602` (protocole), distincte d'un échec d'exécution.
- `change_root` avec un secret incorrect renvoie `isError: true` mais le
  texte reste en français non structuré ; les clients doivent tester le
  drapeau, pas le texte.
- **Validation** : le durcissement sécurité (audit C1-C3/I1-I2, voir
  SECURITY-AUDIT.md) et l'outil `exec` sont compilés et testés sous
  **Windows** et **Linux (WSL2 Ubuntu 26.04)** (10/10, **204 unitaires**,
  21 robustesse/perf, **150 intégration**). Référence 2.0.0 : 124 intégration.
  La validation **macOS** reste à faire.
- Aucune CI automatisée (PureBasic sous licence).

## Résultats des tests

Dernières exécutions de `run_all` (Windows ET Linux/WSL2, incluant `exec` et
le durcissement sécurité) : **10/10 étapes** — tests
unitaires 47 + 33 + 41 + 19 + 24 + 40 = **204** réussis (mcp_common, Memory,
Database, Context7, Git, GitHub), robustesse/performance **21/21**,
tests d'intégration **150/150** (8 serveurs + transport ; PostgreSQL et
Context7 live sont ignorés sans configuration/réseau, GitHub utilise un mock
local). Références antérieures : 132/132 (exec seul, Windows), 124/124
(2.0.0).

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
