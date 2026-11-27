# GreanCast

[English](README.md) | **Français**

**Pilotez votre iPhone depuis votre Mac.** Son écran s'affiche en direct dans une fenêtre : un clic devient un toucher, un glisser devient un balayage, et vous tapez au clavier du Mac.

GreanCast est une app macOS open source pour les développeurs. C'est l'équivalent de [scrcpy](https://github.com/Genymobile/scrcpy) (Android), mais pour iPhone. Elle pilote l'iPhone via [WebDriverAgent](https://github.com/appium/appium-ios/tree/main/packages/webdriveragent), un serveur maintenu par Appium et construit sur le framework XCUITest d'Apple. Par défaut, la connexion passe par un câble USB.

> État : préversion (0.1). Testée sous macOS 27.2 avec Xcode 27, sur un iPhone 17 Pro sous iOS 27.3.

## Pourquoi GreanCast

GreanCast est développé par **[Grean](https://www.grean.fr)**, un outil de qualification de biens immobiliers et de bateaux, pour leur suivi dans le temps ou leur vente.

Nous développons et testons des apps toute la journée. Avec un iPhone sur le bureau, il faut sans cesse lâcher le clavier, prendre le téléphone, toucher l'écran, taper sur un petit clavier, puis revenir au Mac. Nous voulions l'iPhone **dans une fenêtre du Mac**, pour enchaîner un parcours au clic, saisir des données de test avec un vrai clavier, coller depuis le presse-papiers ou faire une capture, sans quitter le Mac.

Notre première idée était que le Mac se fasse passer pour un clavier et une souris Bluetooth auprès de l'iPhone. Ça ne marche pas : macOS refuse de publier le service Bluetooth HID, exactement comme iOS. La Recopie de l'iPhone d'Apple n'est pas disponible partout, et notamment pas dans l'Union européenne. Les solutions open source existantes étaient des serveurs d'automatisation ou des outils dans le navigateur, pas une simple app native. Nous avons donc construit GreanCast sur WebDriverAgent, pour notre propre usage.

L'outil est vite devenu indispensable pour coder et tester. D'autres développeurs ont sûrement le même iPhone sur le même bureau, alors nous le partageons. Retours, tickets et pull requests sont les bienvenus.

## Fonctionnalités

- Recopie de l'écran en direct (MJPEG, ~25 à 30 images/s)
- Clic → toucher, clic long → appui long, glisser → tracé au doigt, molette ou trackpad → défilement
- Saisie au clavier du Mac. Les accents, les touches mortes (^ puis e → ê), les combinaisons avec ⌥ et ⌘V (collage du presse-papiers du Mac) fonctionnent, quelle que soit la disposition du clavier de l'iPhone.
- Home, sélecteur d'apps, centre de contrôle, volume, ouverture d'une app par son identifiant (bundle ID), capture d'écran
- **USB par défaut :** ~1 ms d'aller-retour, pas besoin de Wi‑Fi, rien d'exposé sur le réseau
- Assistant de configuration : il vérifie Xcode, votre équipe de développement Apple, l'iPhone et le mode développeur. Il télécharge ensuite WebDriverAgent, le compile, le signe et le lance pour vous.
- **Garder éveillé :** tant qu'il est connecté, GreanCast empêche le verrouillage automatique de l'iPhone sans modifier ses réglages (activé par défaut, bouton ☕️ de la barre d'outils)
- Détection de l'écran verrouillé, avec un bouton pour réveiller et déverrouiller un iPhone sans code
- **Serveur MCP intégré :** un assistant IA (Claude Code, Codex, Cursor, VS Code…) peut voir l'iPhone et s'en servir — voir [Assistants IA](#assistants-ia-serveur-mcp)

## Limites (à lire en premier)

- **Latence.** Chaque action prend **~0,3 à 0,5 s** : toucher ≈ 440 ms, saisie ≈ 320 ms par envoi, Home ≈ 50 ms. Ce temps est passé dans XCTest sur l'iPhone ; la connexion n'est pas en cause. GreanCast est confortable pour le contrôle à distance, les démos et les tests, mais pas pour jouer.
- **Commencez avec l'iPhone déverrouillé.** WebDriverAgent ne sait pas taper le code. Une fois la connexion établie, *Garder éveillé* empêche le verrouillage automatique. Après 20 s sans commande, GreanCast envoie un événement de clavier physique vide (usage HID 0x07/0x00) : rien n'est tapé et rien ne change à l'écran. Vous pouvez toujours verrouiller l'iPhone vous-même avec le bouton latéral.
- **Pas de touches fléchées.** WebDriverAgent ne sait pas simuler les touches de navigation.
- **Le clavier à l'écran se masque pendant la saisie.** La saisie passe par un clavier physique simulé : iOS masque donc le clavier à l'écran, et peut surligner le champ actif avec la couleur de l'app. Un toucher le fait revenir.

## Prérequis

| | |
|---|---|
| Mac | macOS 14 ou ultérieur |
| Xcode | **Xcode complet** (pas seulement les Command Line Tools), avec votre identifiant Apple ajouté dans *Xcode › Réglages › Comptes* |
| Compte Apple | Gratuit ou payant. Avec un compte gratuit, il faut re-signer WebDriverAgent **tous les 7 jours** ; avec un compte payant, la signature dure un an. |
| iPhone | Branché par câble et autorisé (« Se fier à cet ordinateur »), **mode développeur** activé (*Réglages › Confidentialité et sécurité*) |

Au premier lancement, WebDriverAgent est signé avec votre équipe et installé sur l'iPhone. Il faut ensuite approuver votre certificat sur l'iPhone, dans *Réglages › Général › VPN et gestion de l'appareil*.

## Installation

### Depuis les sources

```bash
git clone https://github.com/GreanOrg/GreanCast.git
cd GreanCast
make run
```

Ou ouvrez `GreanCast.xcodeproj` dans Xcode 16 ou ultérieur et faites ⌘R.

`make` produit `build/GreanCast.app` avec `xcodebuild`. L'app est signée avec votre certificat *Apple Development* si vous en avez un, pour que macOS conserve ses autorisations d'une compilation à l'autre. Sinon, elle est signée pour une exécution locale (ad hoc), et aucun compte Apple n'est nécessaire pour compiler. Dans Xcode, indiquez votre équipe dans `Config/Local.xcconfig` (voir `Config/Local.xcconfig.example`).

### Version compilée

Des DMG signés et notarisés seront publiés sur la page Releases.

## Fonctionnement

```
Mac (GreanCast)                                  iPhone
┌─────────────────────┐   usbmuxd (USB)    ┌─────────────────────────────┐
│ recopie / saisie    ├──127.0.0.1:x ─────►│ WebDriverAgent :8100 (HTTP) │
│ décodeur MJPEG      │◄─127.0.0.1:y ──────┤ flux MJPEG     :9100        │
│ xcodebuild (runner) ├───── Xcode ───────►│ runner XCUITest             │
└─────────────────────┘                    └─────────────────────────────┘
```

1. **WebDriverAgent** est téléchargé dans une version figée, dans `~/Library/Application Support/GreanCast/`. Il est compilé avec `xcodebuild build-for-testing`, signé avec votre équipe, puis lancé avec `xcodebuild test-without-building`. L'identifiant du runner est `greancast.wda.<id d'équipe>`.
2. **Connexion :** GreanCast dialogue avec `usbmuxd` (le même protocole que `iproxy`) et relaie deux ports locaux, accessibles seulement depuis 127.0.0.1, vers les ports 8100 et 9100 de l'iPhone.
3. **Saisie :** les clics et les glissers deviennent des actions de pointeur W3C. Le texte passe par `/wda/keys`, regroupé pendant qu'une requête est en cours. Les boutons physiques utilisent les points d'accès dédiés de WDA.

## Assistants IA (serveur MCP)

GreanCast intègre un serveur [Model Context Protocol](https://modelcontextprotocol.io) : un assistant de code peut regarder l'iPhone et le piloter tant que l'app est ouverte. Rien à installer, pas de connexion à un compte.

1. Ouvrez **Settings › MCP** et activez **Allow AI clients on this Mac**.
2. Ajoutez le serveur à votre client. Les réglages affichent les commandes, prêtes à copier :

   ```sh
   claude mcp add --transport http greancast http://127.0.0.1:8765/mcp   # Claude Code
   codex mcp add greancast --url http://127.0.0.1:8765/mcp               # Codex
   ```

   Cursor, VS Code et les autres clients acceptent la même URL dans leur configuration MCP (type `http`).
3. Demandez quelque chose : « prends une capture de l'iPhone », « ouvre Réglages et va dans Général ».

| Outils | Rôle |
|---|---|
| `screenshot`, `screenshot_with_metadata` | L'écran en JPEG, tiré du flux vidéo en direct ; en option avec l'appareil, la version d'iOS, l'app au premier plan, la date et l'heure, la connexion, la résolution, l'orientation, la batterie |
| `describe_ui`, `wait_for` | Les éléments à l'écran (libellés, valeurs, positions) d'après l'arbre d'accessibilité ; attendre qu'un élément apparaisse |
| `tap`, `tap_element`, `swipe`, `type_text` | Toucher, double toucher ou appui long à des coordonnées, toucher un élément par son libellé, glisser ou faire défiler, saisir du texte |
| `press_button` | Home, volume, sélecteur d'apps, centre de contrôle, verrouillage |
| `list_apps`, `launch_app`, `terminate_app`, `app_state`, `open_url` | Apps installées, ouvrir ou fermer une app, ouvrir un lien web ou un lien profond |
| `get_alert`, `accept_alert`, `dismiss_alert`, `set_orientation`, `dismiss_keyboard` | Alertes, rotation, clavier |
| `get_clipboard`, `set_clipboard`, `install_app` | Désactivés par défaut : presse-papiers de l'iPhone, installation d'un `.app` ou `.ipa` depuis le Mac |

Les coordonnées sont en pixels de la capture. Les outils d'action acceptent `screenshot: true` pour renvoyer l'écran après l'action dans le même appel.

Chaque groupe d'outils a son interrupteur dans Settings › MCP ; un outil désactivé est masqué pour les clients. **Allow AI clients on the local network** rend le serveur accessible depuis d'autres ordinateurs, par une URL qui contient un jeton secret. Le serveur ne parle que Streamable HTTP : les clients qui ne savent lancer que des commandes locales (stdio), comme l'app de bureau Claude, ne sont pas encore pris en charge.

## Sécurité

WebDriverAgent fait tourner sur l'iPhone un serveur HTTP **sans authentification**. GreanCast l'utilise toujours par USB, via des ports accessibles seulement en local. Mais **WebDriverAgent écoute aussi sur l'interface Wi‑Fi de l'iPhone pendant qu'il tourne** : pendant ce temps, n'importe qui sur le même réseau pourrait piloter le téléphone. GreanCast arrête WebDriverAgent quand vous le quittez. Évitez les réseaux non fiables pendant une session. Le mode Wi‑Fi facultatif, dans les réglages, présente le même risque.

Le serveur MCP est désactivé par défaut. Une fois activé, tout programme du Mac peut voir et piloter l'iPhone par son intermédiaire, sans authentification ; sur le réseau, quiconque possède l'URL le peut aussi. Voir [SECURITY.md](SECURITY.md) (en anglais).

## Dépannage

| Symptôme | Solution |
|---|---|
| « Program License Agreement » pendant la compilation | Acceptez le nouveau contrat sur developer.apple.com/account pour cette équipe |
| « Unlock … to Continue » | Déverrouillez l'iPhone, puis *Device › Reconnect* (⌘R) |
| Le runner s'installe mais ne démarre jamais | Approuvez le certificat : *Réglages › Général › VPN et gestion de l'appareil* |
| Un assistant IA n'atteint pas le serveur MCP | Vérifiez *Settings › MCP* : le serveur doit être activé, et le port doit correspondre à l'URL du client. « Port … already in use » signifie qu'un autre programme l'utilise : choisissez un autre port |
| Les clients du réseau ne reçoivent aucune réponse | Autorisez GreanCast dans *Réglages Système › Confidentialité et sécurité › Réseau local*, puis relancez-le |
| Fonctionne une fois, échoue une semaine plus tard | Compte gratuit : *Settings › Advanced › Rebuild WebDriverAgent* |
| Autre problème | *Settings › Advanced › Open Log File* (`~/Library/Logs/GreanCast.log`) |

L'interface de GreanCast est en anglais : les noms de menus et de réglages ci-dessus sont ceux de l'app.

## Contribuer

[![CI](https://github.com/GreanOrg/GreanCast/actions/workflows/ci.yml/badge.svg)](https://github.com/GreanOrg/GreanCast/actions/workflows/ci.yml)

Tickets et pull requests sont les bienvenus. Consultez [CONTRIBUTING.md](CONTRIBUTING.md) et notre [code de conduite](CODE_OF_CONDUCT.md) (en anglais). Vous pouvez écrire vos tickets en français ou en anglais.

## Licence

GreanCast est distribué sous [licence MIT](LICENSE). WebDriverAgent est sous licence BSD ; il est téléchargé au lancement et n'est pas inclus dans GreanCast. Voir [NOTICE](NOTICE).

« GreanCast » et « Grean » sont des marques de Grean ([TRADEMARKS.md](TRADEMARKS.md)). iPhone et Xcode sont des marques d'Apple Inc. GreanCast n'est ni affilié à Apple ni approuvé par Apple.
