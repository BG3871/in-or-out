# Juge de ligne (in-or-out)

Appli iPhone qui juge en direct si la balle est bonne ou faute sur **une seule ligne : celle qui part du téléphone**.
Le téléphone est posé au sol, au bout de la ligne, et filme à 240 images/s. Sur une faute nette, la lampe arrière
flashe et l'appli annonce « Faute ! » à voix haute.

Le jugement reprend exactement la logique de `juge_ligne.py` (analyse des vidéos sur ordinateur) :
suivi de la balle jaune autour de la ligne, contact au croisement des paraboles de descente et de remontée,
balle masquée jusqu'à 60 ms extrapolée, marge d'incertitude, seuils 5 cm (litigieux) et 30 cm (proche).

## Verdicts

| Verdict | Quand | Ce que fait l'appli |
|---|---|---|
| **Bonne** | contact sur la ligne ou côté court, au-delà de la marge d'incertitude | rien (noté au journal) |
| **Faute** | contact dehors à plus de 5 cm **et** au-delà de la marge, suivi suffisant (≥ 5 images de chaque côté) | flash + « Faute ! » en mode Arbitre ; extrait vidéo gardé |
| **Douteuse** | trop près pour trancher (dehors à 5 cm ou moins, ou dans la marge), ou suivi trop court | **aucun signal** ; extrait vidéo gardé pour annotation |

Seuls les rebonds de jeu sont jugés (balle qui avance latéralement, ≥ 384 px/s) : les dribbles et balles
ramassées sont ignorés, comme dans le script.

## Utilisation

1. **Direct** : poser le téléphone au bout de la ligne, choisir le côté faute et le mode, puis appuyer sur
   **« Calibrer et commencer »** et lâcher le téléphone. Après un décompte de 3 s, l'appli trouve seule la ligne dans
   l'axe (la plus longue ligne fuyante qui arrive au pied du téléphone, comme le script) et commence à juger.
   Elle **refuse de juger si elle n'est pas sûre** (deux lignes candidates, bords irréguliers) ; on peut alors réessayer
   ou tracer la ligne à la main (deux touchers, puis nouveau décompte : la ligne est remesurée sur des images prises
   après les touchers, donc un léger mouvement du téléphone ne compte pas).
   - **Silencieux** (par défaut) : l'appli note ses verdicts sans signal. À utiliser tant que la concordance
     avec tes annotations n'est pas jugée suffisante.
   - **Arbitre** : flash (1,5 s par défaut, réglable de 0,5 à 3 s, bouton « Essai ») et « Faute ! » sur les fautes nettes.
     Le son suit la sortie audio de l'iPhone : une enceinte Bluetooth connectée le reçoit. L'annonce peut être ta propre
     voix (« Enregistrer mon Faute ! » : silences coupés, volume au maximum), un fichier audio importé, ou la voix de l'iPhone.
   - Toutes les 3 s, l'appli vérifie que la ligne n'a pas bougé. Si le téléphone a bougé (plus de 4 px),
     elle s'arrête et demande de recalibrer.
2. **Rejeu** : choisir une vidéo au ralenti déjà filmée (IMG_1299, IMG_1323…). Même détecteur et même juge que le direct.
3. **Journal** : chaque rebond jugé, avec son extrait vidéo pour les fautes et les douteuses. Boutons « Bonne / Faute »
   pour annoter ; l'appli affiche la concordance. Export CSV par le bouton de partage. Les extraits sont aussi dans
   l'app Fichiers (dossier Juge de ligne > Extraits).

## Installer sur l'iPhone (sans Mac)

La compilation se fait sur un Mac de GitHub (même montage que paraphe-express).

Une seule fois :
1. Dans le dépôt GitHub : Settings > Secrets and variables > Actions, ajouter `ASC_KEY_ID`, `ASC_ISSUER_ID`
   et `ASC_KEY_P8` (clé API App Store Connect au rôle Admin, les mêmes que pour paraphe-express).
2. Sur developer.apple.com > Identifiers : enregistrer l'identifiant `fr.jugedeligne.app`.
3. Dans App Store Connect : créer l'appli « Juge de ligne » avec cet identifiant.

Ensuite, à chaque version : onglet **Actions** > « iOS : envoi sur TestFlight » > **Run workflow**. La version
arrive dans TestFlight sur l'iPhone 10 à 30 minutes après.

## Développement

- `JugeCore/` : le cœur (suivi, rebonds, verdict, détecteur de balle, calibrage de la ligne), sans dépendance à iOS.
  `swift test --package-path JugeCore` le teste sur Linux ou Mac en rejouant les détections de IMG_1299 et IMG_1323
  exportées par `juge_ligne.py` :
  - mêmes rebonds que le script (instants, distances, marges, niveaux) sur les 412 rebonds des deux vidéos ;
  - les 12 balles annotées (10 sur IMG_1323, 2 sur IMG_1299) : aucune balle bonne jugée faute, les 4 fautes annoncées ;
  - le juge en direct annonce les mêmes rebonds que l'analyse complète, moins de 0,25 s après le rebond ;
  - balle masquée 30 ms au contact retrouvée par extrapolation ;
  - bords de ligne retrouvés à moins d'un demi-pixel de ceux du script, avec ou sans touchers (détection automatique).
- `App/` : l'appli SwiftUI (caméra, lampe, voix, extraits, journal, rejeu). Le projet Xcode est généré par
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) à partir de `project.yml`.
- Workflows : « Tests du cœur » (Linux) et « Compilation iOS » (Mac, sans signature) à chaque envoi ;
  « iOS : envoi sur TestFlight » à la demande.

## Limites connues

- Le délai d'annonce est d'environ 0,2 s après le rebond : le verdict attend la remontée de la balle.
- La conversion en cm suppose une ligne de 5 cm de large (une ligne de fond peut faire jusqu'à 10 cm).
- Les fautes loin de la ligne (plus de 30 cm) sont annoncées aussi, mais n'ont pas encore été vérifiées à l'œil.
- À vérifier sur l'iPhone : que la lampe reste utilisable pendant la capture à 240 i/s, la chauffe sur une longue
  séance, et le nombre d'images analysées par seconde (affiché à l'écran, en orange sous 200).
