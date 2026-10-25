# Sécurité

## Signaler une vulnérabilité

**Ne publiez pas de vulnérabilité dans les issues publiques.**

Ouvrez plutôt un avis de sécurité privé via
[GitHub Security Advisories](https://github.com/mickael-cala/MCPserver-HTTPSuite/security/advisories/new)
(contact : `mickael-cala`). Vous recevrez une réponse sous quelques jours ;
une correction sera publiée avant toute divulgation publique.

## Modèle de sécurité

Le dépôt contient 8 serveurs MCP, chacun avec ses garde-fous métier et une
couche HTTP commune :

| Serveur | Surface | Protections |
|---|---|---|
| `fileMCP` | Système de fichiers | Confinement à `MCP_ROOT`, normalisation des chemins (traversées `..` refusées), **symlinks/junctions sous la racine refusés**, `change_root` protégé par `MCP_ROOT_SECRET` |
| `memoryMCP` | Base SQLite | Échappement SQL (apostrophes doublées), FK en cascade, base locale (`MCP_MEMORY_DB`) |
| `dbMCP` | Bases SQL | **Lecture seule par défaut** (`IsReadOnlyQuery`), écritures uniquement avec `MCP_DB_ALLOW_WRITE=1`, refus journalisés |
| `context7MCP` | API web | HTTP/HTTPS uniquement, clé API jamais loggée (WinHTTP/curl) |
| `gitMCP` | Sous-processus git | `GitSafeParam` rejette les métacaractères shell sur tous les paramètres |
| `githubMCP` | API GitHub | Écritures exigeant `confirm=true`, token jamais renvoyé ni loggé, pagination bornée, validation des segments d'URL |
| `MCP-Fetch-PB` | API web | HTTP/HTTPS uniquement, IP privées/loopback/ULA/link-local refusées, **résolution DNS vérifiée** (anti-SSRF), **réponse plafonnée à 2 Mo** |
| `MCP-SequentialThinking-PB` | État local | Aucune I/O externe |

## Surface réseau HTTP

Le transport est **HTTP JSON-RPC** (`POST /mcp`) avec **SSE optionnel**
(`GET /mcp` + `Accept: text/event-stream`). Il n'y a pas de session serveur.
Un flux SSE ne transporte que des commentaires keep-alive ; aucun message
JSON-RPC serveur→client n'y est envoyé.

| Contrôle | Comportement |
|---|---|
| Écoute par défaut | `MCP_HTTP_HOST=127.0.0.1` (loopback uniquement) |
| Authentification | `MCP_HTTP_TOKEN` : `Authorization: Bearer <token>` exigé sur `POST /mcp` et `GET /mcp` (SSE) ; `401` sinon |
| Origines | `Origin` absente ou loopback du port courant (`127.0.0.1`, `localhost`, `[::1]`) ; sinon `403`. `MCP_HTTP_ALLOWED_ORIGINS` pour une liste explicite |
| Taille du corps | 1 Mio par défaut (`MCP_HTTP_MAX_BODY`, borné 1 Kio–16 Mio) ; `413` au-delà |
| En-têtes | Limite 16 Kio ; `431` au-delà |
| Timeout | 10 s d'inactivité pour les en-têtes/corps ; `408` |
| Transfert | `Content-Length` obligatoire pour POST ; `Transfer-Encoding: chunked` refusé (`501`) |
| Connexions | 64 requêtes en cours et 64 flux SSE maximum ; `503` au-delà |
| SSE | Flux `text/event-stream` uniquement si demandé ; `Origin` et jeton vérifiés ; keep-alive 15 s ; pas de messages serveur→client |
| CORS | Aucun `Access-Control-Allow-Origin` ; les navigateurs ne peuvent pas lire les réponses |
| Journalisation | Méthode, chemin, statut et durée sur **stderr** ; jamais le corps, jamais un secret |
| TLS | **Non fourni** : utiliser un reverse proxy HTTPS devant le serveur, ou rester sur loopback |

### Recommandations de déploiement

- **Ne pas exposer** les serveurs sur Internet. Le cas normal est un client IA
  local sur la même machine, via `127.0.0.1`.
- Si `MCP_HTTP_HOST` n'est pas loopback, **définir `MCP_HTTP_TOKEN`** avec une
  valeur forte et un secret manager ; le serveur journalise un avertissement
  sinon.
- Pour un accès distant, placer un reverse proxy TLS (nginx, Caddy, Traefik)
  devant le serveur, avec authentification et limitation de débit. Le serveur
  lui-même reste en HTTP sur loopback.
- Ne pas se reposer sur `Origin` comme seule authentification : c'est une
  protection anti-CSRF/DNS rebinding, pas un mécanisme d'identité.
- Le jeton circule en clair si le transport n'est pas TLS ; ne l'utiliser que
  sur loopback ou derrière un proxy TLS.
- Un seul client à la fois est traité par processus : une requête lente peut
  retarder les autres. Ne pas exposer un serveur unique à plusieurs
  utilisateurs sans proxy et limite de concurrence.

## Secrets et variables d'environnement

| Variable | Sensibilité | Recommandation |
|---|---|---|
| `MCP_HTTP_TOKEN` | Jeton d'accès HTTP | Valeur forte, rotation, jamais commitée |
| `MCP_ROOT_SECRET` | Mot de passe | Valeur forte, non réutilisée |
| `MCP_GITHUB_TOKEN` | Token PAT | Scope minimal (lecture seule si possible), rotation régulière |
| `MCP_CONTEXT7_API_KEY` | Clé API | Préfixe `ctx7sk`, rotation si fuite |
| `MCP_DB_POSTGRES_DSN` | Peut contenir un mot de passe | Préférer un utilisateur dédié en lecture seule |

Règles générales :

- Les serveurs ne renvoient **jamais** un secret dans une réponse MCP ; les
  logs vont sur **stderr** (jamais sur stdout).
- Ne lancez les serveurs qu'en local ou derrière un proxy authentifié.
- Ne connectez `fileMCP` qu'à un répertoire dont la perte de contenu serait
  acceptable (outils destructeurs : `write_file`, `delete_file`, `move_file`,
  `change_root`).
- `dbMCP` en écriture (`MCP_DB_ALLOW_WRITE=1`) doit pointer une base de test
  ou un utilisateur SQL aux droits limités.

## Sécurité du code

Voir [CONTRIBUTING.md](CONTRIBUTING.md). Les cas de sécurité sont couverts par
les tests : traversées de chemins et symlinks/junctions (fileMCP), injection
SQL (memory/db), injection shell (git), garde `confirm` et gestion d'erreurs
(github), anti-SSRF avec résolution DNS et plafond de réponse (fetch), refus
d'écriture SQL (db), `Origin`/jeton/taille de corps et SSE optionnel sécurisé
(transport HTTP).
