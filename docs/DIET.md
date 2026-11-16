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
| Stockage | X-RAID (`/proc/xraid`), LVM `/dev/c/c` | md (`/proc/mdstat`, `mdadm --detail`), `df /c`, disques libata `sda`/`sdb` (baie = port ata) |
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
- Rien ne monte `/c` pour l'instant : sans volume monté, l'interface ne
  crée pas de partage et l'onglet Stockage affiche « non monté ».
