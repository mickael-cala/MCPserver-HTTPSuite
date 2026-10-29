# Conception — limites fichier 2 Mio et serveur MCP Free Pascal

Date : 2026-10-29  
Statut : validée par Mickael avant rédaction  
Périmètre : `MCPserver-HTTPSuite`, sources PureBasic 6.4x

## 1. Objectif

1. Uniformiser la limite de lecture de fichiers à **2 Mio** (`2 * 1024 * 1024` octets).
2. Ajouter un serveur MCP dédié, **`fpcMCP`**, capable de compiler avec Free Pascal vers six cibles :
   - Windows 32 bits ;
   - Windows 64 bits ;
   - Linux 32 bits ;
   - Linux AMD64 ;
   - Linux AArch64 ;
   - macOS Apple Silicon / AArch64.
3. Fournir une base simple, synchrone, bornée, sans shell arbitraire et fortement commentée.

## 2. Décisions validées

- La limite de lecture est de **2 Mio exactement**.
- Free Pascal est implémenté dans un **nouveau serveur** `fpcMCP`, pas dans `fileMCP`.
- Le serveur `fpcMCP` est **synchrone** dans sa première version.
- Les outils de v1 sont :
  - `fpc_targets` ;
  - `fpc_version` ;
  - `fpc_compile`.
- Aucun outil n’exécute le binaire compilé.
- Aucun argument libre ne permet de changer la commande du compilateur.
- Le compilateur est résolu dans cet ordre :
  1. variable dédiée à la cible ;
  2. variable générique `MCP_FPC` ;
  3. `fpc` trouvé dans le `PATH`.
- La frontière de confiance explicite de v1 inclut le compilateur Free Pascal, sa configuration `fpc.cfg` et les outils de liaison installés.

## 3. Non-objectifs de cette version

Les éléments suivants sont volontairement exclus :

- exécution des binaires produits ;
- file de compilation asynchrone ;
- annulation de compilation après renvoi de la réponse MCP ;
- `extraFlags` libre ;
- nettoyage général des artefacts ;
- bac à sable OS, conteneur, chroot ou utilisateur système dédié ;
- support complet des encodages autres qu’UTF-8 dans `read_file` ;
- remplacement du protocole MCP ou du transport HTTP commun.

## 4. Changement limites `fileMCP`

### 4.1 Constante unique

Ajouter dans `src/fileMCP.pb` :

```purebasic
#FILE_MAX_READ_BYTES = 2 * 1024 * 1024
```

### 4.2 Règles par outil

- `read_file` :
  - lit au maximum `#FILE_MAX_READ_BYTES` ;
  - conserve un marqueur final indiquant la troncature ;
  - vérifie le nombre d’octets réellement lus par `ReadData()` avant `PeekS()`.
- `read_file_lines` :
  - refuse les fichiers strictement supérieurs à `#FILE_MAX_READ_BYTES` ;
  - conserve ses limites de plage de lignes actuelles.
- `search_files` :
  - remplace son littéral `2 * 1024 * 1024` par la même constante.
- Catalogue MCP :
  - `read_file` annonce 2 Mio ;
  - `read_file_lines` annonce 2 Mio ;
  - `search_files` annonce 2 Mio si sa description mentionne la limite.

### 4.3 Hors périmètre

- `MCP_HTTP_MAX_BODY` reste indépendant : c’est une limite de requête entrante, pas de lecture fichier.
- `write_file` n’est pas modifié par cette spécification.

## 5. Durcissement de la racine `fileMCP`

La racine initiale doit recevoir le même niveau de contrôle qu’une racine modifiée par `change_root` :

- normaliser ;
- transformer une racine relative en chemin absolu par rapport au répertoire courant du processus ;
- refuser une racine en lien symbolique ou junction ;
- journaliser le refus et quitter avec un code non nul.

Ce durcissement est intégré à l’extraction du gardien de chemins décrite ci-dessous.

## 6. Nouveau gardien de chemins

Créer `src/fs_guard.pbi`.

Responsabilités :

- séparateur natif ;
- normalisation lexicale multiplateforme ;
- slash final normalisé ;
- détection lien symbolique / junction ;
- détection d’un lien dans les composants sous une racine ;
- préparation stricte d’une racine ;
- validation d’un chemin demandé relativement à une racine autorisée.

Le gardien ne doit contenir aucune lecture ou écriture de fichier métier. Il fournit uniquement des primitives pures de validation.

`fileMCP.pb` réutilise ces primitives au lieu de garder sa propre implémentation. Les noms existants peuvent être conservés comme wrappers courts si cela réduit le risque de régression. Aucun comportement correct existant ne doit changer, hormis le durcissement de la racine initiale.

## 7. Architecture `fpcMCP`

### 7.1 Fichiers

Créer :

- `src/fpc_core.pbi` — métier, résolution, validation, exécution, catalogue et dispatch ;
- `src/fpcMCP.pb` — point d’entrée, configuration et boucle HTTP ;
- `src/fs_guard.pbi` — gardien commun de chemins.

Modifier :

- `src/fileMCP.pb` — limite 2 Mio, racine initiale, réutilisation du gardien ;
- scripts de compilation du dépôt, si l’autorisation de toucher au répertoire parent est donnée ; sinon fournir un patch prêt à appliquer depuis `src`.

Le port par défaut proposé est **8108**, configurable par `MCP_HTTP_PORT` comme tous les serveurs de la suite.

### 7.2 Configuration

Variables :

- `MCP_FPC_ROOT` : racine des sources et artefacts ; défaut = répertoire courant du serveur.
- `MCP_FPC` : compilateur général explicite.
- Variables dédiées :
  - `MCP_FPC_WIN32` ;
  - `MCP_FPC_WIN64` ;
  - `MCP_FPC_LINUX32` ;
  - `MCP_FPC_LINUX64` ;
  - `MCP_FPC_LINUX_AARCH64` ;
  - `MCP_FPC_MACOS_AARCH64`.
- `MCP_FPC_TIMEOUT_MS` : timeout de compilation ; défaut 60 000 ms ; borné entre 1 000 et 300 000 ms.

La détection en repli se limite au nom `fpc` dans le `PATH`. Le serveur ne doit pas parcourir le disque à la recherche d’un exécutable.

## 8. Outils MCP de v1

### 8.1 `fpc_targets`

But : montrer les six cibles connues et leur résolution actuelle.

Sortie texte :

- identifiant API ;
- CPU Free Pascal ;
- OS Free Pascal ;
- options `-P` et `-T` ;
- exécutable résolu ;
- origine : variable dédiée, `MCP_FPC` ou `PATH`.

### 8.2 `fpc_version`

Paramètre :

- `target` : optionnel ; absent = résolution générale `MCP_FPC` puis `fpc` dans le `PATH`, sans imposer une cible.

Comportement :

- lance le compilateur résolu avec `-iV` ;
- retourne version, cible demandée le cas échéant, chemin du compilateur et code de sortie ;
- si le compilateur est absent, retourne une erreur MCP claire.

### 8.3 `fpc_compile`

Paramètres :

- `sourcePath` — requis ;
- `target` — requis ;
- `buildMode` — `debug` ou `release` ; défaut `debug` ;
- `outputName` — optionnel ; nom de fichier simple.

Extensions de source autorisées :

- `.pas` ;
- `.pp` ;
- `.lpr`.

`outputName`, lorsqu’il est fourni, doit :

- contenir au plus 128 caractères ;
- n’utiliser que lettres, chiffres, point, tiret et souligné ;
- ne pas commencer par un point ;
- ne pas contenir `..`, `/`, `\`, `:` ni espace ;
- être transmis sous la forme `-o<nom>` dans le fichier de réponse.

Table des cibles :

| Identifiant | Options FPC |
|---|---|
| `win32` | `-Pi386 -Twin32` |
| `win64` | `-Px86_64 -Twin64` |
| `linux32` | `-Pi386 -Tlinux` |
| `linux64` | `-Px86_64 -Tlinux` |
| `linux-aarch64` | `-Paarch64 -Tlinux` |
| `macos-aarch64` | `-Paarch64 -Tdarwin` |

Modes :

- `debug` : `-g -gl` ;
- `release` : `-O2 -Xs`.

Sorties imposées sous la racine :

- exécutables : `build/<target>/` ;
- unités : `build/<target>/units/`.

Si `outputName` est absent, le nom de sortie est laissé à Free Pascal. Le serveur liste ensuite les artefacts présents sous le répertoire de sortie, sans remonter au-delà de la racine.

## 9. Exécution du compilateur

### 9.1 Mécanisme

Utiliser directement :

```purebasic
RunProgram(Compiler, "@<fichier-reponse>", WorkDir,
           #PB_Program_Open | #PB_Program_Read |
           #PB_Program_Error | #PB_Program_Hide)
```

Le fichier de réponse Free Pascal est créé par le serveur dans un répertoire temporaire dédié, puis supprimé. Cela évite :

- l’appel à `cmd.exe`, `/bin/sh` ou tout autre shell ;
- le collage de drapeaux libres dans une ligne de commande ;
- les problèmes de quotation multiplateforme autant que possible.

### 9.2 Capture

- stdout lu seulement quand `AvailableProgramOutput()` indique une disponibilité ;
- stderr lu avec `ReadProgramError()`, qui ne doit pas bloquer lorsqu’il est vide ;
- stdout et stderr conservés séparément dans le résultat ;
- chaque flux borné à 64 Kio par défaut, avec marqueur de tronquage.

### 9.3 Fin de processus

- attendre jusqu’au timeout ;
- en cas de dépassement : `KillProgram()`, code d’erreur dédié, mention explicite dans le résultat ;
- ensuite `WaitProgram()`, `ProgramExitCode()` et `CloseProgram()` ;
- un processus ouvert avec `#PB_Program_Open` est toujours refermé.

## 10. Validation et erreurs

Le serveur doit refuser sans lancer FPC :

- source absente ou hors racine ;
- source pointant par lien ou junction sous la racine ;
- extension non autorisée ;
- cible inconnue ;
- mode inconnu ;
- nom de sortie contenant un chemin, un séparateur ou des caractères invalides ;
- compilateur non configuré ou non exécutable ;
- répertoires de sortie impossibles à créer.

Format humain recommandé :

```text
Statut    : ECHEC
Cible     : linux64
Source    : <chemin validé>
Code      : <code>
Durée     : <ms>

Erreurs
-------

<diagnostics essentiels>

Sortie compilateur
------------------

<stdout éventuellement tronqué>

Erreurs compilateur
-------------------

<stderr éventuellement tronqué>

Artefacts
---------

<chemin, taille, horodatage>
```

## 11. Sécurité — invariants non négociables

1. Jamais de commande libre.
2. Jamais de shell pour assembler une commande utilisateur.
3. Jamais d’exécutable résolu depuis un chemin fourni par le projet.
4. Jamais d’exécution du binaire produit.
5. Cible prise dans une table interne.
6. Chemins validés avec `fs_guard.pbi`.
7. Timeout et tailles de sortie bornés.
8. Aucun secret dans les journaux ni dans les réponses.
9. Le serveur doit rester simple à auditer : une procédure = une responsabilité.
10. Les commentaires expliquent intention, contrat et paranoïa, pas seulement la syntaxe.

## 12. Commentaires pédagogiques

Les en-têtes de procédures critiques suivent ce modèle :

```purebasic
; -----------------------------------------------------------------------------
; INTENTION
; Ce que la procédure garantit.
;
; CONTRAT
; Entrées attendues, sortie, cas d'erreur.
;
; PARANO
; Attaque ou mauvais usage prévu, garde-fou appliqué.
; -----------------------------------------------------------------------------
```

Les zones sensibles à commenter généreusement sont :

- préparation de la racine ;
- validation du chemin source ;
- résolution du compilateur ;
- construction de la table cible ;
- création du fichier de réponse ;
- boucle de capture stdout/stderr ;
- timeout et kill ;
- choix de ne jamais exécuter le résultat.

## 13. Tests

### 13.1 Tests `fileMCP`

- fichier de 1,9 Mio lisible par `read_file` et `read_file_lines` ;
- fichier exactement de 2 Mio lisible par `read_file` et `read_file_lines` ;
- fichier de 2 Mio + 1 octet refusé par `read_file_lines` et tronqué par `read_file` ;
- `read_file` tronque proprement au-delà de 2 Mio ;
- descriptions du catalogue annoncent 2 Mio ;
- racine initiale symbolique refusée ;
- racine relative transformée en chemin absolu ;
- régressions de traversal et de lien symbolique toujours bloquées.

### 13.2 Tests unitaires `fpc_core`

- table complète des six cibles ;
- cible inconnue refusée ;
- extension inconnue refusée ;
- `outputName` avec chemin refusé ;
- source hors racine refusée ;
- source via lien refusée ;
- priorité variable dédiée > variable générique > PATH ;
- timeout du faux compilateur ;
- stdout et stderr capturés ;
- troncature à 64 Kio.

### 13.3 Tests d’intégration

Si FPC est disponible :

- `fpc_targets` retourne six cibles ;
- `fpc_version` retourne une version ;
- compilation native réussie du plus petit programme possible ;
- chemin source avec espaces ;
- erreur Pascal affichée proprement ;
- artefact produit sous `build/<target>/`.

Si FPC n’est pas disponible :

- tests d’intégration FPC marqués « skipped » ;
- les tests de validation restent obligatoires.

### 13.4 Tests de régression

- `fileMCP` conserve son catalogue et ses protections ;
- tous les serveurs existants compilent encore ;
- les scripts de compilation incluent `fpcMCP` dès que le répertoire parent est modifiable.

## 14. Critères d’acceptation

- Limite unique 2 Mio réellement appliquée et annoncée.
- Aucune limite codée en dur différente pour lecture/search.
- `fpcMCP` compile au moins la cible native disponible sur la machine de test.
- Les six cibles sont exposées, avec erreur claire si la chaîne croisée manque.
- Aucune exécution via shell utilisateur.
- Aucune exécution du binaire compilé.
- Timeout et troncatures testés.
- Commentaires suffisants pour qu’un développeur comprenne les garde-fous sans relire tout le projet.

## 15. Risques résiduels assumés

- Un `fpc.cfg` hostile ou modifié peut orienter certaines recherches ou opérations du compilateur.
- Les compilateurs et outils de liaison restent des exécutables complexes : la compilation n’est pas une preuve d’innocuité du code Pascal.
- La validation de chemin réduit fortement les erreurs, mais ne remplace pas un vrai sandbox OS.
- La compilation synchrone bloque une requête HTTP jusqu’au timeout.
- La génération réelle des six cibles dépend des cross-compilers, RTL, bibliothèques et binutils installés sur la machine hôte.
