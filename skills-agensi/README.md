# Skills Agensi — brouillons pour MCPserver-HTTPSuite

Brouillons non suivis par git (à zipper et soumettre via le Creator
Dashboard Agensi). Rappel du courrier de Samuel :

- Agensi **n'héberge pas** les serveurs MCP : on publie un *skill* qui
  apprend aux agents **quand et comment** utiliser chaque serveur.
- Le skill = **ZIP** contenant un `SKILL.md` + fichiers texte d'appui
  (`references/…`). **Aucun exécutable** : les serveurs restent sur GitHub.
- Le serveur est nommé dans le champ **« Required tools & software »**
  (section Permissions du formulaire, **une ligne par serveur**).
- **2 SKILL.md ou plus = skill pack** — adapté à une suite entière.

## Exemple livré : `filemcp-server/`

```
filemcp-server/
├── SKILL.md                  # frontmatter (name = nom du dossier) + instructions
└── references/
    ├── setup.md              # BOOTSTRAP : /health -> release binaire -> checksum -> lancement -> config client
    ├── tools.md              # les 11 outils, arguments, exemples
    └── protocol.md           # transport JSON-RPC/HTTP, erreurs, config client
```

### ⚠️ Prérequis côté dépôt avant de soumettre

L'agent ne peut pas embarquer l'exécutable (règle Agensi) : il le
**télécharge depuis GitHub** en suivant `references/setup.md`. Cela exige
une **release publique avec binaires** (item « Publier une release v2.0.0 »
de la roadmap, encore ⏳) portant exactement ces noms d'assets :

```
fileMCP-windows-x64.exe
fileMCP-linux-x64
fileMCP-macos-arm64        (+ fileMCP-macos-x64 si validation Intel)
SHA256SUMS.txt
```

Sans release, l'agent n'a que la voie « compiler avec PureBasic sous
licence » — rédhibitoire pour un acheteur de skill. Les binaires étant
100 % natifs (~450 Ko, zéro dépendance), c'est un attaching trivial après
`build`. (Mêmes noms à décliner pour les 7 autres serveurs du pack.)

Le corps du SKILL.md suit la divulgation progressive de la spec
(< 500 lignes, détails déportés dans `references/`). Le point clé enseigné :
le **workflow `confirm=true`** d'`exec` — premier appel volontairement refusé,
montrer la commande à l'humain, relancer identique avec `confirm: true`.

## Zipper et soumettre

```bash
cd skills-agensi
# le ZIP doit contenir le dossier (name = nom du dossier parent)
python -c "import shutil; shutil.make_archive('filemcp-server', 'zip', '.', 'filemcp-server')"
```

Formulaire de soumission (Creator Dashboard → Submit a Skill) :

- **Skill file** : `filemcp-server.zip`
- **Required tools & software** (Permissions, une par ligne) :

```
fileMCP server — github.com/mickael-cala/MCPserver-HTTPSuite (build or release binary, port 8101)
MCP client with Streamable HTTP support (type http / httpUrl)
```

- Revue : 24–48 h, scan de sécurité avant publication.

## Plan du pack complet (8 serveurs = 8 SKILL.md)

| Dossier du skill | Serveur / port | Angle du SKILL.md |
|---|---|---|
| `filemcp-server` | fileMCP · 8101 | fichiers confinés + `exec` confirmé *(fait)* |
| `fetch-web-server` | MCP-Fetch-PB · 8102 | HTML→Markdown, anti-SSRF, plafond 2 Mo |
| `sequential-thinking-server` | MCP-SequentialThinking-PB · 8103 | chaînes de raisonnement numérotées |
| `memory-graph-server` | memoryMCP · 8104 | graphe entités/relations SQLite persistant |
| `db-explorer-server` | dbMCP · 8105 | SQL lecture seule, écriture derrière `MCP_DB_ALLOW_WRITE=1` |
| `context7-docs-server` | context7MCP · 8106 | doc de bibliothèques via Context7 |
| `git-explorer-server` | gitMCP · 8107 | exploration de dépôts git locaux (anti-injection) |
| `github-api-server` | githubMCP · 8108 | API GitHub, écritures derrière `confirm=true` |

Un pack « MCPserver-HTTPSuite complet » peut aussi embarquer un SKILL.md
transverse (choisir le bon serveur, boucle `initialize` → `tools/list` →
`tools/call`, en-têtes/tokens) en plus des 8 unitaires.

## Vérifier le format

```bash
npx @agentskills/skills-ref validate filemcp-server   # ou : skills-ref validate
```

Contrôles principaux : `name` ≤ 64 car., minuscules/tirets, **égal au nom du
dossier** ; `description` ≤ 1024 car. (le « quoi » + le « quand ») ; corps
Markdown libre.
