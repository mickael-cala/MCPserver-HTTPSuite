# Audit de sécurité — MCPserver-HTTPSuite

> Audit « parano » réalisé le 2026-11-12 sur la version post-2.0.0 (outil
> `exec` inclus). Méthode : lecture ligne à ligne du transport
> (`http_server.pbi`, `jsonrpc.pbi`) et des 8 serveurs, avec preuves par
> numéros de ligne ; les comportements d'exécution des bibliothèques sous-
> jacentes (PQexec multi-statements, suivi des redirections WinHTTP) sont
> ceux documentés par leurs éditeurs et n'ont pas été exécutés ici.
>
> **Périmètre de confiance** : serveur MCP écoutant sur loopback, un seul
> client IA local. Toute exposition au-delà (LAN, multi-utilisateur,
> navigateur) change la menace : voir les constats critiques.

## Verdict

| Axe | Usage local loopback (contrat affiché) | Exposition réseau / multi-utilisateur |
|---|---|---|
| Dev | ✅ Production : tests (204 unitaires, 150 intégration, 21 robustesse), bornes systématiques, docs synchronisées | 🟠 Mono-thread bloque `/health`, pas de CI ni release binaires |
| Cyber | ✅ fileMCP, memory, git, sequential · 🟠 fetch et dbMCP à durcir | 🔴 Non — 3 failles critiques (corrigées, voir Statut) |
| UX agent | ✅ Catalogue propre, erreurs HTTP sémantiques, troncatures informatives | 🟠 Sorties en prose non structurée, `isError` heuristique |

Le dépôt tient sa promesse documentée (« client IA local sur la même
machine », SECURITY.md). Les constats ci-dessous sont classés selon ce
contrat : une faille « critique » suppose que quelqu'un d'autre que
l'opérateur peut joindre le serveur ou influencer ce qu'il va chercher.

## Constats critiques

### C1 — Fetch : redirections suivies sans re-validation (SSRF)

`ValidateFetchUrl` (schéma, hôte, DNS, IP privées) ne s'applique qu'à
l'URL initiale, avant la requête (`MCP-Fetch-PB.pb:194-215`). Aucun appel à
`WinHttpSetOption` pour désactiver les redirections (grep négatif) : sous
Windows, WinHTTP suit 301/302 avec sa politique par défaut — vers n'importe
quel hôte, privé compris. Sur le chemin curl (Linux), aucune directive
`location` n'est écrite dans la config (`http.pbi`) : curl ne suit pas les
redirections → **comportement divergent entre OS**, trou sous Windows.

Scénario : `fetch http://attaquant.example/article` (validé ✓) → 302 vers
`http://169.254.169.254/latest/meta-data/iam/security-credentials/` → la
réponse cloud est retournée en Markdown. Le durcissement statique Phase 8
(excellent : liste IPv4/IPv6 exhaustive, octal refusé, décimal fail-closed,
`userinfo@` neutralisé) est contourné en un saut.

**Correction appliquée** : redirections automatiques désactivées côté
WinHTTP (`WINHTTP_OPTION_DISABLE_FEATURE`) ; le serveur fetch suit les
301/302/303/307/308 **manuellement** (max 5 sauts) en re-passant chaque
`Location` par `ValidateFetchUrl` (résolution DNS incluse) ; en-têtes de
réponse capturés sur les deux transports (`WinHttpQueryHeaders
RAW_HEADERS_CRLF`, `curl --dump-header`) ; `Location` relatives résolues
(`//hôte/chemin`, `/chemin`), formes non résolables refusées (fail-closed) ;
ports restreints à 80 (http) et 443 (https) ; URL contenant des caractères
de contrôle ou dépassant 2 048 caractères refusées.

### C2 — dbMCP : la « lecture seule » est contournable

`IsReadOnlyQuery` ne vérifie que le premier mot et ne cherche jamais `;`
(`db_core.pbi:80-85`) : `SELECT 1; DROP TABLE users` passe la whitelist.
Sur PostgreSQL (PQexec exécute les stacked queries), le DROP part réellement ;
sur SQLite, `prepare_v2` ne compile que la première instruction (mitigation
de fortune). De plus `EXPLAIN` est whitelisté (`:83`) alors que
`EXPLAIN ANALYZE DELETE FROM t` **exécute** le DML sur PostgreSQL.

Les commentaires de tête sont bien neutralisés avant la whitelist
(`:65-77`, testé) — le garde était bon sur ce point, ce qui le rendait
trompeur pour le reste.

**Correction appliquée** (défense en profondeur) :
1. tout `;` dans la requête → refus (fail-closed) ;
2. `EXPLAIN` retiré de la whitelist ;
3. lecture seule appliquée **par le moteur** : SQLite `PRAGMA query_only=1`
   à l'ouverture, PostgreSQL `SET default_transaction_read_only = on`,
   dans les deux cas uniquement quand `MCP_DB_ALLOW_WRITE` n'est pas `1`.
   L'application continue d'interdire `SET`/`PRAGMA`/`BEGIN` (hors
   whitelist) et les multi-statements (`;`) : même un bug futur du garde
   applicatif ne peut plus écrire.

### C3 — Client HTTP curl : secrets en clair dans /tmp + injection de config

Chemin Linux de `mcp_common/http.pbi` : chaque requête écrit les en-têtes
(dont `Authorization: Bearer ghp_…`) dans
`/tmp/mcp_http_<Date>_<Random6>.cfg`, lisible par les autres utilisateurs
locaux pendant la requête et **persistant en cas de crash** (suppression
seulement en fin normale). De plus `CurlEsc` n'échappe que `\` et `"` — pas
LF/CR : un `\n` dans le chemin d'une URL de `fetch` (jamais nettoyé, la
validation ne porte que sur schéma+hôte) écrit des directives curl
arbitraires dans le fichier de config (contournement de `max-time`, options
ajoutées).

**Correction appliquée** : `CurlEsc` neutralise LF/CR ; `ValidateFetchUrl`
refuse les caractères de contrôle (recouvrement) ; sur Linux/macOS le
fichier de config est créé avec un `umask 077` temporaire (permissions
0600, restauration immédiate) ; le nom du fichier temporaire vérifie
l'absence préalable (boucle de régénération) ; Windows : `%TEMP%`
utilisateur est déjà privé (aucun changement).

## Constats importants

| # | Constat | Où | Statut |
|---|---|---|---|
| I1 | **DNS rebinding du serveur lui-même** : une requête avec un `Host` pirate (`evil.com:8101` résolu vers 127.0.0.1) était acceptée faute de vérification du header `Host` — le contrôle `Origin` n'attrape pas les requêtes sans `Origin`. | `http_server.pbi:334-348` | **Corrigé** : `Host` exigé dans la liste autorisée (loopback avec/sans port, hôte d'écoute, `MCP_HTTP_ALLOWED_HOSTS`) sur `GET/POST /mcp` → `403` sinon ; `Host` absent toléré (clients HTTP/1.0 — le vecteur rebinding exige un Host contrôlé par l'attaquant) |
| I2 | **`%VAR%` non bloqué par `GitSafeParam`** : sous Windows, `cmd.exe` développe les variables **même entre guillemets** ; un `%APPDATA%` dans un nom de branche est expansé (et peut transporter `&`). `^` et `!` restent autorisés : inertes entre guillemets (hors delayed expansion, désactivée en `cmd /c`). | `git_core.pbi:26-51` | **Corrigé** : `%` ajouté à la blacklist |
| I3 | **DNS rebinding de fetch** (TOCTOU) : `nslookup` valide, puis le transport re-résout à la connexion — deux résolutions, deux vérités. | `MCP-Fetch-PB.pb` | **Corrigé** : IP validée épinglée par saut (curl `connect-to`, DNS court-circuité) ; WinHTTP vérifie l'IP réellement connectée après réponse (`WINHTTP_OPTION_CONNECTION_INFO`), réponse jetée si privée |
| I4 | **memory** : `%`/`_` non échappés dans le LIKE de `search_nodes` + préfixe `%` → index inutilisable, scan complet répétable = DoS CPU du mono-thread. | `memory_core.pbi` | **Corrigé** : jokers échappés (`ESCAPE '\'`), requête bornée à 256 caractères |
| I5 | Aucune limite de taille/cardinalité des entrées métier (memory) ; github/context7 lisent des réponses non plafonnées. | `memory_core.pbi`, `http.pbi` | **Corrigé** : entités ≤ 100/appel, noms ≤ 256, observations ≤ 128 Kio (les 100 Ko légitimes de T1.18 passent) ; réponses github 4 Mio / context7 8 Mio via `HttpGetLimited`/`HttpPostLimited` |
| I6 | `MCP_CONTEXT7_API_BASE` / `MCP_GITHUB_API_BASE` acceptés sans validation : la clé Bearer part vers la destination configurée (trust de configuration, non atteignable via les outils MCP). | `context7MCP.pb` | **Corrigé** : `HttpCheckApiBase` — http/https uniquement (`file://` → refus de démarrage), avertissement si HTTP hors loopback |
| I7 | Mono-thread strict : un outil lent (fetch 15 s, exec 60 s) bloque `/health` et les keep-alives SSE. | `http_server.pbi:705-735` | Ouvert (choix documenté) |
| I8 | Pas d'isolation par requête : une erreur runtime PureBasic tue le processus. | — | **Mitigué** : `tools/watchdog_all.bat/.sh` relance les serveurs morts toutes les 10 s ; l'isolation par sous-processus reste ouverte |
| I9 | Pas de release binaires, pas de CI, version bumpée à la main dans 8 fichiers. | — | Ouvert (bloque aussi la soumission Agensi) |
| I10 | `DetectIsError` heuristique sur la prose française : un résultat réussi contenant « introuvable » bascule `isError: true`. | `jsonrpc.pbi` | **Corrigé** : règles « contient » supprimées (préfixe seul), 13 messages d'échec migrés vers le préfixe `Erreur :` |
| I11 | Sorties en prose non structurée (parsing par l'agent) ; `structuredContent` (spec MCP) inutilisé. | — | Ouvert |
| I12 | Outil inconnu → `result.isError` au lieu d'une erreur JSON-RPC `-32602`. | `jsonrpc.pbi` | **Corrigé** : index des outils construit depuis le catalogue, outil inconnu → `-32602` (spécification MCP) ; reste : `id` numériques via Double (limite de la bibliothèque JSON PureBasic, précision > 2⁵³) |

## Parano / mineurs (connus et assumés)

- `exec` (fileMCP) : `KillProgram` ne tue pas les petits-fils du shell ;
  nom de script temporaire prévisible ; sortie `cmd.exe` en OEM relue en
  UTF-8 (accents dégradés). Documenté dans ERRATA.md.
- Slowloris doux : timeout **d'inactivité** remis à zéro par chaque octet ;
  64 connexions qui gouttent = `503` pour tous (cap `#HTTP_MAX_CONNS`).
  Bénin en loopback.
- Map globale `G_HttpHeaders` correcte uniquement grâce à l'invariant
  mono-requête — couplage invisible à documenter avant toute introduction
  de threads.
- Réflexion d'URL/commandes dans les erreurs et logs (`Left(…,120)`,
  tronqués) : un secret collé dans une commande refusée finit sur stderr.
- `HtmlToMarkdown` quadratique : 2 Mio de balises = dizaines de secondes de
  CPU mono-thread. UTF-8 décodé par blocs de 64 Kio : codepoint coupé à une
  frontière corrompu (`http.pbi`).
- Comparaison du token/secret : **corrigé** depuis (niveau 2) —
  `HttpConstCompare` à temps constant.
- `delete_file` récursif sans `confirm` (confiné sous `MCP_ROOT`) alors que
  `exec` exige `confirm` : choix cohérent, documenté.

## Ce qui est objectivement bien (preuves)

- **Anti-SSRF statique** : liste IPv4/IPv6 privées exhaustive (169.254
  metadata, CGNAT, NAT64, IPv4-mappé), IP octales refusées par règle des
  zéros de tête, décimal → hostname → NXDOMAIN → fail-closed, `userinfo@`
  neutralisé doublement, plafond 2 Mo appliqué dans la boucle de lecture.
- **Injection SQL memory** : `SqlQuote` dédié aux 13 points d'injection,
  test « Robert'); DROP TABLE… » présent, zéro `ORDER BY` dynamique,
  `PRAGMA foreign_keys = ON`.
- **GitHub/Context7** : token/clé uniquement en header `Authorization`,
  jamais en URL, jamais loggé (longueur seulement), `GhSafeSegment` +
  `%`-encodage en double couche, `confirm=true` sur exactement les 2 POST,
  pagination clampée à 100.
- **Transport** : `Transfer-Encoding: chunked` refusé (`501`) → smuggling
  neutralisé par design mono-parseur + `Connection: close` ; Content-Type
  strict (`415`) ; `Origin` en égalité exacte ; drain borné avant `413` ;
  timeout d'inactivité ; codes 408/411/431/503 sémantiques.
- **Culture** : bornes partout, fail-closed par principe, documentation
  synchronisée par checklist avant commit, 204 unitaires + 150 intégration
  + 21 robustesse/perf avec mock et rapports.

## Statut des corrections (semaine 1 de durcissement)

| Constat | Correction | Tests |
|---|---|---|
| C1 | Redirects WinHTTP désactivés + suivi manuel re-validé (≤ 5 sauts) + ports 80/443 + refus caractères de contrôle | Intégration : port non standard refusé, URL avec LF refusée |
| C2 | `;` refusé, `EXPLAIN` retiré, `PRAGMA query_only` / `default_transaction_read_only` au niveau moteur | Intégration : `SELECT 1; DROP TABLE` refusé |
| C3 | `CurlEsc` LF/CR + `umask 077` (fichier 0600) + vérif d'existence du fichier temp | Vérifié par revue + audit (comportement Linux) |
| I1 | Vérification du header `Host` sur `/mcp` + `MCP_HTTP_ALLOWED_HOSTS` | Intégration : Host pirate → 403, Host absent → accepté |
| I2 | `%` bloqué dans `GitSafeParam` | Intégration : ref paramètre avec `%` refusé |

## Statut des corrections (semaine 2 de durcissement)

| Constat | Correction | Tests |
|---|---|---|
| I3 | IP validée épinglée (curl `connect-to`) + vérification de l'IP réellement connectée (WinHTTP, réponse jetée si privée) | Par construction + revue (le rebinding mid-flight n'est pas simulable hors ligne) |
| I4 | Jokers LIKE échappés + `ESCAPE '\'` + requête ≤ 256 car. | Intégration : `a_b` ne matche plus `aXb`, `%` ne matche plus rien |
| I5 | Bornes d'entrées memory (≤ 100 items, noms 256, obs 128 Kio) + réponses plafonnées github 4 Mio / context7 8 Mio | Intégration : nom trop long refusé, observation trop longue refusée |
| I6 | `HttpCheckApiBase` : http/https uniquement, refus de démarrage sinon | Intégration : `API_BASE file://` → démarrage refusé (github + context7) |
| Niveau 2 (bonus) | Comparaison à temps constant (`HttpConstCompare` : jeton Bearer + `change_root`) ; `MCP_HTTP_AUTH_LOCKOUT` (429 après 20 401/60 s) ; `MCP_HTTP_RATE_LIMIT` (opt-in) | Intégration : 3 échecs d'auth → 429 ; rate limit → 429 après le plafond |
| Niveau 3 (I8-lite) | `tools/watchdog_all.bat/.sh` : relance automatique des serveurs morts | Manuel (scripts de supervision) |

**Semaine 3 (protocole, I10-I12)** — validée Windows ET WSL2 (204 unitaires,
21 robustesse, 150 intégration) :

| Constat | Correction | Tests |
|---|---|---|
| I12 | Outil inconnu → erreur JSON-RPC `-32602` (index construit depuis le catalogue, sans modification des serveurs) | Unité + intégration : outil fantôme → `-32602`, outil connu inchangé |
| I10 | `DetectIsError` préfixe seul (`Erreur`/`ERREUR`/`Impossible`/`Echec`), règles « contient » supprimées ; 13 messages d'échec migrés | Unité : « Fichier introuvable : x » seul n'est plus une erreur ; intégration complète verte (aucun faux négatif) |

Reste ouvert : I7 (concurrence — décision de design : threads interdits sans
revoir le couplage `G_HttpHeaders`, file d'attente discutable sans pompage
d'événements), I11 (`structuredContent` — conception de schémas par outil),
mineurs (petits-fils de `exec`, `HtmlToMarkdown` O(n²), UTF-8 par blocs,
CI, macOS).

Reste ouvert : I7-I12 et les mineurs (cf. ROADMAP.md). Les compteurs de
tests cités dans ce document correspondent à l'état post-correction
(204 unitaires, 150 intégration, 21 robustesse/perf).
