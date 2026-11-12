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
| `fileMCP` | Système de fichiers + shell | Confinement à `MCP_ROOT`, normalisation des chemins (traversées `..` refusées), **symlinks/junctions sous la racine refusés**, `change_root` protégé par `MCP_ROOT_SECRET`, **`exec` exige `confirm=true` (validation humaine par commande ou par lot), refus journalisés**, timeout et sortie bornée |
| `memoryMCP` | Base SQLite | Échappement SQL (apostrophes doublées), FK en cascade, base locale (`MCP_MEMORY_DB`) |
| `dbMCP` | Bases SQL | **Lecture seule par défaut, à deux étages** : garde applicatif (`IsReadOnlyQuery`, `;` refusé, `EXPLAIN` exclu) **et moteur** (`PRAGMA query_only` / `default_transaction_read_only=on`, appliqués à l'ouverture) ; écritures uniquement avec `MCP_DB_ALLOW_WRITE=1` (fixé au démarrage), refus journalisés |
| `context7MCP` | API web | HTTP/HTTPS uniquement, clé API jamais loggée (WinHTTP/curl) |
| `gitMCP` | Sous-processus git | `GitSafeParam` rejette les métacaractères shell sur tous les paramètres |
| `githubMCP` | API GitHub | Écritures exigeant `confirm=true`, token jamais renvoyé ni loggé, pagination bornée, validation des segments d'URL |
| `MCP-Fetch-PB` | API web | HTTP/HTTPS uniquement (ports 80/443), IP privées/loopback/ULA/link-local refusées, **résolution DNS vérifiée** (anti-SSRF), **redirections suivies manuellement avec re-validation de chaque saut** (jamais automatiques), URL sans caractères de contrôle, **réponse plafonnée à 2 Mo** |
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
| Hôte (anti DNS rebinding) | En-tête `Host` sur `/mcp` : loopback du port courant, hôte d'écoute ou `MCP_HTTP_ALLOWED_HOSTS` exigé ; sinon `403`. Un `Host` pirate (domaine re-résolu vers 127.0.0.1) est refusé même sans `Origin` |
| Version MCP | `MCP-Protocol-Version` accepté : `2025-03-26` / `2025-06-18` ; absent → traité comme `2025-03-26` ; invalide → `400` |
| Taille du corps | 1 Mio par défaut (`MCP_HTTP_MAX_BODY`, borné 1 Kio–16 Mio) ; `413` au-delà |
| En-têtes | Limite 16 Kio ; `431` au-delà |
| Timeout | 10 s d'inactivité pour les en-têtes/corps ; `408` |
| Transfert | `Content-Length` obligatoire pour POST ; `Transfer-Encoding: chunked` refusé (`501`) |
| Connexions | 64 requêtes en cours et 64 flux SSE maximum ; `503` au-delà |
| SSE | Flux `text/event-stream` uniquement si demandé ; `Origin` et jeton vérifiés ; keep-alive 15 s ; pas de messages serveur→client |
| CORS | Aucun `Access-Control-Allow-Origin` ; les navigateurs ne peuvent pas lire les réponses |
| Débit | `MCP_HTTP_AUTH_LOCKOUT` : après N échecs d'authentification en 60 s, `/mcp` répond `429` pendant 30 s (anti brute-force du jeton, défaut 20). `MCP_HTTP_RATE_LIMIT` : plafond global de requêtes `/mcp` par 10 s (opt-in, défaut désactivé). Comparaison du jeton/secret à **temps constant** |
| Journalisation | Méthode, chemin, statut, durée et version MCP sur **stderr** ; jamais le corps, jamais un secret |
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

## Limites de sécurité connues

- **TOCTOU symlink** : un attaquant local avec un accès écriture à `MCP_ROOT`
  pourrait remplacer un composant entre la validation et l'opération. Le
  confinement bloque les liens présents au moment du contrôle, pas une course
  locale.
- **DNS rebinding** : `fetch` résout le hostname avant la connexion HTTP et
  **revalide chaque saut de redirection** ; un DNS malveillant peut
  néanmoins changer la réponse entre la validation et la connexion
  (TOCTOU). La vérification du header `Host` côté serveur (`403` sur un
  host pirate) bloque en revanche le rebinding **du serveur lui-même** par
  une page web. Fix complet côté fetch : épingle l'IP résolue.
- **Pas d'OAuth 2.1** : le jeton Bearer est une authentification simple, sans
  découverte ni rotation automatique. Pour un accès distant, utiliser un
  reverse proxy avec OAuth ou une passerelle authentifiée.
- **Pas de TLS natif** : HTTP en clair, à réserver au loopback ou à un reverse
  proxy TLS.
- **Pas de rate limiting** : une exposition réseau doit être protégée en amont.
- **Liens Markdown** : les `href` `javascript:` du HTML source peuvent
  persister dans le Markdown ; le client doit assainir le rendu.

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
- `exec` (fileMCP) exécute une **commande shell arbitraire** : chaque appel
  (commande unique ou lot) doit porter `confirm=true`, soumis à la validation
  de l'opérateur par le client MCP — le serveur journalise chaque refus. Le
  répertoire de travail est confiné sous `MCP_ROOT` mais **ne limite pas les
  effets de la commande** (`cd ..`, chemins absolus…) : ne confirmer que des
  commandes vérifiées, et exiger `MCP_HTTP_TOKEN` si le serveur est joignable
  au-delà du loopback.
- `dbMCP` en écriture (`MCP_DB_ALLOW_WRITE=1`) doit pointer une base de test
  ou un utilisateur SQL aux droits limités.

## Sécurité du code

Voir [CONTRIBUTING.md](CONTRIBUTING.md). Les cas de sécurité sont couverts par
les tests : traversées de chemins et symlinks/junctions (fileMCP), garde
`confirm` + répertoire de travail confiné + timeout de `exec` (fileMCP),
injection SQL (memory/db), injection shell (git), garde `confirm` et gestion
d'erreurs (github), anti-SSRF avec résolution DNS et plafond de réponse
(fetch), refus d'écriture SQL (db), `Origin`/jeton/taille de corps et SSE
optionnel sécurisé (transport HTTP).
