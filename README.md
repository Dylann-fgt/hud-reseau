# HUD Réseau

Un bandeau discret posé en bas de l'écran, qui affiche en permanence l'**IP publique du
poste** et l'**état réel du tunnel WireGuard**.

Écrit en **PowerShell 5.1 + WPF** (rien à installer, tout est dans Windows). Un seul
fichier de script, un seul fichier de configuration. **Aucune élévation requise.**

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

```powershell
git clone https://github.com/Dylann-fgt/hud-reseau.git
cd hud-reseau

# Premier lancement : crée config.json depuis le modèle, puis s'arrête.
wscript.exe lancer-hud.vbs

# Renseigne au minimum interface / gateway / expectedPublicIp, puis relance.
notepad config.json
wscript.exe lancer-hud.vbs
```

Démarrage automatique à l'ouverture de session :

```powershell
.\installer-demarrage.ps1            # pose un raccourci dans le dossier Démarrage
.\installer-demarrage.ps1 -Retirer   # l'enlève
```

Le raccourci vise `wscript.exe`, pas `powershell.exe` : `lancer-hud.vbs` démarre le script
**sans faire clignoter de fenêtre console**. Aucune écriture hors du profil courant — ni
registre machine, ni tâche planifiée, ni service.

**Une seule instance à la fois** : un mutex nommé bloque les doublons, silencieusement.

---

## Configuration — `config.json`

Le dépôt versionne **`config.example.json`**. Le premier lancement en fait une copie de
travail nommée `config.json`, qui n'est **pas** versionnée : elle désigne une installation
précise, et le HUD la réécrit tout seul à chaque fois qu'on déplace le bandeau.

| Clé | Effet |
|---|---|
| `interface` | nom exact de l'adaptateur WireGuard, tel que Windows le nomme |
| `gateway` | adresse à pinguer **dans** le tunnel (l'extrémité serveur) |
| `expectedPublicIp` | l'IP publique attendue quand le VPN travaille — celle du serveur de sortie |
| `expectedLabel` | libellé affiché en face de cette IP dans l'infobulle |
| `linkIntervalSec` | cadence de la sonde d'adaptateur (défaut **3 s**) |
| `gatewayIntervalSec` | cadence du ping de passerelle (défaut **15 s**) |
| `publicIpIntervalSec` | cadence de la mesure d'IP publique (défaut **90 s**) |
| `position` | `bottom-center`, `bottom-right`, ou `custom` (écrit tout seul après un glisser) |
| `offsetX` / `offsetY` | marges — ou coordonnées absolues si `position` vaut `custom` |
| `opacity` | opacité au repos ; le survol repasse à 1.0 |
| `hideOnFullscreen` | efface le bandeau devant une application plein écran |

Pour retrouver le nom exact de l'adaptateur :

```powershell
Get-NetAdapter | Where-Object InterfaceDescription -like '*WireGuard*' | Select-Object Name, Status
```

---

## Interactions

- **glisser** — déplacer le bandeau ; la position est enregistrée dans `config.json`
- **survol** — opacité pleine, et une infobulle détaillée : adresse dans le tunnel, latence
  vers la passerelle, octets reçus depuis le montage, heure de la dernière mesure d'IP
- **clic droit** — rafraîchir tout de suite · replacer au centre / à droite · copier l'IP
  publique · quitter

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
- **S'efface devant le plein écran**, et repasse à l'opacité pleine au survol.

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
