# ReadyNasNextGen

Un système récent pour redonner vie au **NETGEAR ReadyNAS Duo v1** : Linux 6.18, partage
de fichiers Windows/macOS (SMB) et Linux (NFS), interface web d'administration, sans toucher
au firmware d'origine.

> **Projet expérimental.** Il démarre et sert des fichiers, mais il se lance encore depuis un
> PC à chaque démarrage (voir [Limites](#limites-actuelles)). Gardez une sauvegarde de vos
> données.

## Ce que vous obtenez

- **Partages réseau** : SMB 3 (Windows, macOS, Linux, via ksmbd) et NFS v3/v4.
- **Interface web** en HTTPS (français, allemand, anglais), dérivée de
  [DIET](https://github.com/mfe-/ReadyNASDuoSparc) : état du NAS, disques, partages,
  utilisateurs, services, journaux.
- **Services** : MiniDLNA (télévisions, lecteurs multimédia), découverte automatique sur le
  réseau (`<nom>.local`), rsync et WebDAV par utilisateur.
- **Vos disques X-RAID existants** sont repris tels quels, en lecture seule par défaut ; un
  nouveau RAID peut être créé en RAID1 Linux standard (md).
- **Ventilateur régulé** selon la température : le NAS reste silencieux au repos.
- Le **firmware d'origine reste intact** : un redémarrage normal relance RAIDiator ou DIET.

## Matériel nécessaire

- Un **ReadyNAS Duo v1** (processeur SPARC Infrant ; le Duo v2 est un autre matériel).
- Une **clé USB** d'au moins 1 Go, branchée sur le NAS.
- Un **adaptateur USB-série 3,3 V** relié au connecteur série interne du NAS (9600 bauds).
- Un **PC Linux** sur le même réseau, avec Docker (serveur TFTP) et de quoi construire le
  système (voir [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#construire), ~15 Go libres).

## Installation

1. **Construire le système** sur le PC :
   ```sh
   git clone --recursive https://github.com/beudbeud/ReadyNasNextGen.git
   cd ReadyNasNextGen
   make rapide        # télécharge la chaîne de compilation précompilée, puis construit
   ```
   Résultat dans `output-rapide/images/` : `vmlinux.k3` (le noyau) et `rootfs.tar` (le système).

2. **Préparer la clé USB** : une partition ext4 (ou ext3), puis, en root, extraire le
   système dans un dossier `rootfs-6.18` à sa racine :
   ```sh
   mount /dev/sdX1 /mnt
   mkdir /mnt/rootfs-6.18
   tar -xpf output-rapide/images/rootfs.tar -C /mnt/rootfs-6.18
   umount /mnt
   ```
   Branchez la clé sur le NAS.

3. **Démarrer le NAS sur le nouveau système** : lancez le serveur TFTP
   (`tools/tftp-server.sh output-rapide/images`), ouvrez la console série, allumez le NAS et
   interrompez `iboot` au démarrage. À l'invite `iboot>` :
   ```
   tftp <MAC-du-NAS> <IP-du-NAS> <IP-du-PC> vmlinux.k3 0x80004000
   go 0x80004000
   ```
   `tools/iboot-cmd.py` fait ces étapes automatiquement. Le système démarre en quelques
   secondes sur la clé.

4. **Premier accès** : connectez-vous en SSH (`ssh root@<IP-du-NAS>`), choisissez le mot de
   passe de l'interface avec `diet-webpass`, puis ouvrez `https://<IP-du-NAS>/` (utilisateur
   `admin` ; acceptez le certificat auto-signé).

## Vos données (X-RAID)

Les disques formatés par le firmware d'origine (X-RAID) sont reconnus et montés dans `/c`
**en lecture seule** par défaut : rien n'est écrit sur vos données. Avant tout montage, le
système vérifie l'état du miroir (disque en panne, arrêt brutal, superblocs différents,
synchronisation inachevée) et refuse en cas de doute.

L'écriture sur un volume X-RAID et la migration vers un RAID1 Linux standard sont possibles ;
elles sont décrites, avec leurs précautions, dans [docs/XRAID.md](docs/XRAID.md).

## Limites actuelles

- **Démarrage depuis le PC** : à chaque démarrage, il faut l'adaptateur série et le serveur
  TFTP. Le démarrage autonome (sans PC) est à l'étude.
- **Montage du volume X-RAID** : en cours de correction (outil LVM), le stockage peut
  apparaître absent.
- Pas d'horloge sauvegardée : au démarrage, mettez l'heure à jour par le réseau (bouton
  « Mettre l'heure à jour » de l'interface).

## Revenir au système d'origine

Il suffit de redémarrer le NAS normalement : le firmware d'origine démarre depuis sa mémoire
flash, que ce projet ne modifie jamais.

**Ne jamais écrire dans la flash** (commandes d'écriture NAND d'`iboot`, `/dev/mtd*`) : une
flash corrompue rend le NAS inutilisable sans matériel de récupération.

## Pour aller plus loin

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) : construction, chaîne de compilation, état
  détaillé du portage, paramètres du noyau, arborescence.
- [docs/DIET.md](docs/DIET.md) : l'interface web et ses différences avec DIET.
- [docs/XRAID.md](docs/XRAID.md) : reprise des disques X-RAID, écriture, migration vers md.
- [FEASIBILITY.md](FEASIBILITY.md) : étude de départ.

## Crédits et licences

- Noyau, pilotes et scripts : **GPL-2.0** (voir `LICENSE`), écrits d'après les sources GPL du
  noyau 2.6.17 publiées par NETGEAR ; le micrologiciel du coprocesseur LP
  (`arch/sparc/kernel/padre_lpram.c`) provient de ces mêmes sources GPL.
- Interface web : dérivée de [DIET](https://github.com/mfe-/ReadyNASDuoSparc) de davemmi
  (support du Duo v1 : [mfe-/ReadyNASDuoSparc#16](https://github.com/mfe-/ReadyNASDuoSparc/pull/16)).
  Le dépôt d'origine ne déclare aucune licence : ce code n'est donc **pas** sous la GPL-2.0 de
  ce dépôt (voir [docs/DIET.md](docs/DIET.md#origine-et-licence)).
- `readynas_crypto` : GPL-2.0+ (Henrik Nordström) ; `des.c` : LGPL-2.1 (Christophe Devine).
- Buildroot, Linux et les paquets construits gardent leurs propres licences.

Aucun binaire ni code propriétaire Infrant/NETGEAR n'est inclus.
