# X-RAID sous Linux 6.18 : compatibilité, garde-fous, bascule vers md

Ce document décrit le paquet `package/xraid-compat` : lire **et écrire** le
volume X-RAID créé par RAIDiator (ReadyNAS Duo v1, 2 disques en miroir) sans
le convertir, puis, si on le souhaite, passer au RAID logiciel `md` de Linux.

**État : rien n'a encore été essayé sur le NAS.** Tout a été écrit d'après la
description fonctionnelle du format (résumée au §1, établie pour
l'interopérabilité, sans reprendre de code d'Infrant/NETGEAR) et essayé sur PC
avec des images disque factices (§8). Les relevés à faire sur le NAS avant
toute écriture sont au §9.

Par défaut le X-RAID est monté **en lecture seule** (`XRAID_RW=non`). L'écriture
ne s'active qu'après validation, en écrivant `XRAID_RW=oui` dans
`/etc/nas-raid.conf`.

## 1. Le format X-RAID en bref

- X-RAID n'est **pas** `md`. Le pilote de RAIDiator (`padre_io`) recopie chaque
  écriture tombant dans une **section** sur l'autre disque, **aux mêmes LBA**.
  Pas de décalage, pas de bande, pas de métadonnées entre les données.
- Le disque **base** a un MBR ordinaire : `p1` racine RAIDiator (ext3),
  `p2` swap, `p3` étendue, `p5` volume physique LVM (groupe `c`, volume `c`,
  ext3 à **blocs de 16 Kio**, monté sur `/c`). Le disque **miroir** n'a **pas de
  MBR** (secteur 0 à zéro) mais contient la même image à partir du secteur 1.
- Sections installées par RAIDiator (LBA de 512 octets) : section 0 =
  [32, 32 + 4 096 000), section 1 = [4 096 032, V − 2 + 30). V est la taille
  « visible » : N − 20 480 secteurs en général, ou une taille fixe par classe de
  disque (750 Go : V = 1 465 128 688 pour N = 1 465 149 168).
- La fin de chaque disque (au-delà de V, ~10 Mio) est la **zone protégée** :
  superbloc courant en N − 4096 (copie en N − 4072), superbloc de secours en
  N − 4048 (copie en N − 4024), marque « WGam » en N − 2.
- Superbloc (9 440 octets, entiers 32 bits **gros-boutistes**) : magic
  `WGao` (0x5747616F) en 0, version 0.1.0, identifiant (fin de l'adresse MAC du
  NAS) en 0x14, date de création en 0x18, V en 0x20, nombre de disques en
  0x24/0x28, disque fictif en 0x33, **bit 0 de 0x84 = arrêt propre**, nombre de
  sections en 0x100 ; table des disques (12 × 128 octets en 0x200, entrée 1 =
  SATA 0, entrée 2 = SATA 1 : rôle base/miroir, **état** en +0x10 :
  0 en panne, 1 online, 2 secours, 8 en reconstruction, copie de la table de
  partitions en +0x18) ; table des sections (32 octets en 0x800 : niveau en +5,
  disques porteurs (`dmap`, 3 = les deux) en +4, utilisée en +6, **initialisée**
  (miroir synchronisé, `initialized` du pilote) en +7 ; +8 reste non nul sur
  un volume sain et n'est pas lu comme état de synchronisation ; début en
  +0x10, taille en +0x18) ; entrée du disque porteur (`this_disk`) en 0x1460.
- Sous Linux 6.18 les disques s'appellent `sda`/`sdb` dans l'ordre des ports
  SATA ; le disque base peut être l'un ou l'autre (sur un Duo installé avec
  le second port en base, la base est `sdb`). Les outils se fient au
  superbloc (`this_disk`), jamais au nom.

## 2. Ce que fait la compatibilité

Au démarrage, `S35stockage` lance `nas-raid monter` (avant NFS et SMB) :

1. **Analyse** (`xraid-info`, C, lecture seule) des disques SATA (pas la clé
   USB) : les quatre copies du superbloc, choix du superbloc de référence
   (identique sur les disques, sinon le plus récent), rôle de chaque disque,
   sections bornées à V, partitions (MBR du disque **base** ; s'il manque,
   table recopiée dans le superbloc et EBR lus sur le miroir), puis
   **comparaison de 256 blocs de 64 Kio par section** aux mêmes LBA sur les
   deux disques. Verdict : `rw`, `ro` ou `aucun`, avec les raisons.
2. **Lecture et écriture** (tous les garde-fous passent et `XRAID_RW=oui`) :

        disque base   ──dm-linear [début, début+lg)──┐
                                                    ├─ mdadm --build (RAID 1, AUCUN superbloc)
        disque miroir ──dm-linear [début, début+lg)──┘        = /dev/md10 (section 0), /dev/md11 (section 1)
        partitions du disque base ── dm-linear sur md1x ── /dev/mapper/xr-p1, xr-p2, xr-p5
        xr-p5 ── LVM (vgchange -ay c, métadonnées en lecture seule) ── /dev/mapper/c-c
        /dev/mapper/c-c ── fuse2fs (ext3 à blocs de 16 Kio) ── /c

   Chaque écriture va donc sur les deux disques aux mêmes LBA, exactement
   comme le faisait RAIDiator, et uniquement **dans les sections bornées à V**.
   Le disque base est le premier membre (source d'une réparation).
3. **Lecture seule** (un garde-fou refuse l'écriture) : pas de md ; les
   partitions sont projetées directement sur un seul disque (la base si elle est
   « online », sinon le miroir) avec `dmsetup --readonly`, LVM avec
   `read_only_volume_list`, et `fuse2fs -o ro`.
4. Si un disque porte un superbloc md (déjà migré), c'est le md qui est monté
   sur `/c` (`mdadm --assemble --scan`, VG `donnees`, ext4).

À l'arrêt (`nas-raid demonter`) : démontage, LVM désactivé, md arrêtés, dm
retirés.

Le swap (`p2`) et la racine RAIDiator (`p1`) ne sont pas utilisés (le swap de
RAIDiator a des pages de 16 Kio).

## 3. Garde-fous

| Situation | Effet |
|---|---|
| `XRAID_RW` ≠ `oui` (défaut) | lecture seule |
| Superbloc absent, version ≠ 0.1.0, sections incohérentes, deux « base » | rien n'est monté |
| Superbloc courant absent (secours seul) ou différent d'un disque à l'autre | lecture seule |
| **Arrêt non propre** noté par RAIDiator (bit 0 de 0x84 à 0) | lecture seule, jusqu'à une vérification complète réussie (§4) |
| **Un disque manque** ou configuration à un disque | lecture seule sur le disque présent |
| **Synchronisation inachevée** (point de reprise ≠ 0, disque en reconstruction/secours) | lecture seule |
| Section qui n'est pas un miroir (RAID 4 des NV+) | lecture seule |
| **Échantillons différents** aux mêmes LBA | lecture seule |
| Partition qui déborde des sections ou de V | lecture seule |
| Arrêt brutal **sous Linux** (marque `/var/lib/nas-raid/xraid-sale` restée) | lecture seule, jusqu'à une vérification complète réussie |
| md X-RAID dégradé à l'arrêt (un disque a lâché en cours de route) | la marque reste : lecture seule au démarrage suivant |
| Migration en cours | X-RAID en lecture seule |

Toujours : `xraid-info` n'ouvre les disques qu'en lecture ; `nas-raid` n'écrit
**jamais** le superbloc X-RAID ni la zone protégée en mode compatibilité (aucune
table dm ne dépasse V ; vérifié par les essais) ; pas de superbloc md
(`--build`) ; métadonnées LVM en lecture seule (`metadata_read_only`).
Une seule action `nas-raid` à la fois (verrou).

## 4. Risques et limites

- **Pas de suivi de resynchronisation** : sans superbloc md ni mise à jour du
  superbloc X-RAID, une coupure de courant pendant une écriture peut laisser
  les deux disques différents, sans que rien ne le note sur les disques. La
  marque `xraid-sale` (sur la clé USB) le détecte et repasse en lecture seule ;
  il faut alors `nas-raid verifier`. Si la clé USB est remplacée, la marque est
  perdue : faire une vérification complète.
- Après un passage sous Linux, RAIDiator voit toujours son superbloc comme avant
  (rien n'y est écrit) : il ne sait pas que les données ont changé ; elles sont
  aux mêmes endroits sur les deux disques, il peut donc les relire.
- Un disque qui lâche **en cours de route** : md continue sur l'autre ; la
  marque reste et le démarrage suivant est en lecture seule. Ne pas réassembler
  à la main avec `--assume-clean`.
- `fuse2fs` en espace utilisateur sur un SPARC à ~200 MHz : lent. Un journal
  ext3 à rejouer peut empêcher le montage en écriture (fsck préalable sur PC).
- LVM : si le groupe `c` contient des instantanés RAIDiator, il faut
  `CONFIG_DM_SNAPSHOT` (absent du noyau) ; à vérifier avec les relevés.
- SMART est lu par ATA PASS-THROUGH (`xraid-info smart`), pas par smartctl
  (absent : chaîne sans C++) : non vérifié sur le NAS.
- Ordre des octets du superbloc tel que vu par Linux : supposé gros-boutiste,
  à confirmer par les relevés.

## 5. Vérification et réparation du miroir

- `nas-raid verifier` (ou « Vérifier le miroir » dans DIET) compare **tout le
  contenu des sections** des deux disques par blocs de 1 Mio, en lecture seule
  (`xraid-info verifier`), relit trois fois un bloc différent (écriture en
  cours), note les zones de 64 Mio différentes (`/var/lib/nas-raid/verif.res`)
  et les erreurs de lecture. Plusieurs heures pour 2 × 750 Go. Mieux vaut le
  faire volume en lecture seule. Réussie hors écriture, elle retire la marque
  `xraid-sale` et accepte un superbloc RAIDiator « non propre ».
- `nas-raid reparer --confirmer REPARER --oui` : seulement si les raisons sont
  « arrêt non propre » ou « échantillons différents ». Assemble en écriture et
  lance `repair` sur chaque md : la base est recopiée sur le miroir là où ils
  diffèrent. Ensuite `nas-raid verifier`, puis redémarrer.

## 6. Bascule vers md

Toutes ces actions effacent des disques. Elles demandent **deux
confirmations** : `--confirmer PHRASE` (phrase exacte affichée en cas de refus)
**et** `--oui` ; dans DIET, une case à cocher et la phrase à taper. Chacune a un
mode **à blanc** (`--a-blanc`) qui affiche les commandes sans rien exécuter ni
écrire. Journal : `/var/lib/nas-raid/journal` (onglet Journaux de DIET).

Le md créé : RAID 1 sur disques entiers, métadonnées 1.2, bitmap interne, nom
`donnees` (`/dev/md/donnees`, `/etc/mdadm.conf`), LVM (VG `donnees`, LV `c`),
ext4 à blocs de 4 Kio, monté sur `/c` par le noyau (plus de fuse2fs).

### 6.1 Migration sur place des deux disques (sans 3ᵉ disque)

    nas-raid migrer --a-blanc                       # voir ce qui sera fait
    nas-raid verifier                               # obligatoire, < 7 jours
    nas-raid migrer --confirmer MIGRER --oui        # étapes 1 à 3
    nas-raid migrer --finaliser --confirmer 'EFFACER sdX' --oui   # étape 4

Contrôles préalables : X-RAID sain (deux disques online, pas de synchronisation,
échantillons identiques, pas d'arrêt brutal non vérifié), vérification complète
réussie de moins de 7 jours, SMART des deux disques lisible et sans secteur
en attente ni illisible (`--sans-smart` pour passer outre, déconseillé), données
de `/c` assez petites pour le md.

1. **casser** : le disque miroir B quitte le X-RAID : début et zone X-RAID de B
   effacés, md RAID 1 **dégradé** sur B, LVM, ext4. Le X-RAID est remonté en
   **lecture seule** sur le disque base A seul (toujours lisible par RAIDiator
   comme un X-RAID dégradé). Le md est monté sur `/mnt/md`.
2. **copier** : `rsync -aH --numeric-ids --delete /c/ /mnt/md/`, reprenable
   (relancer la même commande après une coupure ; au démarrage, `S35stockage`
   remonte X-RAID en lecture seule et le md sur `/mnt/md`). Refusé si `/c` n'est
   pas le X-RAID en lecture seule ou si `/mnt/md` n'est pas monté.
3. **vérifier** : `rsync -n -c` (sommes de contrôle ; `VERIF_RSYNC=` dans
   `/etc/nas-raid.conf` pour comparer taille et date seulement) ; toute
   différence arrête la migration. La migration s'arrête ici : contrôler
   `/mnt/md`.
4. **finaliser** (`--finaliser`, phrase `EFFACER <disque base>`) : refusé si le
   md contient moins de la moitié des données du X-RAID ; A est effacé (début
   et zone X-RAID) puis ajouté au md : **resynchronisation** (`/proc/mdstat`) ;
   `/c` = md. **Le retour au X-RAID/RAIDiator n'est plus possible.**

Étapes et journal dans `/var/lib/nas-raid/` (`migration`, `journal`).

### 6.2 Nouveau RAID md (disques neufs ou existants)

    nas-raid creer /dev/sda /dev/sdb --confirmer 'EFFACER sda sdb' --oui

Efface les disques (y compris un X-RAID), crée le md (un seul disque : md
dégradé, compléter avec `ajouter`), LVM, ext4, monte `/c`. Seuls les disques
SATA du NAS sont acceptés.

### 6.3 Remplacement et extension verticale

    nas-raid ajouter /dev/sdb --confirmer 'EFFACER sdb' --oui   # disque neuf à la place d'un ancien
    nas-raid agrandir --confirmer AGRANDIR --oui                 # quand les deux sont plus grands

Remplacer un disque à la fois (retirer l'ancien, insérer le nouveau,
`ajouter`, attendre la fin de la resynchronisation), puis `agrandir` : bitmap
retiré, `mdadm --grow --size=max`, bitmap remis, `pvresize`, `lvextend`,
`resize2fs` (ext4 monté).

## 7. Tableau de bord DIET

La carte « Stockage /c » affiche le mode (X-RAID lecture et écriture, X-RAID
lecture seule, RAID md), les raisons d'une lecture seule, l'état des sections,
la dernière vérification du miroir et l'étape d'une migration. Boutons :
« Vérifier le miroir », « Migrer vers md », « Terminer la migration »,
« Créer un RAID md » (assistant : essai à blanc, case à cocher, phrase à
taper) et « Journal du stockage ». API : `GET ?a=stockage` (`nas-raid etat
--json`, sans accès aux disques : résultat mis en cache au montage), `POST
?a=raid_verifier|raid_plan|raid_lancer`, journal `?a=log&f=stockage`.

## 8. Essais sur PC (sans NAS, sans root)

    sh package/xraid-compat/tests/essai.sh
    sh package/diet/tests/essai-api.sh

`tests/fabrique-images.py` fabrique des images en fichiers creux (750 Go
apparents, quelques Mo réels) : superbloc, copies, secours, « WGam », MBR sur
la base seulement, EBR, sections, avec les scénarios propre, sale, dégradé,
synchronisation inachevée, miroir différent, disque md. Les essais vérifient
la détection, le JSON, la vérification complète, les verdicts, les commandes
d'assemblage (aucune table au-delà de V), les refus (vérification, SMART,
confirmations), les essais à blanc de migration, création, extension, et
l'API DIET. dmsetup, mdadm, lvm, fuse2fs et mount sont simulés : aucun
périphérique dm ou loop n'est créé (il faudrait root).

## 9. Relevés à faire sur le NAS (lecture seule)

Sous le système 6.18 avec `XRAID_RW=non` (défaut). Les fichiers produits
contiennent des **numéros de série** (IDENTIFY dans le superbloc), une partie
de l'**adresse MAC** et le **nom d'hôte** (métadonnées LVM) : ne pas les publier.
Les écrire sur la clé USB, pas sur les disques. Pour chaque disque `X` = `a`,
`b` :

    N=$(cat /sys/block/sdX/size); echo "sdX $N"
    dd if=/dev/sdX of=/debut-sdX.bin bs=512 count=128                  # 64 premiers Kio (MBR)
    dd if=/dev/sdX of=/fin-sdX.bin bs=512 skip=$((N - 20480)) count=20480   # 10 derniers Mio (superblocs)
    xraid-info smart /dev/sdX

puis :

    xraid-info --echantillons 64 /dev/sda /dev/sdb
    xraid-info --json /dev/sda /dev/sdb
    dd if=/dev/sdB of=/pv-debut.bin bs=512 skip=4608040 count=2048     # sdB = le disque base : étiquette et métadonnées LVM
    cat /proc/partitions; dmesg | grep -i -E 'sd[ab]|ata[12]'
    nas-raid etat; nas-raid monter --a-blanc; nas-raid migrer --a-blanc
    cat /var/run/nas-raid.mode; ls /c; df /c                           # montage en lecture seule fait par S35stockage
    lvm lvs --config 'devices { filter = [ "a|^/dev/mapper/xr-p|", "r|.*|" ] }'

À vérifier : `od -A d -t x1 -j 8388608 -N 4 /fin-sdX.bin` donne `57 47 61 6f`
(« WGao » en N − 4096, gros-boutiste) ; `xraid-info` répond `rw` ou `ro` avec
des raisons cohérentes ; sections 32 / 4 096 000 et 4 096 032 / 1 461 032 686 ;
base = le disque qui a un MBR ; `ls /c` lisible ; LVM sans instantané ; valeurs
SMART plausibles (heures de marche). Ensuite seulement : `nas-raid verifier`, puis
`XRAID_RW=oui` et un redémarrage.

## Fichiers

| Fichier | Rôle |
|---|---|
| `package/xraid-compat/src/xraid-info.c` | analyse, vérification complète, SMART (lecture seule) |
| `package/xraid-compat/src/nas-raid` | montage, démontage, vérification, réparation, migration, md |
| `package/xraid-compat/src/S35stockage` | démarrage et arrêt |
| `package/xraid-compat/tests/` | images factices et essais |
| `/etc/nas-raid.conf` (sur le NAS, facultatif) | `XRAID_RW`, `ECHANTILLONS`, `VERIF_RSYNC`, `FUSE2FS_OPTS`… (variables en tête de `nas-raid`) |
| `/var/lib/nas-raid/` (sur le NAS) | marques, vérification, migration, journal |
