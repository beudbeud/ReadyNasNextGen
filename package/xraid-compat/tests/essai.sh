#!/bin/sh
# Essais de xraid-compat sur le PC, sans le NAS ni root : images disque X-RAID
# factices (fichiers creux, fabrique-images.py), xraid-info compilé pour l'hôte,
# nas-raid avec dmsetup/mdadm/lvm/fuse2fs/mount simulés (ils notent leurs
# arguments dans cmd.log). Aucun périphérique dm ou loop n'est créé.
#   sh package/xraid-compat/tests/essai.sh   (dash ; le busybox de l'hôte préfère
# ses propres applets, mount par exemple, aux commandes simulées)
set -u
ICI=$(cd "$(dirname "$0")" && pwd)
SRC=$ICI/../src
SH=${SH:-sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/xraid-essai.XXXXXX")
R=$T/racine
ECHECS=0; N=0
verifie() {	# verifie "description" condition-shell
	N=$((N + 1))
	if eval "$2"; then echo "ok   $1"; else echo "ÉCHEC $1"; ECHECS=$((ECHECS + 1)); fi
}
mkdir -p "$R/bin" "$R/proc" "$R/var/run" "$R/var/lib" "$R/etc/init.d"
cc -O2 -Wall -Werror -o "$R/bin/xraid-info" "$SRC/xraid-info.c" || exit 1
for s in propre grand sale degrade synchro different md; do
	python3 "$ICI/fabrique-images.py" "$T/$s" "$s" > /dev/null || exit 1
done

# ---------- xraid-info ----------
mode() { "$R/bin/xraid-info" --echantillons 32 "$T/$1"/*.img | sed -n "s/^XR_MODE='\(.*\)'/\1/p"; }
for c in propre:rw grand:rw sale:ro degrade:ro synchro:ro different:ro md:ro; do
	verifie "xraid-info : ${c%%:*} -> ${c#*:}" "[ \"\$(mode ${c%%:*})\" = ${c#*:} ]"
done
J=$("$R/bin/xraid-info" --json --echantillons 4 "$T"/grand/*.img)
js() { printf '%s' "$J" | python3 -c "import json,sys; j=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }
verifie "JSON : valide, V = 1 465 128 688 (750 Go)" "js 'j[\"v\"]==1465128688 and j[\"n\"]==1465149168'"
verifie "JSON : section 1 bornée à V (zone protégée exclue)" "js 'j[\"sections\"][1][\"debut\"]+j[\"sections\"][1][\"secteurs\"]==j[\"v\"] and j[\"sections\"][1][\"secteurs_declares\"]==1461032686'"
verifie "JSON : base = sdb (MBR), miroir = sda (sans MBR)" "js '[(d[\"role\"],d[\"mbr\"]) for d in j[\"disques\"]]==[(\"miroir\",0),(\"base\",1)]'"
verifie "JSON : p5 LVM à 4 608 040 = section 1 + 512 008" "js '[(p[\"num\"],p[\"type\"],p[\"section\"],p[\"decalage\"]) for p in j[\"partitions\"]][2]==(5,\"8e\",1,512008)'"
J=$("$R/bin/xraid-info" --json "$T"/degrade/sdb.img)
verifie "JSON : dégradé, raison disque_manquant, lecture sur la base" "js 'j[\"mode\"]==\"ro\" and j[\"raisons\"][0][\"code\"]==\"disque_manquant\" and j[\"lecture\"].endswith(\"sdb.img\")'"
"$R/bin/xraid-info" --echantillons 4 "$T"/sale/*.img > "$T/sale.txt"
verifie "texte : raison arret_brutal" "grep -q \"^XR_RAISONS='arret_brutal'\" '$T/sale.txt'"
verifie "texte : évaluable par sh" "(set -e; eval \"\$(cat '$T/sale.txt')\"; [ \"\$XR_V\" = 8368128 ])"
"$R/bin/xraid-info" verifier "$T"/propre/sdb.img "$T"/propre/sda.img > "$T/v1" 2>/dev/null; rc=$?
verifie "verifier : images identiques -> code 0" "[ $rc = 0 ] && grep -q \"RESULTAT='identiques'\" '$T/v1'"
"$R/bin/xraid-info" verifier "$T"/different/sdb.img "$T"/different/sda.img > "$T/v2" 2>/dev/null; rc=$?
verifie "verifier : un écart -> code 1, une zone" "[ $rc = 1 ] && grep -q 'ZONES_DIFFERENTES=1' '$T/v2'"
verifie "xraid-info n'ouvre rien en écriture (O_RDONLY seulement)" "! grep -q 'O_RDWR\|O_WRONLY' '$SRC/xraid-info.c'"
verifie "smart : refus propre sur une image (pas de SG_IO)" "! '$R/bin/xraid-info' smart '$T/propre/sda.img' 2>/dev/null"

# ---------- nas-raid avec commandes simulées ----------
stub() { printf '#!/bin/sh\necho "%s $*" >> "%s/cmd.log"\n%s\n' "$1" "$T" "${2:-}" > "$R/bin/$1"; chmod 755 "$R/bin/$1"; }
for c in dmsetup lvm fuse2fs umount rsync partprobe logger mkfs.ext4 resize2fs; do stub $c; done
stub mdadm
stub mount 'echo "/dev/x $3 ext4 rw 0 0" >> "'"$R"'/proc/mounts"'
: > "$R/proc/mounts"
printf 'Personalities : [raid1]\nmd11 : active raid1 dm-3[1] dm-2[0]\n      100 blocks [2/2] [UU]\n' > "$R/proc/mdstat"
export NAS_RAID_RACINE=$R
nr0() { NAS_RAID_DISQUES="$DISQ" $SH "$SRC/nas-raid" "$@"; }
DISQ="$T/grand/sda.img $T/grand/sdb.img"; : > "$T/cmd.log"; nr0 monter 2>/dev/null >/dev/null
verifie "XRAID_RW=non (défaut) : lecture seule même si sain" "grep -q 'xraid-ro rw_desactive' '$R/var/run/nas-raid.mode' && ! grep -q mdadm '$T/cmd.log'"
nr0 demonter 2>/dev/null >/dev/null
echo XRAID_RW=oui > "$R/etc/nas-raid.conf"
nr() { NAS_RAID_DISQUES="$DISQ" $SH "$SRC/nas-raid" "$@"; }
etat_mode() { cut -d' ' -f1 "$R/var/run/nas-raid.mode"; }
# toute table dm sur une image doit finir avant V (zone protégée intacte)
dans_v() {
	awk -v v="$1" '/^dmsetup create/ { for (i = 1; i <= NF; i++) if ($i == "linear" && $(i+1) ~ /\.img$/) { gsub(/'"'"'/, "", $(i+2)); if ($(i+2) + $(i-1) > v) bad = 1 } } END { exit bad }' "$T/cmd.log"
}

DISQ="$T/grand/sda.img $T/grand/sdb.img"
: > "$T/cmd.log"; nr monter 2>/dev/null >/dev/null
verifie "monter (propre) : xraid-rw" "[ \"\$(etat_mode)\" = xraid-rw ]"
verifie "monter : mdadm --build RAID 1 sans superbloc, base en premier" "grep -q 'mdadm --build /dev/md11 --level=1 --raid-devices=2 --assume-clean /dev/mapper/xr-a-s1 /dev/mapper/xr-b-s1' '$T/cmd.log'"
verifie "monter : p5 projetée sur md11 à 512008" "grep -q \"dmsetup create xr-p5 --table 0 1460504296 linear /dev/md11 512008\" '$T/cmd.log'"
verifie "monter : aucune table au-delà de V" "dans_v 1465128688"
verifie "monter : LVM métadonnées en lecture seule, fuse2fs rw" "grep -q 'metadata_read_only = 1' '$T/cmd.log' && grep -q 'fuse2fs -o allow_other /dev/mapper/c-c /c' '$T/cmd.log'"
verifie "monter : marque xraid-sale posée" "[ -e '$R/var/lib/nas-raid/xraid-sale' ]"
verifie "monter : jamais d'écriture directe (dd)" "! grep -q '^dd' '$T/cmd.log'"
echo "/dev/mapper/c-c /c fuse rw 0 0" > "$R/proc/mounts"
nr demonter 2>/dev/null >/dev/null
verifie "demonter : md arrêtés, marque retirée" "grep -q 'mdadm --stop /dev/md11' '$T/cmd.log' && [ ! -e '$R/var/lib/nas-raid/xraid-sale' ]"
# coupure de courant sous Linux : la marque reste
echo 1 > "$R/var/lib/nas-raid/xraid-sale"; : > "$T/cmd.log"
nr monter 2>/dev/null >/dev/null
verifie "après coupure : lecture seule (arret_brutal_linux)" "grep -q 'xraid-ro arret_brutal_linux' '$R/var/run/nas-raid.mode'"
verifie "lecture seule : dm --readonly sur la base, LVM read_only_volume_list, fuse2fs ro" "grep -q 'dmsetup create xr-p5 --readonly --table 0 1460504296 linear .*grand/sdb.img 4608040' '$T/cmd.log' && grep -q 'read_only_volume_list' '$T/cmd.log' && grep -q 'fuse2fs -o ro,allow_other' '$T/cmd.log'"
verifie "lecture seule : pas de md" "! grep -q 'mdadm' '$T/cmd.log'"
DISQ="$T/propre/sda.img $T/propre/sdb.img"
nr verifier 2>/dev/null
verifie "verifier (propre) : marque retirée après comparaison complète" "[ ! -e '$R/var/lib/nas-raid/xraid-sale' ] && grep -q '^ok ' '$R/var/lib/nas-raid/verif.etat'"
# X-RAID arrêté brutalement sous RAIDiator : ro, puis rw après une vérification réussie
DISQ="$T/sale/sda.img $T/sale/sdb.img"; rm -f "$R/var/lib/nas-raid/xraid-verifie"
nr monter 2>/dev/null >/dev/null
verifie "superbloc sale : lecture seule" "grep -q 'xraid-ro arret_brutal' '$R/var/run/nas-raid.mode'"
nr verifier 2>/dev/null; nr monter 2>/dev/null >/dev/null
verifie "superbloc sale vérifié : rw (arret_brutal_verifie)" "grep -q 'xraid-rw arret_brutal_verifie' '$R/var/run/nas-raid.mode'"
rm -f "$R/var/lib/nas-raid/xraid-sale"
DISQ="$T/degrade/sdb.img"; : > "$T/cmd.log"
nr monter 2>/dev/null >/dev/null
verifie "dégradé : lecture seule sur le disque présent" "grep -q 'xraid-ro disque_manquant' '$R/var/run/nas-raid.mode' && ! grep -q mdadm '$T/cmd.log'"
DISQ="$T/different/sda.img $T/different/sdb.img"
nr monter 2>/dev/null >/dev/null
verifie "miroir différent : lecture seule" "grep -q 'xraid-ro miroir_different' '$R/var/run/nas-raid.mode'"
nr reparer 2>/dev/null >/dev/null; rc=$?
verifie "reparer : refusé sans confirmation" "[ $rc != 0 ]"
DISQ="$T/synchro/sda.img $T/synchro/sdb.img"
nr monter 2>/dev/null >/dev/null
verifie "synchronisation inachevée : lecture seule" "grep -q 'xraid-ro synchro_en_cours' '$R/var/run/nas-raid.mode'"

# ---------- migration et md ----------
DISQ="$T/grand/sda.img $T/grand/sdb.img"; rm -f "$R/var/lib/nas-raid/verif.etat"
: > "$T/cmd.log"; nr migrer --confirmer MIGRER --oui > "$T/m0" 2>&1; rc=$?
verifie "migrer : refusé sans vérification complète" "[ $rc != 0 ] && grep -q 'vérification complète' '$T/m0' && [ ! -s '$T/cmd.log' ]"
echo "ok $(date +%s)" > "$R/var/lib/nas-raid/verif.etat"
nr migrer --confirmer MIGRER --oui > "$T/m1" 2>&1; rc=$?
verifie "migrer : refusé si SMART illisible" "[ $rc != 0 ] && grep -q 'SMART illisible' '$T/m1' && [ ! -s '$T/cmd.log' ]"
echo "health=PASSED realloc=0 pending=3 uncorr=0 hours=1" > "$R/var/run/smart.sdb.img"
echo "health=PASSED realloc=0 pending=0 uncorr=0 hours=1" > "$R/var/run/smart.sda.img"
nr migrer --confirmer MIGRER --oui > "$T/m2" 2>&1; rc=$?
verifie "migrer : refusé si secteurs en attente" "[ $rc != 0 ] && grep -q 'en attente' '$T/m2'"
echo "health=PASSED realloc=0 pending=0 uncorr=0 hours=1" > "$R/var/run/smart.sdb.img"
nr migrer --oui > "$T/m3" 2>&1; rc=$?
verifie "migrer : refusé sans la phrase de confirmation" "[ $rc != 0 ] && grep -q \"confirmation requise : --confirmer 'MIGRER' --oui\" '$T/m3' && [ ! -s '$T/cmd.log' ]"
avant=$(ls -l --time-style=+%s "$T"/grand/*.img | md5sum)
nr migrer --a-blanc > "$T/m4" 2>&1; rc=$?
verifie "migrer à blanc : réussit sans rien exécuter" "[ $rc = 0 ] && [ ! -s '$T/cmd.log' ] && [ \"\$(ls -l --time-style=+%s '$T'/grand/*.img | md5sum)\" = '$avant' ] && [ ! -e '$R/var/lib/nas-raid/migration' ]"
verifie "migrer à blanc : efface le miroir sda, md dégradé, ext4 4 Kio" "grep -q '^+ dd if=/dev/zero of=.*grand/sda.img bs=512 seek=1465145072 count=4096' '$T/m4' && grep -q 'mdadm --create /dev/md/donnees .*sda.img missing' '$T/m4' && grep -q 'mkfs.ext4 -b 4096' '$T/m4'"
verifie "migrer à blanc : copie depuis le X-RAID en lecture seule sur sdb" "grep -q 'xr-p5 --readonly .*grand/sdb.img 4608040' '$T/m4' && grep -q 'rsync -aH --numeric-ids --delete /c/ /mnt/md/' '$T/m4'"
verifie "migrer à blanc : n'efface jamais la base avant --finaliser" "! grep -q 'of=.*grand/sdb.img' '$T/m4'"
nr migrer --finaliser --a-blanc > "$T/m5" 2>&1
verifie "finaliser à blanc : efface sdb puis l'ajoute au md" "grep -q 'of=.*grand/sdb.img bs=1048576' '$T/m5' && grep -q 'mdadm /dev/md/donnees --add .*grand/sdb.img' '$T/m5'"
nr creer "$T/grand/sda.img" "$T/grand/sdb.img" --a-blanc > "$T/c1" 2>&1
verifie "creer à blanc : RAID 1 sur les deux disques" "grep -q 'mdadm --create /dev/md/donnees .*sda.img .*sdb.img$' '$T/c1'"
nr creer /dev/sdz --confirmer 'EFFACER sdz' --oui > "$T/c2" 2>&1; rc=$?
verifie "creer : refuse un disque qui n'est pas SATA" "[ $rc != 0 ] && grep -q \"n'est pas un disque SATA\" '$T/c2'"
nr agrandir --a-blanc > "$T/g1" 2>&1
verifie "agrandir à blanc : md, pvresize, lvextend, resize2fs" "grep -q 'mdadm --grow /dev/md/donnees --size=max' '$T/g1' && grep -q 'pvresize' '$T/g1' && grep -q 'resize2fs /dev/mapper/donnees-c' '$T/g1'"
DISQ="$T/md/sda.img $T/md/sdb.img"; : > "$T/cmd.log"
nr monter 2>/dev/null >/dev/null
verifie "disque md (déjà migré) : assemblage md et ext4 sur /c" "[ \"\$(etat_mode)\" = md ] && grep -q 'mdadm --assemble --scan' '$T/cmd.log' && grep -q 'mount -t ext4 /dev/mapper/donnees-c /c' '$T/cmd.log'"
nr etat --json --rafraichir > "$T/e1"
verifie "etat --json : valide, mode md" "python3 -c \"import json; j=json.load(open('$T/e1')); assert j['mode']=='md' and j['xraid']['mode']=='ro'\""

echo "$N essais, $ECHECS échec(s) ; fichiers dans $T"
[ $ECHECS -eq 0 ] && rm -rf "$T"
exit $ECHECS
