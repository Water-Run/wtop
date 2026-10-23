# wtop

[English](README.md) · [中文](README-zh.md) · [Français](README-fr.md) · [Русский](README-ru.md)

**WaterRun's top** est un moniteur système pour le terminal qui veut
tourner partout : sur Linux, macOS et Windows récents, mais aussi sur les
vieilles machines et les vieilles consoles que les outils modernes ont
laissées de côté.

Processeur, mémoire, disques, réseau, processus, GPU et le reste tiennent
sur un seul écran qui s'adapte à la fenêtre. wtop s'adapte aussi à ce que
le terminal sait réellement faire, d'un terminal truecolor avec souris
jusqu'à une simple fenêtre `cmd.exe` sans couleur.

```bash
wtop                # moniteur interactif
wtop --snapshot     # un instantané JSON, pour les scripts
wtop --stream --count 60 > samples.jsonl  # 60 instantanés JSON
wtop --record --count 60 > samples.wtop  # enregistrer les mesures complètes
wtop --replay samples.wtop              # les consulter hors ligne
wtop --report       # résumé matériel Markdown en anglais
wtop --memory-bandwidth  # bande passante mémoire en JSON, à la demande (Linux)
wtop --diagnose     # ce que wtop peut lire sur cette machine
```

Les enregistrements conservent les heures de mesure d’origine. Pendant la relecture, Espace lance ou suspend, Alt-Gauche/Droite avance d’une mesure, Alt-Début/Fin rejoint la première ou la dernière, et `f` change la vitesse. Les inspections en direct et les actions sur les processus sont désactivées.

## Systèmes pris en charge

| Système | État |
|---|---|
| Linux (x86_64) | Version 0.1.0 publiée, installable avec LuaRocks |
| Windows, version 32 bits | En développement. Testé sur Windows Server 2008 et un Windows actuel ; compilé pour XP |
| macOS (Apple silicon, Intel) | En développement. Fonctionne sur macOS 26 (Apple silicon) |

La version Windows est un seul paquet 32 bits qui vise tout, de XP à
Windows 11. Elle surveille Windows lui-même, pas une couche Linux par-dessus.
XP est une cible de compilation, mais n'a pas encore été testé sur une
vraie machine XP.

> [!NOTE]
> Pour l'instant, les versions Windows et macOS se compilent depuis les
> sources. La version 0.1.0 et le paquet LuaRocks sont réservés à Linux.

## Pensé pour le vieux matériel

- **Consoles simples.** wtop vérifie ce que le terminal prend en charge
  avant d'utiliser couleurs, souris, Unicode ou écran alternatif. Sur une
  console sans séquences ANSI, comme `cmd.exe` sur les anciens Windows, il
  dessine via l'API console de Windows : pas de codes d'échappement bruts à
  l'écran.
- **Petits écrans.** La disposition se réorganise jusqu'à de très petites
  fenêtres, et un mode ASCII sans couleur, au clavier seul, reste utilisable.
- **Peu gourmand.** La collecte suit une minuterie avec des intervalles
  minimaux raisonnables, et les panneaux invisibles ne sont ni collectés ni
  dessinés.
- **Aucune dépendance.** Juste PUC Lua et un petit module C. Pas de Python,
  pas d'environnement d'exécution à installer, aucun programme externe par
  défaut.

## Ce qu'il affiche

- Dix onglets intégrés : Vue d'ensemble, Processus, Calcul, Mémoire, Stockage,
  Réseau, GPU, Charges de travail, Système et Analyses.
- Une liste de processus avec recherche, tri, navigation dans l'arbre, accès aux
  charges de travail et menu de signaux avec confirmation.
- Les versions Linux et Windows en développement listent les écrans et les caractéristiques EDID en cache dans Système. Sélectionnez un appareil et appuyez sur `Enter` pour les détails.
- Les détails affichent les déclarations CTA vidéo, audio, couleur et HDR/VRR en cache lorsqu’elles sont disponibles. Elles décrivent les capacités, pas le signal actuel.
- Les versions Linux en développement affichent le mode de sortie configuré par le noyau et sa fréquence nominale, séparément des caractéristiques en cache.
- Les versions macOS en développement affichent les écrans en ligne, les dimensions du mode actuel et la fréquence nominale dans Système.
- Les versions Linux en développement affichent les états PM PCI/USB, l’état d’alimentation PCI du noyau et les durées cumulées dans les détails des appareils.
- Sur Linux x86, les versions en développement affichent les capacités CPUID aux côtés de la topologie CPU et des caches rapportés par le noyau.
- Les versions Windows en développement peuvent utiliser Intel Sysman pour la puissance GPU, les plafonds annoncés, les fréquences et les causes de limitation.
- Les pilotes AMD Windows compatibles peuvent fournir la puissance de la puce, la température, les fréquences et la vitesse du ventilateur via ADL.
- Les versions Windows en développement affichent la température NVMe et les limites indiquées par le disque. Appuyez sur `s` pour consulter son état en lecture seule ; les données SMART ATA sont lues après sélection du disque.
- Des inspections approfondies facultatives (SMART/NVMe, bande passante
  mémoire, unités systemd, sshd) quand les outils sont présents sur la machine.
- Sous Linux, `b` ouvre le débit mémoire en direct avec les courbes de lecture et d’écriture. Espace met la mesure en pause ; fermer le panneau l’arrête. Les compteurs peuvent nécessiter des droits supplémentaires.
- Une mesure qui a échoué ou qui est incomplète est signalée comme telle
  (par exemple `denied` ou `partial`) au lieu d'apparaître vide ou à zéro.
- Dix langues d'interface, à changer en cours de route avec `L`, et cinq
  thèmes de couleurs.

## Installation

### Linux

Avec LuaRocks 3.13+ et Lua 5.5 :

```bash
git clone https://github.com/Water-Run/wtop.git
cd wtop
luarocks --lua-version=5.5 make wtop-scm-1.rockspec
wtop
```

Si LuaRocks ne trouve pas Lua 5.5, ajoutez `--lua-dir=/chemin/vers/lua`.

Vous pouvez aussi vous passer de LuaRocks et lancer wtop depuis les
sources. Cela télécharge Lua 5.5.1 dans le dépôt, vérifie son SHA-256 et
compile le module natif :

```bash
make run
```

Il faut un compilateur C, `make`, et `curl` ou `wget`.

### Windows

Compilez le paquet 32 bits sous Linux avec un compilateur croisé MinGW
(`i686-w64-mingw32-gcc`) :

```bash
./tools/build_windows_x86.sh
```

Copiez `dist/windows-x86` sur la machine Windows et lancez `wtop.cmd`
depuis `cmd.exe` ou PowerShell. Dans une session Cygwin/OpenSSH, utilisez
plutôt `wtop.sh`.

### macOS

```bash
make run
```

Le résultat se trouve dans `dist/macos/wtop`. Il vise macOS 11 sur Apple
silicon et 10.13 sur Intel.

`make test-bundles` construit et vérifie les paquets en dossier et en fichier
unique dans `dist/macos-bundle/`.

## Utilisation

| Touche | Action |
|---|---|
| `1`–`9`, `0`, `Tab` | Changer d'onglet et de focus |
| `e`, puis `b` | Afficher, masquer, réordonner, créer ou copier des pages |
| `e`, puis `a` | Ajouter un widget à la page active |
| `j`/`k`, `Entrée` dans les tableaux du matériel | Choisir un appareil et ouvrir ses détails |
| `F` dans les détails d’un processus | Afficher les descripteurs ouverts et leurs détails sous Linux |
| `d` / `D` | Inspecter les unités systemd / sshd sous Linux |
| `l` dans les détails d’une unité | Lire les messages récents du journal sous Linux |
| `u` | Examiner les sessions de connexion sous Linux |
| `s` dans le journal ou les détails de sshd | Afficher un résumé du journal sous Linux |
| `f` | Changer la fréquence de rafraîchissement |
| `p` dans Vue d’ensemble, Calcul ou GPU | Puissance, limites, pourcentages, barres, statistiques de session et causes de limitation |
| `x` dans GPU | Liaison PCIe et trafic échantillonné, si le pilote les fournit |
| `!` | Alertes actuelles, indicateurs des capteurs et détails NVMe |
| `B` | Basculer entre graphiques en blocs et en braille |
| `z` / `Z` | Afficher plus / moins de temps dans les graphiques |
| `L` | Changer de langue |
| `?` ou `F1` | Toutes les touches |
| `q` ou `Ctrl+C` | Quitter |

<details>
<summary><b>Options de la ligne de commande</b></summary>

| Option | |
|---|---|
| `--snapshot` | Affiche un instantané JSON puis quitte |
| `--stream` | Émet des instantanés JSON ligne par ligne jusqu'à l'interruption |
| `--record` | Écrit un enregistrement sur la sortie standard redirigée |
| `--replay FILE` | Relit un enregistrement hors ligne ; accepte aussi `--snapshot`, `--agent` et `--report` |
| `--replay-frame N` | Avec `--replay`, commence à la mesure N |
| `--record-limit-mib N` | Limite de taille, 256 MiB par défaut |
| `--count N` | Avec `--stream` ou `--record`, s’arrête après N mesures |
| `--report` | Affiche un résumé matériel Markdown en anglais |
| `--memory-bandwidth` | Mesure une fois la bande passante mémoire en JSON (Linux ; accès à perf requis) |
| `--memory-pmu NAME` | Avec `--memory-bandwidth`, choisit un PMU ou les liste avec `list` |
| `--unmask-remote-addresses` | Avec `--snapshot`, `--stream` ou `--record` : conserve les adresses de socket distantes complètes |
| `--agent` | JSON compact pour les scripts et les agents LLM |
| `--diagnose` | Indique quelles sources de données fonctionnent ici |
| `--lang LOCALE` | Langue de l'interface, par ex. `fr-FR`, `zh-CN`, `ru-RU` |
| `--theme NOM` | `lua-blue`, `water-dark`, `water-light`, `high-contrast`, `colorblind` |
| `--interval MS` | Intervalle d'échantillonnage, de 100 à 10000 (1000 par défaut) |
| `--no-color` | Pas de couleurs |
| `--safe-mode` | N'exécute aucun programme auxiliaire facultatif |
| `--sudo` | Relance via `sudo` (Linux) |

</details>

Les réglages peuvent aussi aller dans `~/.config/wtop/config.yml` ; voir
[config.example.yml](config.example.yml).

### Accès root

La surveillance courante fonctionne en utilisateur normal. Certains
détails, comme les connexions des processus d'autres utilisateurs ou les
données SMART, demandent les droits root : lancez `sudo wtop` ou
`wtop --sudo`. Une session root ne lit ni n'écrit votre configuration ou
votre disposition personnelles.

Certaines requêtes de disque Windows nécessitent les droits administrateur.

## Développement

| Commande | |
|---|---|
| `make run` | Compiler et lancer |
| `make test-fast` | Tests rapides |
| `make test` | Tests unitaires, de fixtures et de terminal |
| `make test-all` | Tout, y compris LuaRocks et les paquets |

Les notes de conception (en anglais) sont dans [docs/](docs/) :
[architecture](docs/ARCHITECTURE.md), [multiplateforme](docs/CROSS_PLATFORM.md),
[interface](docs/UI.md), [surveillance](docs/MONITORING.md),
[i18n](docs/I18N.md), [empaquetage](docs/PACKAGING.md) et le
[JSON agent](docs/AGENT.md).

## Licence

[EUPL-1.2](LICENSE).
