# DIET sur Linux 6.18

Le tableau de bord web DIET (projet
[ReadyNASDuoSparc](https://github.com/mfe-/ReadyNASDuoSparc), système 2.6.17) est
porté sur le système 6.18 : c'est le paquet `package/diet`, activé dans
`readynas_ng_defconfig` et `readynas_ng_rapide_defconfig`. Les sources sont
dans `package/diet/src/`, rangées comme sur le système cible.

## Origine et licence

- **DIET** a été écrit par **davemmi** pour le ReadyNAS NV+ v1 et publié dans le dépôt
  [mfe-/ReadyNASDuoSparc](https://github.com/mfe-/ReadyNASDuoSparc)
  ([PR #15](https://github.com/mfe-/ReadyNASDuoSparc/pull/15)).
- Le support du ReadyNAS Duo v1 (X-RAID, langues, notifications…) vient de
  [mfe-/ReadyNASDuoSparc#16](https://github.com/mfe-/ReadyNASDuoSparc/pull/16).
- `package/diet/src/` est dérivé de ce code (interface, API, scripts), adapté ici à Linux 6.18.
- **Licence** : le dépôt d'origine ne déclare **aucune licence** à ce jour. Le code dérivé de
  DIET n'est donc **pas** couvert par la GPL-2.0 de ce dépôt ; il reste soumis aux droits de son
  auteur. Une licence sera indiquée ici dès que le projet d'origine en aura une.

## Mise en route sur le NAS

1. Au premier démarrage, `S50lighttpd` crée un certificat HTTPS auto-signé
   (ECDSA P-256, 10 ans, nom d'hôte et adresse d'eth0). Aucune clé n'est dans
   l'image. Après un changement de nom ou d'adresse :
   `/etc/init.d/S50lighttpd newcert` puis `restart`.
2. En SSH, lancer `diet-webpass` (utilisateur `admin` par défaut) pour
   choisir le mot de passe de l'interface (`/etc/lighttpd/htpasswd`). Sans
   ce fichier, tout accès est refusé.
3. Ouvrir `https://<adresse du NAS>/` (le port 80 redirige vers HTTPS).
   L'accès est limité aux réseaux privés.

## Ce qui change par rapport à l'ancien DIET

| Sujet | Ancien DIET (2.6.17) | DIET sur 6.18 |
|---|---|---|
| Serveur web | busybox httpd derrière lighttpd statique | lighttpd seul : TLS mbedTLS, `mod_auth` (htpasswd SHA-512), `mod_cgi` |
| Partages | Samba 3.6, `smb.conf` + `shares.conf`, `smbpasswd` | ksmbd : `/etc/ksmbd/ksmbd.conf`, `ksmbd.adduser` (mot de passe sur l'entrée standard), `ksmbd.control -r` |
| NFS | programmes RAIDiator en chroot (`diet-nfs`) | nfsd du noyau + nfs-utils 2.x : l'interface édite `/etc/exports` et lance `exportfs -ra` |
| Stockage | X-RAID (`/proc/xraid`), LVM `/dev/c/c` | md (`/proc/mdstat`, `mdadm --detail`), `df /c`, disques libata `sda`/`sdb` (baie = port ata) ; X-RAID existant et bascule vers md par `nas-raid` (docs/XRAID.md) |
| Températures | `smartctl` toutes les 5 min | drivetemp (`/sys/block/sdX/device/hwmon/*/temp1_input`) ; `smartctl` utilisé seulement s'il est présent |
| Ventilateur | régulé par `diet-hwmon` | régulé par `padre-ventilateur` (S45ventilateur) ; l'interface affiche son état (`/var/run/ventilateur.etat`) et modifie `/etc/ventilateur.conf` (courbe, période, seuils), puis relance le service |
| `diet-hwmon` | régulation, SMART, historique, alertes, arrêt d'urgence | surveillance seule : historique, SMART si présent, alertes Telegram. L'arrêt d'urgence est fait par `padre-ventilateur` |
| Bouton d'alimentation | `diet-hotplug` (`/proc/sys/kernel/hotplug`) | `/sbin/hotplug` → `diet-hotplug` (CONFIG_UEVENT_HELPER) : maintenu 3 s = extinction |
| Réseau | `/etc/diet-net.conf` + `S41diet-net` | `/etc/network/interfaces` (ifupdown de busybox), appliqué au prochain démarrage |
| Heure | `ntpd -q` au démarrage | `ntpd` en tâche de fond + bouton « Mettre l'heure à jour » |
| Journal | `/var/log/boot.log` | `/var/log/diet.log`, `/var/log/messages` (syslog), `dmesg` |

Ce qui est conservé : les mêmes onglets, les langues fr/de/en (page et
messages, `/etc/diet-lang`), les notifications Telegram (jeton et
identifiant saisis dans l'interface, enregistrés dans `/etc/diet-notify.conf`
sur le NAS, jamais dans l'image), la veille des disques, les voyants
(baies, alimentation), l'extinction et le redémarrage, `diet-status` en
console.

Retiré : tout ce qui est propre à X-RAID, Samba 3.6, RAIDiator
(`zu-raidiator`, `init-weiche`, `install-weiche`), la flash, l'écran LCD
(absent du Duo), `rsyncd`, LVM et `diet-import`.

## Services

Carte « Services » de l'onglet Partages (API : `GET ?a=services`,
`POST ?a=svc_set|dlna_set|dlna_scan|rsync_pw|rsync_c`, en-tête `X-Diet` obligatoire).

| Service | Ce que règle l'interface | Fichiers |
|---|---|---|
| MiniDLNA | marche/arrêt ; nom affiché (`friendly_name`) ; dossiers (`media_dir`, un par ligne, préfixe facultatif `A,` `V,` `P,`, dossiers existants sous `/c`, lettres, chiffres, espace, `-` et `_`, sans lien qui sorte de `/c`) ; « Réindexer » (`S60minidlnad force-reload` = `minidlnad -R`) | `/etc/minidlna.conf` (copie `.bak`), base dans `/var/lib/minidlna` |
| Avahi | marche/arrêt ; le nom annoncé (`<nom>.local`) suit le nom du NAS (avahi est relancé quand il change) | `/etc/avahi/services/*.service` |
| rsync | marche/arrêt ; comptes des utilisateurs (voir plus bas) ; module `[c]` de l'administrateur (tout `/c`, en root, compte `sauvegarde`) **seulement s'il est coché** (`RSYNC_C=1`), avec son mot de passe et la commande `rsync -av dossier/ sauvegarde@<nom>.local::c/sauvegardes/` | `/etc/rsyncd.conf` (généré), `/etc/rsyncd.secrets` (600) |
| WebDAV | marche/arrêt de l'instance `S51webdav` ; adresses `https://<nom>.local/webdav/<utilisateur>/` et `/webdav/<partage>/` | `/etc/lighttpd/webdav.conf` (généré), `/etc/lighttpd/htpasswd-users` |

État : en marche ou arrêté ; pour MiniDLNA, nombre de fichiers indexés
(audio, vidéo, images) lu sur sa page d'état `http://127.0.0.1:8200/status` (pas de
`sqlite3` sur le NAS) et taille de `files.db`.

Persistance : `SVC_MINIDLNA`, `SVC_AVAHI`, `SVC_RSYNC`, `SVC_WEBDAV` dans
`/etc/diet.conf` (`0` = arrêté, `1` ou absent = en marche). `S50avahi-daemon`,
`S60minidlnad` (qui remplacent ceux de Buildroot), `S61rsyncd` (dans
`board/readynas-duo-v1/rootfs-overlay/etc/init.d/`) et `S51webdav` (paquet
diet) ne démarrent pas un service à `0`. Un service arrêté perd aussi son
annonce Avahi (`rsync.service`, `webdav.service` renommés en `.service.off`,
puis `avahi-daemon -r`).

### WebDAV et rsync : les comptes locaux

Les utilisateurs de l'onglet Partages ont un seul mot de passe pour SMB,
WebDAV et rsync. Quand l'API crée un compte ou change son mot de passe
(`user_set`, mot de passe dans le corps du POST), elle l'écrit en une fois :
ksmbd (`ksmbd.adduser`, entrée standard), `/etc/lighttpd/htpasswd-users`
(crypt SHA-512 par `mkpasswd`, `root:nas` 640, distinct de
`/etc/lighttpd/htpasswd` de l'interface) et `/etc/rsyncd.secrets`
(`root` 600). `user_del` retire le compte partout (son dossier est gardé).
Jamais de mot de passe dans l'URL, les journaux ni l'image. Un compte créé
avant cette version n'a ni WebDAV ni rsync : l'interface affiche « mot de
passe à redéfinir pour activer WebDAV/rsync ».

Après chaque changement d'utilisateur ou de partage, l'API régénère :

- `/etc/rsyncd.conf` : un module `[<nom>]` par utilisateur (`path =
  /c/home/<nom>`, `uid`/`gid = <nom>`, `auth users = <nom>`,
  `munge symlinks`), un module par partage en écriture (`uid = nas`,
  `gid = users`, `auth users` = tous les comptes ; un partage qui porte le
  nom d'un utilisateur n'a pas de module), et `[c]` seulement si
  `RSYNC_C=1`. Exemple : `rsync -av dossier/ <nom>@<nas>.local::<nom>/`.
- `/etc/lighttpd/webdav.conf`, vérifié par `lighttpd -tt` avant d'être mis en
  place (sinon l'ancien est gardé et le message le dit), puis `S51webdav
  restart`. C'est une **seconde instance lighttpd** sous l'utilisateur
  système `nas` (créé par `DIET_USERS` dans `diet.mk`), sur
  `127.0.0.1:8081`, avec `umask 002` et `server.follow-symlink = "disable"`.
  Le lighttpd principal (root, HTTPS) lui relaie `/webdav` (`mod_proxy`,
  corps transmis au fil de l'eau) et ne demande pas le compte de
  l'interface sur ce chemin ; l'instance WebDAV authentifie :
  `/webdav/<nom>/` = dossier personnel, `"require" => "user=<nom>"` ;
  `/webdav/<partage>/` = partage, tout compte local (`valid-user`), en
  lecture seule si le partage l'est ; tout le reste est refusé.
  L'administrateur de l'interface n'a pas d'accès WebDAV. `mod_webdav` ne
  soumet pas l'en-tête `Destination` (COPY/MOVE) à `mod_auth` : chaque bloc
  refuse une destination hors de son propre espace, ou avec `..` ou
  `%2e`/`%2f`. `mod_extforward` (relais de confiance 127.0.0.1) rend le
  schéma `https` à l'instance pour que la `Destination` corresponde.
  Le lighttpd de l'interface n'est jamais rechargé pour WebDAV.

Modèle de droits sur `/c` :

| Dossier | Propriétaire, mode | Qui écrit |
|---|---|---|
| `/c/home` | `root:root` 755 | — |
| `/c/home/<nom>` | `<nom>:<nom>` 2770 | `<nom>` (SMB, rsync), `nas` (WebDAV) : le groupe personnel `<nom>` (groupe principal du compte) a pour seul autre membre `nas` ; setgid + umask 002 : les fichiers WebDAV sont `nas:<nom>` 664, modifiables par `<nom>` ; les autres comptes n'y entrent pas |
| `/c/<partage>` (créé par l'interface) | `root:users` 2777, sans bit collant | tout le monde (SMB invité ou compte, WebDAV `nas`, rsync `nas`) : espace commun ; ksmbd force 0666/0777 |

Un partage créé avant (`nobody` 1777, bit collant) reste tel quel : un compte
ne peut alors pas effacer les fichiers d'un autre ; pour l'aligner :
`chown root:users /c/<partage> && chmod 2777 /c/<partage>`.
Un nouveau compte a pour groupe principal son groupe personnel (même numéro
que son uid si libre) ; un compte créé avant y passe quand son mot de passe
est redéfini. Noms refusés : ceux d'un groupe système (`audio`, `video`,
`users`…), `sauvegarde`, `nas`, `c`, `home`, `webdav`, `root`.

## Rapidité : collecteur et cache

Lancer un programme coûte ~60 ms sur ce SPARC et les flottants sont émulés par
le noyau. Donc :

- **Collecteur** : `S95diet` lance l'API elle-même en tâche de fond
  (`DIET_COLLECTE=1 /www/cgi-bin/api`, pid dans `/var/run/diet/pid`). Elle écrit
  les réponses JSON prêtes dans `/var/run/diet/<clé>.json` (fichier temporaire
  puis `mv`) : `status` toutes les 5 s et le reste (`stockage services shares nfs
  sys users config`) toutes les 60 s quand l'interface est ouverte (requête vue
  depuis moins de 2 min) ; sinon 60 s et 5 min. `all.json` = état + stockage +
  historique, lu en une requête au chargement de la page.
- **Lecture** : en tête de l'API, avant le reste du script, un GET de ces clés
  fait `exec cat` du fichier si le collecteur tourne (commandes internes du
  shell seulement). Sans collecteur ou sans fichier : calcul direct, comme avant.
- **Réveil** : FIFO `/var/run/diet/reveil` (attente par `read -t`, sans
  processus). La lecture y écrit `vu` quand le collecteur est au repos (pas de
  fichier `actif`) ; un POST réussi vide le cache, pose `inval` (un calcul
  commencé avant est jeté) et écrit `tout` : tout est recalculé aussitôt.
- **Calcul** : `/proc`, `/sys` et les fichiers de configuration sont lus par le
  shell (`read`, développements de variables, `$((…))` en entiers 64 bits) :
  `status` lance 2 programmes (`ifconfig`, `df`) au lieu d'une soixantaine ;
  pas de `printf %f` ni de calcul dans awk.
- **busybox** : `FEATURE_SH_STANDALONE`, `FEATURE_PREFER_APPLETS` et
  `FEATURE_SH_NOFORK` (dans `DIET_BUSYBOX_CONFIG_FIXUPS`) : ash lance ses applets
  sans les chercher dans le `PATH` et les applets « nofork » (`cat`, `echo`,
  `printf`, `test`…) sans créer de processus. Un programme de même nom qu'un
  applet n'est lancé que par son chemin complet.

`/etc/init.d/S95diet restart-collecte` relance le collecteur.

## Paquets et applets utilisés

lighttpd (avec mbedTLS ; seuls `gen_key` et `cert_write` sont gardés parmi
les programmes de mbedTLS), ksmbd-tools, nfs-utils, mdadm. Le paquet active
dans busybox `ntpd` et le wget HTTPS (Telegram). Le reste est busybox
(`sh`, `awk`, `sed`, `hdparm`, `mkpasswd`, `start-stop-daemon`…).
`smartctl` n'est pas dans l'image : smartmontools demande une chaîne C++,
que ni la chaîne interne ni la chaîne précompilée n'ont.

## Essai sur le PC

    sh package/diet/tests/essai-api.sh

crée une racine factice (`DIET_RACINE`) avec `/proc`, `/sys` et `/etc`
simulés (RAID1 sain puis dégradé, drivetemp, ksmbd.conf, exports), remplace
les commandes du NAS par des scripts qui notent leurs arguments, appelle
l'API comme le ferait lighttpd et vérifie le JSON et les fichiers écrits.
`--servir` lance l'interface sur http://127.0.0.1:8080/ avec ces données
(busybox httpd de l'hôte).

## Limites connues

- L'API tourne en root (comme l'ancien DIET) : protégée par le mot de
  passe, le filtre des réseaux privés et l'en-tête `X-Diet` contre le CSRF.
- Le wget de busybox ne vérifie pas le certificat de Telegram.
- WebDAV : les fichiers sont créés par `nas` (pas par le compte qui se
  connecte) ; COPY/MOVE seulement à l'intérieur d'un même espace (dossier
  personnel ou partage) ; un client sur le NAS lui-même (127.0.0.1) ne peut
  pas faire de MOVE/COPY (schéma non transmis) ; la base des verrous est
  `/var/lib/lighttpd-webdav/webdav.db`. Le module rsync `[c]` (sur demande)
  écrit en root. Les dossiers
  MiniDLNA aux noms accentués ne sont pas acceptés par l'interface (les
  écrire à la main dans `/etc/minidlna.conf`) ; le nombre de fichiers
  indexés dépend du format de la page d'état de minidlnad.
- `/c` est monté par `S35stockage` (paquet xraid-compat, docs/XRAID.md) :
  X-RAID existant (lecture seule par défaut) ou md. Sans volume monté,
  l'interface ne crée pas de partage et affiche « non monté ».
