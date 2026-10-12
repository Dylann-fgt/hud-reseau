# HUD Réseau

L'**IP publique du poste** et l'**état réel du tunnel WireGuard**, affichés en permanence
dans un bandeau discret en bas de l'écran **et** par une icône dans la zone de notification,
près de l'horloge.

Écrit en **PowerShell 5.1 + WPF** (rien à installer, tout est dans Windows). Un installateur
par utilisateur, une fenêtre de paramètres. **Aucune élévation requise.**

---

## Pourquoi, alors que le client WireGuard dit déjà « connecté »

Le client WireGuard sait dire que l'interface est montée. Il ne sait pas dire **par où sort
le trafic**.

Sur un poste en **tunnel complet**, la question qui compte n'est pas « l'interface
est-elle up » mais « **mon trafic passe-t-il vraiment par le VPN** ». Ce sont deux choses
différentes, et l'écart entre les deux est exactement la panne qu'on ne remarque pas : un
tunnel monté qui ne transporte rien.

Le HUD répond aux deux, en croisant **trois sondes indépendantes** :

| Sonde | Ce qu'elle prouve | Cadence par défaut |
|---|---|---|
| présence et état de l'adaptateur WireGuard | le tunnel **existe** | 3 s |
| ping de la passerelle du tunnel | le tunnel **passe du trafic** | 15 s |
| IP publique observée, comparée à celle attendue | la sortie se fait **bien par le VPN** | 90 s |

D'où quatre cas — dont un que l'icône WireGuard ne montre jamais :

| | Condition | Affichage |
|---|---|---|
| 🟢 | les trois sondes concordent | `VPN actif` |
| 🟠 | interface up, passerelle muette | `tunnel muet` |
| 🟠 | interface up, **IP publique ≠ celle attendue** | **`hors tunnel`** — fuite, tunnel partiel, ou route cassée |
| 🔴 | adaptateur absent ou down | `VPN coupé` |

**`hors tunnel` est la raison d'être de l'outil.**

---

## Installation

**Double-clic sur `Installer.cmd`.** L'assistant installe — ou met à jour — le HUD pour
le compte courant, sans droit administrateur, et le lance.

| Ce qu'il écrit | Où |
|---|---|
| le programme | `%LOCALAPPDATA%\Programs\HUD-Reseau\` |
| le raccourci | menu Démarrer › **HUD Réseau** |
| le lancement à l'ouverture de session *(case à cocher)* | dossier Démarrage |
| l'entrée de désinstallation | Paramètres › Applications › **Applications installées** |

Ni registre machine, ni service, ni tâche planifiée. Les raccourcis visent `wscript.exe` :
`lancer-hud.vbs` démarre le script **sans faire clignoter de fenêtre console**.

Sans assistant :

```powershell
.\installer.ps1 -Silencieux       # installe, démarrage automatique, lance le HUD
.\installer.ps1 -Desinstaller     # désinstalle (propose de garder les réglages)
```

Une mise à jour arrête proprement le HUD en cours — par un signal nommé, sans tuer de
processus — et **conserve les réglages**.

**Une seule instance à la fois.** Relancer le HUD alors qu'il tourne (menu Démarrer,
double-clic) ouvre sa fenêtre de paramètres au lieu d'en démarrer un deuxième.

### Antivirus

Un script PowerShell qui se copie dans `AppData`, démarre caché et se lance à l'ouverture de
session ressemble, vu de loin, à ce que fait un logiciel malveillant. **Bitdefender
(Advanced Threat Control, `Atc4.Detection`) a bloqué la première version de l'installateur**
et mis en quarantaine le script *et ses sources*. L'installateur ne fait plus ce qui
l'avait alerté — retirer la marque « provenant d'Internet » (`Unblock-File`), énumérer puis
tuer des processus — mais une alerte comportementale reste possible. Si elle survient :
restaurer depuis la quarantaine, puis ajouter une exception sur le dossier d'installation.
Une restauration laisse les fichiers **verrouillés en écriture** jusqu'au redémarrage.

---

## Premier lancement et paramètres

Au premier lancement, la **fenêtre de paramètres** s'ouvre seule. On la retrouve ensuite par
un **clic gauche sur l'icône** de notification, ou clic droit › *Paramètres…*

- **Interface WireGuard** — bouton *Détecter* : liste les tunnels actifs et propose la
  passerelle (première adresse du réseau du tunnel — à vérifier). WireGuard **retire
  l'adaptateur quand le tunnel est désactivé** : il faut l'activer pour le détecter.
- **IP publique attendue** — bouton *IP actuelle* : reprend l'IP de sortie mesurée. Le HUD
  prévient si le tunnel n'est pas monté à ce moment-là — on reprendrait l'adresse de la box.
- fréquence des trois sondes, bandeau (affiché ou non, position, opacité, effacement devant
  le plein écran), notifications, lancement à l'ouverture de session.

Les réglages vivent dans **`%APPDATA%\HUD-Reseau\config.json`**, hors du dossier
d'installation : une mise à jour ne les touche pas. Le dépôt versionne
`config.example.json`, qui documente les clés ; un `config.json` laissé à côté du script par
la version 1 est repris automatiquement au premier lancement.

| Clé | Effet |
|---|---|
| `interface` | nom exact de l'adaptateur WireGuard, tel que Windows le nomme |
| `gateway` | adresse à pinguer **dans** le tunnel (l'extrémité serveur) ; vide = pas de ping |
| `expectedPublicIp` | l'IP publique attendue quand le VPN travaille ; vide = pas de comparaison |
| `expectedLabel` | nom de cette sortie, affiché dans l'infobulle et les notifications |
| `linkIntervalSec` / `gatewayIntervalSec` / `publicIpIntervalSec` | cadences (défaut **3 / 15 / 90 s**) |
| `showBar` | affiche le bandeau ; l'icône de notification, elle, reste toujours |
| `position` | `bottom-center`, `bottom-right`, ou `custom` (écrit tout seul après un glisser) |
| `offsetX` / `offsetY` | marges — ou coordonnées absolues si `position` vaut `custom` |
| `opacity` | opacité du bandeau au repos ; le survol repasse à 1.0 |
| `hideOnFullscreen` | efface le bandeau devant une application plein écran |
| `notify` | notification Windows quand l'état change |

---

## Interactions

**Icône de notification** — sa pastille prend la couleur de l'état.

- **survol** — état et IP publique
- **clic gauche** — paramètres
- **clic droit** — état · rafraîchir · copier l'IP publique · afficher le bandeau · position ·
  effacement en plein écran · notifications · lancement à l'ouverture de session ·
  paramètres · quitter
- **notification** quand l'état change et le reste **8 s** — pas pour l'état constaté au
  démarrage, qui n'est pas un changement

Windows 11 range toute nouvelle icône sous la flèche **^**. Le HUD la sort **une fois**, à sa
première apparition ; si on la remet ensuite dans le débordement, il ne la touche plus.

**Bandeau**

- **glisser** — déplacer ; la position est enregistrée
- **survol** — opacité pleine, et une infobulle détaillée : adresse dans le tunnel, latence
  vers la passerelle, octets reçus depuis le montage, heure de la dernière mesure d'IP
- **clic droit** — rafraîchir · copier l'IP · replacer · masquer · paramètres · quitter
- **Alt+F4** masque le bandeau sans arrêter le HUD

---

## Choix techniques

- **Aucune élévation.** Tout passe par `System.Net.NetworkInformation` et un `Ping` .NET.
  `wg show` aurait donné le dernier *handshake*, mais son tube nommé est réservé aux
  administrateurs — le ping de la passerelle rend le même service sans UAC. Un HUD
  permanent qui réclamerait l'élévation à chaque ouverture de session serait un mauvais
  échange.
- **Deux threads.** Les mesures tournent dans un *runspace* séparé et déposent leur
  résultat dans une table synchronisée ; l'interface WPF ne fait que **lire**. Une requête
  HTTPS lente ne fige donc jamais le bandeau — c'est la seule raison d'avoir un deuxième
  thread ici.
- **`PER_MONITOR_AWARE_V2` déclaré AVANT la création de la fenêtre.** Sinon Windows étire
  un rendu 96 dpi et le texte est flou sur un écran à 150 %. L'ordre compte : après, il est
  trop tard.
- **Hors Alt+Tab** via le style étendu `WS_EX_TOOLWINDOW`. Un bandeau permanent n'a rien à
  faire dans le sélecteur de fenêtres.
- **S'efface devant le plein écran — le vrai.** Une fenêtre compte comme plein écran si
  elle n'est **pas agrandie** et couvre **tout l'écran où elle se trouve**, cet écran étant
  celui du bandeau. La version 1 comparait sa taille à celle de l'écran *principal* : sur un
  poste à deux écrans, un navigateur simplement agrandi sur le plus grand faisait disparaître
  le bandeau.
- **Icône de notification** en WinForms (`NotifyIcon`) dans le même fil que WPF : le
  `Dispatcher` de WPF pompe aussi ses messages. Pastilles dessinées à la taille système,
  libérées (`DestroyIcon`) à la sortie.

### Piège d'encodage — transposable à tout script PowerShell

**PowerShell 5.1 lit un `.ps1` sans BOM en ANSI.** Un tiret cadratin UTF-8 s'y décode alors
en `â€"` — dont le dernier caractère est un **guillemet typographique fermant**, que le
parseur accepte comme délimiteur de chaîne.

Le script ne meurt donc pas sur le caractère fautif : il meurt **trente lignes plus loin**,
sur une parenthèse « manquante », et on cherche au mauvais endroit.

**`hud-reseau.ps1` doit rester en UTF-8 *avec* BOM.** À revérifier après toute édition par
un outil qui écrit sans.

---

## Trois façons de fausser sa lecture

Un indicateur qui ment est pire qu'un indicateur absent. Ceux-ci sont connus :

1. **L'IP publique attendue est écrite en dur.** Si le serveur de sortie change d'adresse,
   l'état bascule en `hors tunnel` sans qu'aucune fuite n'existe. `expectedPublicIp` doit
   être mis à jour en même temps que le serveur.
2. **Le service d'écho d'IP est un tiers** (`api.ipify.org`, puis deux replis :
   `icanhazip.com`, `ifconfig.me`). Il voit l'IP de sortie — donc celle du serveur quand le
   tunnel travaille. Rien de personnel n'y transite, mais **la requête part toutes les
   90 s** et elle est visible dans les journaux réseau.
3. **La sonde de plein écran masque le bandeau**, et un HUD invisible n'est pas un HUD vert.

---

## Prérequis

- **Windows 10 / 11**, PowerShell **5.1** (présent par défaut).
- Un tunnel **WireGuard** déjà configuré sur le poste. Le HUD **observe**, il ne monte ni
  ne démonte rien.
- Un accès sortant HTTPS pour la mesure d'IP publique.

---

## Droits

Aucune licence n'est accordée : **tous droits réservés**. Le code est publié pour être lu,
pas pour être redistribué.

Fourni **sans aucune garantie**. C'est de l'outillage personnel mis au propre, pas un
produit.
