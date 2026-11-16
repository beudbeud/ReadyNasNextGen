#!/bin/sh
# Essai de l'API DIET sur le PC, sans le NAS : racine factice (DIET_RACINE)
# avec /proc, /sys, /etc et /var simulés, commandes du NAS remplacées par des
# scripts qui notent leurs arguments. Vérifie le JSON (python3) et les fichiers.
#   sh package/diet/tests/essai-api.sh            essais (dash ; pas en root)
# NB : le busybox de l'hôte préfère ses propres applets aux commandes simulées
# (pidof, ifconfig, hostname…) ; c'est pourquoi les essais passent par dash.
#   sh package/diet/tests/essai-api.sh --servir   interface sur http://127.0.0.1:8080/
#                                                 (busybox httpd, données simulées)
set -u
ICI=$(cd "$(dirname "$0")" && pwd)
SRC=$ICI/../src
BOARD=$ICI/../../../board/readynas-duo-v1/rootfs-overlay
SH=${SH:-sh}
R=$(mktemp -d "${TMPDIR:-/tmp}/diet-essai.XXXXXX")
export DIET_RACINE="$R"
ECHECS=0; N=0

# ---------- racine factice ----------
mkdir -p "$R"/bin "$R"/etc/init.d "$R"/etc/ksmbd "$R"/etc/network "$R"/var/run "$R"/var/log "$R"/c \
	"$R"/proc/sys/kernel "$R"/proc/sys/dev/boot "$R"/proc/net "$R"/proc/fs/nfsd
cp "$SRC"/etc/diet-lang.sh "$SRC"/etc/diet.conf "$BOARD"/etc/ventilateur.conf "$BOARD"/etc/exports "$R"/etc/
cp "$BOARD"/etc/ksmbd/ksmbd.conf "$R"/etc/ksmbd/
# services : MiniDLNA, rsync, annonces Avahi, lighttpd (WebDAV inclus à part)
mkdir -p "$R"/etc/lighttpd "$R"/etc/avahi "$R"/var/run/minidlna "$R"/var/run/avahi-daemon "$R"/var/lib/minidlna
cp "$BOARD"/etc/minidlna.conf "$BOARD"/etc/rsyncd.conf "$R"/etc/
cp -R "$BOARD"/etc/avahi/services "$R"/etc/avahi/
cp "$SRC"/etc/lighttpd/lighttpd.conf "$SRC"/etc/lighttpd/webdav.conf "$R"/etc/lighttpd/
cp "$BOARD"/etc/rsyncd.conf "$R"/etc/
head -c 2048 /dev/zero > "$R"/var/lib/minidlna/files.db
echo $$ > "$R"/var/run/minidlna/minidlna.pid
echo fr > "$R"/etc/diet-lang
echo readynas > "$R"/etc/hostname
printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/home:/bin/false\n' > "$R"/etc/passwd
printf 'root:x:0:\nusers:x:100:\nnobody:x:65534:\n' > "$R"/etc/group
echo readynas > "$R"/proc/sys/kernel/hostname
echo '12345.67 20000.00' > "$R"/proc/uptime
echo '0.10 0.20 0.30 1/50 999' > "$R"/proc/loadavg
printf 'model: ReadyNAS Duo\n' > "$R"/proc/sys/dev/boot/info
printf 'MemTotal: 255000 kB\nMemFree: 100000 kB\nMemAvailable: 180000 kB\nBuffers: 1000 kB\nCached: 50000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$R"/proc/meminfo
printf 'cpu  100 0 50 1000 10 0 5 0\n' > "$R"/proc/stat
printf 'Inter-|\n face |\n  eth0: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n' > "$R"/proc/net/dev
printf '   8       0 sda 10 0 800 0 5 0 400 0 0 0 0\n   8      16 sdb 10 0 800 0 5 0 400 0 0 0 0\n' > "$R"/proc/diskstats
printf '/dev/root / ext4 rw 0 0\n/dev/md0 /c ext4 rw 0 0\n' > "$R"/proc/mounts
echo 8 > "$R"/proc/fs/nfsd/threads
for d in sda:38000 sdb:41000; do
	mkdir -p "$R/sys/block/${d%%:*}/device/hwmon/hwmon0"
	echo "DISQUE-ESSAI ${d%%:*}" > "$R/sys/block/${d%%:*}/device/model"
	echo 3907029168 > "$R/sys/block/${d%%:*}/size"
	echo "${d#*:}" > "$R/sys/block/${d%%:*}/device/hwmon/hwmon0/temp1_input"
done
SAIN='Personalities : [raid1]
md0 : active raid1 sdb1[1] sda1[0]
      1953382464 blocks super 1.2 [2/2] [UU]

unused devices: <none>'
DEGRADE='Personalities : [raid1]
md0 : active raid1 sdb1[1](F) sda1[0]
      1953382464 blocks super 1.2 [2/1] [U_]
      [=>...................]  recovery =  7.5% (146503680/1953382464) finish=300.1min speed=100000K/sec

unused devices: <none>'
echo "$SAIN" > "$R"/proc/mdstat
echo "temp=45 disques=41 fan=1800 pwm=120" > "$R"/var/run/ventilateur.etat
echo $$ > "$R"/var/run/ventilateur.pid
echo "INVALIDE" > "$R"/var/run/diet-hwmon.pid

# ---------- commandes simulées (notent leurs arguments dans cmd.log) ----------
stub() { printf '#!/bin/sh\necho "%s $*" >> "$DIET_RACINE/cmd.log"\n%s\n' "$1" "${2:-}" > "$R/bin/$1"; chmod 755 "$R/bin/$1"; }
stub ifconfig 'echo "eth0 Link encap:Ethernet"; echo "  inet addr:10.0.0.2  Bcast:10.0.0.255  Mask:255.255.255.0"'
stub route 'printf "Kernel\nDestination Gateway\n0.0.0.0 10.0.0.1 0.0.0.0 UG 0 0 0 eth0\n"'
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/md0 1922000000 922000000 1000000000 48% /c"'
stub pidof 'case "$1" in ksmbd.mountd|dropbear|lighttpd) echo 123;; *) exit 1;; esac'
stub ksmbd.control
stub exportfs
stub hdparm
stub hostname 'echo readynas'
stub mdadm 'echo "/dev/md0: simulé"; echo "  State : clean"'
stub dmesg 'echo "[    1.0] sd 0:0:0:0: [sda] 3907029168 512-byte logical blocks"'
# wget : Telegram, ou page d'état de minidlnad (nombres de fichiers)
stub wget 'case "$*" in *127.0.0.1:8200*) echo "<tr><td>Audio files</td><td>12</td></tr><tr><td>Video files</td><td>3</td></tr><tr><td>Image files</td><td>40</td></tr>";; *) echo "{\"ok\":true}";; esac'
stub start-stop-daemon
stub lighttpd '[ ! -e "$DIET_RACINE/lighttpd.ko" ]'
stub chown
# mkpasswd -m sha512 -S sel -P 0 : mot de passe lu sur l'entrée standard (vraie empreinte SHA-512)
stub mkpasswd 'IFS= read -r p; printf "%s" "$p" | openssl passwd -6 -stdin'
# ksmbd.adduser : mot de passe lu sur l'entrée standard, noté dans motdepasse.log
cat > "$R"/bin/ksmbd.adduser <<'EOF'
#!/bin/sh
echo "ksmbd.adduser $*" >> "$DIET_RACINE/cmd.log"
db=""; del=""
while [ $# -gt 1 ]; do case "$1" in -P) db=$2; shift;; -C) shift;; -d) del=1;; esac; shift; done
if [ -n "$del" ]; then grep -v "^$1:" "$db" > "$db.t"; mv "$db.t" "$db"
else IFS= read -r p1; IFS= read -r p2; [ "$p1" = "$p2" ] || exit 1; printf '%s' "$p1" > "$DIET_RACINE/motdepasse.log"; echo "$1:SIMULE" >> "$db"; fi
EOF
chmod 755 "$R"/bin/ksmbd.adduser
for s in S45ventilateur S60nfs S70ksmbd S95diet S50avahi-daemon S51webdav S60minidlnad S61rsyncd; do
	printf '#!/bin/sh\necho "%s $*" >> "$DIET_RACINE/cmd.log"\n' "$s" > "$R/etc/init.d/$s"; chmod 755 "$R/etc/init.d/$s"
done
for s in diet-notify diet-alerts; do ln -s "$SRC/usr/sbin/$s" "$R/bin/$s"; done

if [ "${1:-}" = --servir ]; then
	echo "Racine factice : $R ; interface : http://127.0.0.1:8080/ (Ctrl-C pour arrêter)"
	exec busybox httpd -f -p 127.0.0.1:8080 -h "$SRC/www"
fi

# ---------- outils d'essai ----------
# api MÉTHODE requête [corps] [X-Diet] : sortie sans en-têtes dans $OUT, statut dans $ST
api() {
	corps=${3:-}
	brut=$(printf '%s' "$corps" | REQUEST_METHOD=$1 QUERY_STRING="$2&l=fr" CONTENT_LENGTH=${#corps} \
		HTTP_X_DIET=${4-1} REMOTE_ADDR=10.0.0.9 $SH "$SRC/www/cgi-bin/api")
	ST=$(printf '%s\n' "$brut" | sed -n 's/^Status: \([0-9]*\).*/\1/p' | head -n 1); ST=${ST:-200}
	OUT=$(printf '%s\n' "$brut" | tr -d '\r' | sed '1,/^$/d')
}
verifie() {	# verifie "description" condition-shell
	N=$((N + 1))
	if eval "$2"; then echo "ok   $1"; else echo "ÉCHEC $1"; ECHECS=$((ECHECS + 1)); fi
}
json() {	# json 'expression python sur j' : vrai si l'expression est vraie
	printf '%s' "$OUT" | python3 -c "import json,sys; j=json.load(sys.stdin); sys.exit(0 if ($1) else 1)" 2>/dev/null
}
enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote_plus(sys.argv[1]))' "$1"; }

# ---------- état ----------
api GET a=status
verifie "status : JSON valide" "json 'True'"
verifie "status : RAID1 sain UU" "json 'j[\"md\"][0][\"map\"]==\"UU\" and j[\"md\"][0][\"level\"]==\"raid1\"'"
verifie "status : 2 disques, drivetemp, baies" "json '[d[\"temp\"] for d in j[\"disks\"]]==[38,41] and [d[\"bay\"] for d in j[\"disks\"]]==[1,2]'"
verifie "status : ventilateur (padre-ventilateur)" "json 'j[\"temp\"]==45 and j[\"fan\"]==1800 and j[\"pwm\"]==120 and j[\"svc\"][\"fan\"]==1'"
verifie "status : services" "json 'j[\"svc\"][\"ksmbd\"]==1 and j[\"svc\"][\"nfs\"]==1 and j[\"svc\"][\"ntpd\"]==0 and j[\"svc\"][\"hwmon\"]==0'"
verifie "status : /c et mémoire" "json 'j[\"c\"][\"size\"]==1922000000 and j[\"mem\"][\"avail\"]==180000 and j[\"ip\"]==\"10.0.0.2\"'"
echo "$DEGRADE" > "$R"/proc/mdstat
api GET a=status
verifie "status dégradé : U_, sdb en panne, resynchro" "json 'j[\"md\"][0][\"map\"]==\"U_\" and j[\"disks\"][1][\"faulty\"]==1 and j[\"disks\"][0][\"faulty\"]==0 and \"recovery\" in j[\"md\"][0][\"sync\"]'"
A=$($SH "$SRC"/usr/sbin/diet-alerts)
verifie "diet-alerts : RAID dégradé + disque en panne" 'case "$A" in *"RAID dégradé (md0)"*"disque en panne dans le RAID (sdb1)"*) true;; *) false;; esac'
echo "$SAIN" > "$R"/proc/mdstat
verifie "diet-alerts : rien si sain" '[ -z "$($SH "$SRC"/usr/sbin/diet-alerts)" ]'

# ---------- réglages matériels ----------
api GET a=config
verifie "config : lit ventilateur.conf et diet.conf" "json 'j[\"FAN_PWM_MIN\"]==50 and j[\"PERIODE\"]==60 and j[\"SPINDOWN_MIN\"]==30'"
api POST a=config 'FAN_PWM_MIN=60&TEMP_HIGH=52&SPINDOWN_MIN=10'
verifie "config : enregistré (200)" '[ "$ST" = 200 ]'
verifie "config : ventilateur.conf modifié, commentaire gardé" 'grep -q "^FAN_PWM_MIN=60 .*# consigne" "$R"/etc/ventilateur.conf && grep -q "^TEMP_HIGH=52" "$R"/etc/ventilateur.conf'
verifie "config : padre-ventilateur relancé, veille appliquée" 'grep -q "S45ventilateur restart" "$R"/cmd.log && grep -q "hdparm -S 120 /dev/sda" "$R"/cmd.log'
api POST a=config 'FAN_PWM_MIN=5'
verifie "config : minimum trop bas refusé (400)" '[ "$ST" = 400 ]'
api POST a=config 'PERIODE=600'
verifie "config : période > 240 s refusée" '[ "$ST" = 400 ]'

# ---------- partages SMB ----------
api GET a=shares
verifie "shares : [c] seul, pas [global]" "json 'j==[{\"name\":\"c\",\"path\":\"/c\",\"ro\":0,\"guest\":0,\"exists\":1}]'"
api POST a=share_add 'name=photos'
verifie "share_add : section, dossier, rechargement ksmbd" 'grep -q "^\[photos\]" "$R"/etc/ksmbd/ksmbd.conf && [ -d "$R"/c/photos ] && grep -q "ksmbd.control -r" "$R"/cmd.log'
api POST a=share_add 'name=photos'
verifie "share_add : doublon refusé (409)" '[ "$ST" = 409 ]'
api POST a=share_add 'name=global'
verifie "share_add : nom réservé refusé" '[ "$ST" = 400 ]'
api POST a=share_add 'name=a%2Fb'
verifie "share_add : caractères interdits refusés" '[ "$ST" = 400 ]'
api POST a=share_set 'name=photos&ro=1&guest=0'
api GET a=shares
verifie "share_set : lecture seule, avec compte" "json '[s for s in j if s[\"name\"]==\"photos\"][0][\"ro\"]==1 and [s for s in j if s[\"name\"]==\"photos\"][0][\"guest\"]==0'"
api POST a=share_del 'name=photos'
api GET a=shares
verifie "share_del : retiré, dossier gardé" "json 'len(j)==1' && [ -d \"\$R\"/c/photos ]"

# ---------- utilisateurs (SMB, WebDAV, rsync : même mot de passe) ----------
E=$R/etc
PW='s3cret é+&%x'
api POST a=user_set "name=alice&pw=$(enc "$PW")"
verifie "user_set : compte créé (uid 1000, groupe personnel alice, membre nas)" 'grep -q "^alice:x:1000:1000:" "$E"/passwd && grep -qx "alice:x:1000:nas" "$E"/group'
verifie "user_set : mot de passe décodé passé sur stdin, jamais journalisé" '[ "$(cat "$R"/motdepasse.log)" = "$PW" ] && ! grep -q "s3cret" "$R"/cmd.log "$R"/var/log/diet.log'
verifie "user_set : WebDAV (htpasswd-users SHA-512, 640, root:nas)" 'grep -q "^alice:[\$]6[\$]" "$E"/lighttpd/htpasswd-users && [ "$(stat -c %a "$E"/lighttpd/htpasswd-users)" = 640 ] && grep -q "chown root:nas $E/lighttpd/htpasswd-users" "$R"/cmd.log'
verifie "user_set : rsync (rsyncd.secrets 600)" 'grep -qxF "alice:$PW" "$E"/rsyncd.secrets && [ "$(stat -c %a "$E"/rsyncd.secrets)" = 600 ]'
verifie "user_set : dossier personnel 2770 à alice" '[ "$(stat -c %a "$R"/c/home/alice)" = 2770 ] && grep -q "chown alice:alice $R/c/home/alice" "$R"/cmd.log'
verifie "rsyncd.conf : module [alice] (uid/gid alice, auth alice), pas de [c]" 'awk "/^\[alice\]/,0" "$E"/rsyncd.conf | grep -q "uid = alice" && grep -q "auth users = alice" "$E"/rsyncd.conf && grep -q "path = /c/home/alice" "$E"/rsyncd.conf && ! grep -q "^\[c\]" "$E"/rsyncd.conf'
verifie "webdav.conf : /webdav/alice pour alice seule, vérifié (-tt), instance relancée" 'grep -q "\"require\" => \"user=alice\"" "$E"/lighttpd/webdav.conf && grep -q "\"/webdav/alice\" => \"/c/home/alice\"" "$E"/lighttpd/webdav.conf && grep -q "lighttpd -tt -f $E/lighttpd/webdav.conf.tmp" "$R"/cmd.log && grep -q "S51webdav restart" "$R"/cmd.log && grep -q "server.username = \"nas\"" "$E"/lighttpd/webdav.conf'
api GET a=users
verifie "users : alice avec mots de passe SMB et WebDAV/rsync" "json 'j==[{\"name\":\"alice\",\"uid\":1000,\"smb\":1,\"dav\":1}]'"
api POST a=share_add 'name=commun'
verifie "share_add : partage root:users 2777, module rsync et WebDAV pour les comptes" '[ "$(stat -c %a "$R"/c/commun)" = 2777 ] && grep -q "chown root:users $R/c/commun" "$R"/cmd.log && awk "/^\[commun\]/,0" "$E"/rsyncd.conf | grep -q "uid = nas" && grep -q "\"/webdav/commun\" => \"/c/commun\"" "$E"/lighttpd/webdav.conf'
api POST a=share_set 'name=commun&ro=1&guest=0'
verifie "share_set lecture seule : plus de module rsync, WebDAV en lecture seule" '! grep -q "^\[commun\]" "$E"/rsyncd.conf && awk "/webdav.commun/,0" "$E"/lighttpd/webdav.conf | grep -q "is-readonly = \"enable\""'
# compte créé avant (groupe users, sans WebDAV/rsync) : à redéfinir
echo "carol:x:1001:100::/c/home/carol:/bin/false" >> "$E"/passwd
api GET a=users
verifie "users : compte ancien sans WebDAV/rsync (dav 0)" "json '[u[\"dav\"] for u in j]==[1,0]'"
api POST a=user_set "name=carol&pw=$(enc carol-2026)"
verifie "user_set compte ancien : groupe personnel, WebDAV/rsync activés" 'grep -q "^carol:x:1001:1001:" "$E"/passwd && grep -qx "carol:x:1001:nas" "$E"/group && grep -q "^carol:" "$E"/lighttpd/htpasswd-users && grep -q "^\[carol\]" "$E"/rsyncd.conf'
api POST a=share_set 'name=commun&ro=0&guest=0'
verifie "share_set écriture : module rsync du partage pour tous les comptes" 'awk "/^\[commun\]/,0" "$E"/rsyncd.conf | grep -q "auth users = alice,carol"'
api POST a=user_set 'name=root&pw=abcdefgh'
verifie "user_set : compte système refusé (403)" '[ "$ST" = 403 ]'
api POST a=user_set 'name=bob&pw=abc'
verifie "user_set : mot de passe trop court refusé" '[ "$ST" = 400 ] && ! grep -q "^bob:" "$E"/passwd'
for n in sauvegarde nas c a%2Fb "$(enc 'x"y')" "$(enc 'x y')" -x "$(enc 'x/../y')" "$(enc 'x]
[c')"; do
	api POST a=user_set "name=$n&pw=abcdefgh"
	verifie "user_set : nom dangereux ou réservé « $n » refusé" '[ "$ST" = 400 ]'
done
echo "video:x:28:" >> "$E"/group
api POST a=user_set 'name=video&pw=abcdefgh'
verifie "user_set : nom d’un groupe système refusé (409)" '[ "$ST" = 409 ] && ! grep -q "^video:" "$E"/passwd'
touch "$R"/lighttpd.ko; cp "$E"/lighttpd/webdav.conf "$R"/dav.avant
api POST a=user_set 'name=dave&pw=abcdefgh'
verifie "conf WebDAV refusée par lighttpd -tt : ancienne gardée, signalé" '[ "$ST" = 200 ] && cmp -s "$E"/lighttpd/webdav.conf "$R"/dav.avant && [ ! -e "$E"/lighttpd/webdav.conf.tmp ] && json "\"lighttpd -tt\" in j[\"msg\"]"'
rm -f "$R"/lighttpd.ko
api POST a=user_del 'name=dave'
api POST a=user_del 'name=alice'
api GET a=users
verifie "user_del : retiré de passwd, ksmbdpwd.db, htpasswd-users, secrets, groupe" "json '[u[\"name\"] for u in j]==[\"carol\"]' && ! grep -q alice \"\$E\"/ksmbd/ksmbdpwd.db \"\$E\"/lighttpd/htpasswd-users \"\$E\"/rsyncd.secrets \"\$E\"/group"
verifie "user_del : modules rsync et WebDAV retirés, dossier gardé" '! grep -q alice "$E"/rsyncd.conf "$E"/lighttpd/webdav.conf && [ -d "$R"/c/home/alice ]'

# ---------- NFS ----------
api GET a=nfs
verifie "nfs : lit /etc/exports" "json 'j[0][\"path\"]==\"/c\" and j[0][\"client\"]==\"10.0.0.0/8\" and j[0][\"ro\"]==0'"
mkdir -p "$R"/c/films
api POST a=nfs_add "path=$(enc /c/films)&client=$(enc 10.1.0.0/16)&ro=1"
verifie "nfs_add : ligne ajoutée, exportfs -ra" 'grep -qx "/c/films 10.1.0.0/16(ro,no_subtree_check)" "$R"/etc/exports && grep -q "exportfs -ra" "$R"/cmd.log'
api POST a=nfs_add "path=$(enc /etc)&client=$(enc '*')"
verifie "nfs_add : dossier hors de /c refusé" '[ "$ST" = 400 ]'
api POST a=nfs_add "path=$(enc /c/films)&client=$(enc '10.0.0.0/8;reboot')"
verifie "nfs_add : client invalide refusé" '[ "$ST" = 400 ]'
api POST a=nfs_del "path=$(enc /c/films)&client=$(enc 10.1.0.0/16)"
verifie "nfs_del : ligne retirée, /c gardé" '! grep -q films "$R"/etc/exports && grep -q "^/c " "$R"/etc/exports'

# ---------- système, réseau, Telegram ----------
api POST a=sys_set "host=nas-essai&lang=de&tz=$(enc 'CET-1CEST,M3.5.0,M10.5.0/3')&net=static&ip=10.0.0.5&mask=255.255.255.0&gw=10.0.0.1&dns=$(enc '10.0.0.53 10.0.0.54')&tgtoken=$(enc 123456:ABC-essai)&tgchat=42"
verifie "sys_set : enregistré" '[ "$ST" = 200 ]'
verifie "sys_set : interfaces statique" 'grep -q "iface eth0 inet static" "$R"/etc/network/interfaces && grep -q "address 10.0.0.5" "$R"/etc/network/interfaces'
verifie "sys_set : nom, NetBIOS, langue" '[ "$(cat "$R"/etc/hostname)" = nas-essai ] && grep -q "netbios name = NAS-ESSAI" "$R"/etc/ksmbd/ksmbd.conf && [ "$(cat "$R"/etc/diet-lang)" = de ]'
verifie "sys_set : diet-notify.conf en 600" '[ "$(stat -c %a "$R"/etc/diet-notify.conf)" = 600 ]'
api GET a=sys
verifie "sys : relit réseau, DNS, Telegram" "json 'j[\"net\"]==\"static\" and j[\"ip\"]==\"10.0.0.5\" and j[\"gw\"]==\"10.0.0.1\" and j[\"dns\"]==\"10.0.0.53 10.0.0.54\" and j[\"tgset\"]==1 and j[\"tgchat\"]==\"42\"'"
api POST a=notify_test ''
verifie "notify_test : envoyé (wget simulé)" '[ "$ST" = 200 ] && grep -q "wget .*api.telegram.org/bot123456:ABC-essai/sendMessage" "$R"/cmd.log'
api POST a=sys_set "host=nas-essai&lang=fr&tz=UTC0&net=dhcp&tgchat="
verifie "sys_set : DHCP et Telegram désactivé" 'grep -q "iface eth0 inet dhcp" "$R"/etc/network/interfaces && [ ! -e "$R"/etc/diet-notify.conf ]'
api POST a=sys_set 'host=Bad_Name'
verifie "sys_set : nom invalide refusé" '[ "$ST" = 400 ]'

# ---------- services : MiniDLNA, Avahi, rsync, WebDAV ----------
api GET a=services
verifie "services : JSON, tout en marche par défaut" "json 'j[\"host\"]==\"nas-essai\" and all(j[k][\"on\"]==1 for k in (\"minidlna\",\"avahi\",\"rsync\",\"webdav\"))'"
verifie "services : MiniDLNA lu dans minidlna.conf, fichiers et base" "json 'j[\"minidlna\"][\"name\"]==\"ReadyNAS\" and j[\"minidlna\"][\"dirs\"]==[\"/c/media\"] and j[\"minidlna\"][\"files\"]==[12,3,40] and j[\"minidlna\"][\"db\"]==2048 and j[\"minidlna\"][\"run\"]==1'"
verifie "services : rsync sans mot de passe" "json 'j[\"rsync\"][\"pw\"]==0'"
mkdir -p "$R"/c/films "$R/c/mes photos"; ln -s "$R"/etc "$R"/c/lien
: > "$R"/cmd.log
mkdir -p "$R"/c/media
api POST a=dlna_set "name=$(enc 'Salon TV')&dirs=$(enc 'V,/c/films
P,/c/mes photos
/c/media')"
verifie "dlna_set : nom et dossiers écrits, minidlna relancé" '[ "$ST" = 200 ] && [ "$(grep -c "^media_dir=" "$R"/etc/minidlna.conf)" = 3 ] && grep -qx "media_dir=P,/c/mes photos" "$R"/etc/minidlna.conf && [ "$(grep "^friendly_name=" "$R"/etc/minidlna.conf)" = "friendly_name=Salon TV" ] && grep -q "S60minidlnad restart" "$R"/cmd.log && grep -q "^inotify=yes" "$R"/etc/minidlna.conf'
for d in /etc /c/../etc /c/lien 'X,/c/films' '/c/films/'; do
	api POST a=dlna_set "name=x&dirs=$(enc "$d")"
	verifie "dlna_set : dossier « $d » refusé" '[ "$ST" = 400 ]'
done
api POST a=dlna_set "name=x&dirs=$(enc /c/absent)"
verifie "dlna_set : dossier absent refusé (404)" '[ "$ST" = 404 ]'
api POST a=dlna_set "name=$(enc 'a
media_dir=/etc')&dirs=$(enc /c/films)"
verifie "dlna_set : nom avec saut de ligne refusé, conf intacte" '[ "$ST" = 400 ] && ! grep -q "/etc" "$R"/etc/minidlna.conf'
api POST a=svc_set 's=minidlna&on=0'
verifie "svc_set minidlna 0 : diet.conf et arrêt" '[ "$ST" = 200 ] && grep -q "^SVC_MINIDLNA=0" "$R"/etc/diet.conf && grep -q "S60minidlnad stop" "$R"/cmd.log'
api POST a=dlna_scan ''
verifie "dlna_scan : refusé si arrêté (409)" '[ "$ST" = 409 ]'
api POST a=svc_set 's=minidlna&on=1'
api POST a=dlna_scan ''
verifie "dlna_scan : réindexation (force-reload)" '[ "$ST" = 200 ] && grep -q "S60minidlnad start" "$R"/cmd.log && grep -q "S60minidlnad force-reload" "$R"/cmd.log'
PW='r5ync é+&%x:y'
api POST a=rsync_pw "pw=$(enc "$PW")"
verifie "rsync_pw : sauvegarde dans rsyncd.secrets (600), autres comptes gardés" '[ "$ST" = 200 ] && grep -qxF "sauvegarde:$PW" "$R"/etc/rsyncd.secrets && grep -q "^carol:" "$R"/etc/rsyncd.secrets && [ "$(stat -c %a "$R"/etc/rsyncd.secrets)" = 600 ]'
verifie "rsync_pw : mot de passe absent des journaux" '! grep -q r5ync "$R"/cmd.log "$R"/var/log/diet.log'
api POST a=rsync_pw "pw=$(enc 'abcdef
x:y')"
verifie "rsync_pw : saut de ligne refusé" '[ "$ST" = 400 ] && grep -qxF "sauvegarde:$PW" "$R"/etc/rsyncd.secrets && ! grep -q "^x:" "$R"/etc/rsyncd.secrets'
api POST a=rsync_c 'on=1'
verifie "rsync_c 1 : module [c] du compte sauvegarde" 'grep -q "^RSYNC_C=1" "$R"/etc/diet.conf && awk "/^\\[c\\]/,0" "$R"/etc/rsyncd.conf | grep -q "auth users = sauvegarde"'
api POST a=rsync_c 'on=0'
verifie "rsync_c 0 : module [c] retiré" '! grep -q "^\[c\]" "$R"/etc/rsyncd.conf && grep -q "^\[carol\]" "$R"/etc/rsyncd.conf'
api POST a=rsync_pw 'pw=abc'
verifie "rsync_pw : trop court refusé" '[ "$ST" = 400 ]'
api POST a=svc_set 's=rsync&on=0'
verifie "svc_set rsync 0 : arrêt, annonce Avahi retirée, avahi rechargé" '[ ! -e "$R"/etc/avahi/services/rsync.service ] && [ -e "$R"/etc/avahi/services/rsync.service.off ] && grep -q "S61rsyncd stop" "$R"/cmd.log && grep -q "S50avahi-daemon reload" "$R"/cmd.log'
api POST a=svc_set 's=rsync&on=1'
verifie "svc_set rsync 1 : annonce remise, démarrage" '[ -e "$R"/etc/avahi/services/rsync.service ] && grep -q "S61rsyncd start" "$R"/cmd.log'
api POST a=svc_set 's=avahi&on=0'
verifie "svc_set avahi 0" 'grep -q "^SVC_AVAHI=0" "$R"/etc/diet.conf && grep -q "S50avahi-daemon stop" "$R"/cmd.log'
api POST a=svc_set 's=webdav&on=0'
verifie "svc_set webdav 0 : instance WebDAV arrêtée, annonce retirée" '[ "$ST" = 200 ] && grep -q "^SVC_WEBDAV=0" "$R"/etc/diet.conf && grep -q "S51webdav stop" "$R"/cmd.log && [ -e "$R"/etc/avahi/services/webdav.service.off ]'
api GET a=services
verifie "services : états relus" "json 'j[\"webdav\"][\"on\"]==0 and j[\"avahi\"][\"on\"]==0 and j[\"rsync\"][\"pw\"]==1 and j[\"rsync\"][\"c\"]==0 and j[\"minidlna\"][\"name\"]==\"Salon TV\"'"
api POST a=svc_set 's=sshd&on=0'
verifie "svc_set : service inconnu refusé" '[ "$ST" = 400 ]'
api POST a=svc_set "s=webdav&on=$(enc '1;reboot')"
verifie "svc_set : valeur invalide refusée" '[ "$ST" = 400 ]'
api POST a=svc_set 's=rsync&on=0' ''
verifie "svc_set sans X-Diet refusé (403)" '[ "$ST" = 403 ]'
api POST a=svc_set 's=webdav&on=1'
verifie "svc_set webdav 1 : instance démarrée, annonce remise" 'grep -q "S51webdav start" "$R"/cmd.log && [ -e "$R"/etc/avahi/services/webdav.service ]'
verifie "lighttpd.conf : /webdav relayé vers 127.0.0.1:8081, hors du compte de l’interface" 'grep -qF "\"host\" => \"127.0.0.1\", \"port\" => 8081" "$SRC"/etc/lighttpd/lighttpd.conf && grep -qF "\$HTTP[\"url\"] !~ \"^/webdav(/|\$)\" {" "$SRC"/etc/lighttpd/lighttpd.conf'
# scripts de démarrage : un service à 0 dans diet.conf ne démarre pas
for s in S50avahi-daemon:AVAHI S51webdav:WEBDAV S60minidlnad:MINIDLNA S61rsyncd:RSYNC; do
	f=$BOARD/etc/init.d/${s%%:*}; [ -e "$f" ] || f=$SRC/etc/init.d/${s%%:*}; : > "$R"/cmd.log
	sed -i "s/^SVC_${s#*:}=.*/SVC_${s#*:}=0/" "$R"/etc/diet.conf
	sed "s#/etc/#$R/etc/#g; s#/var/#$R/var/#g; s#/usr/sbin/avahi-daemon#start-stop-daemon#" "$f" | PATH="$R/bin:$PATH" sh -s start >/dev/null
	verifie "${s%%:*} : pas de démarrage si SVC_${s#*:}=0" '[ ! -s "$R"/cmd.log ]'
	sed -i "s/^SVC_${s#*:}=.*/SVC_${s#*:}=1/" "$R"/etc/diet.conf
	sed "s#/etc/#$R/etc/#g; s#/var/#$R/var/#g; s#/usr/sbin/avahi-daemon#start-stop-daemon#" "$f" | PATH="$R/bin:$PATH" sh -s start >/dev/null
	verifie "${s%%:*} : démarrage si SVC_${s#*:}=1" '[ -s "$R"/cmd.log ]'
done

# ---------- stockage : X-RAID (compatibilité) et md, par nas-raid ----------
# vrai nas-raid et xraid-info compilé pour l'hôte, sur des images X-RAID factices
XC=$ICI/../../xraid-compat
cc -O2 -o "$R"/bin/xraid-info "$XC"/src/xraid-info.c && ln -s "$XC"/src/nas-raid "$R"/bin/nas-raid
for s in propre sale degrade md; do python3 "$XC"/tests/fabrique-images.py "$R/img/$s" $s > /dev/null; done
stk() {	# stk scénario « contenu de nas-raid.mode »
	export NAS_RAID_DISQUES="$(ls "$R/img/$1"/*.img | tr '\n' ' ')"
	echo "$2" > "$R"/var/run/nas-raid.mode; rm -f "$R"/var/run/xraid.json
	api GET a=stockage
}
stk propre xraid-rw
verifie "stockage X-RAID propre : rw, 2 sections, base/miroir" "json 'j[\"mode\"]==\"xraid-rw\" and j[\"xraid\"][\"mode\"]==\"rw\" and len(j[\"xraid\"][\"sections\"])==2 and j[\"xraid\"][\"miroir\"].endswith(\"sda.img\")'"
stk sale 'xraid-ro arret_brutal'
verifie "stockage X-RAID sale : lecture seule, raison arret_brutal" "json 'j[\"mode\"]==\"xraid-ro\" and [r[\"code\"] for r in j[\"xraid\"][\"raisons\"]]==[\"arret_brutal\"]'"
stk degrade 'xraid-ro disque_manquant'
verifie "stockage X-RAID dégradé : lecture seule, un seul disque" "json 'j[\"xraid\"][\"miroir\"]==\"\" and j[\"xraid\"][\"raisons\"][0][\"code\"]==\"disque_manquant\"'"
stk md md
verifie "stockage md : mode md" "json 'j[\"mode\"]==\"md\" and j[\"migration\"][\"etape\"]==\"\"'"
stk propre xraid-rw
cp "$R"/proc/mounts "$R"/mounts.bak; echo '/dev/root / ext4 rw 0 0' > "$R"/proc/mounts	# /c simulé trop plein pour l'image
api POST a=raid_plan 'op=migrer'
mv "$R"/mounts.bak "$R"/proc/mounts
verifie "raid_plan migrer : essai à blanc (mdadm --create, rsync)" 'case "$OUT" in *"mdadm --create /dev/md/donnees"*"rsync -aH"*) true;; *) false;; esac'
api POST a=raid_lancer 'op=migrer&oui=1'
verifie "raid_lancer : refusé sans phrase" '[ "$ST" = 400 ]'
api POST a=raid_lancer 'op=migrer&confirm=MIGRER'
verifie "raid_lancer : refusé sans la seconde confirmation" '[ "$ST" = 400 ]'
api POST a=raid_lancer "op=migrer&confirm=$(enc "MIGRER';reboot")&oui=1"
verifie "raid_lancer : phrase avec caractères interdits refusée" '[ "$ST" = 400 ]'
api POST a=raid_lancer 'op=creer&d=sdz&confirm=EFFACER+sdz&oui=1'
verifie "raid_lancer : disque inconnu refusé" '[ "$ST" = 400 ]'
api POST a=raid_plan 'op=rm'
verifie "raid_plan : opération inconnue refusée" '[ "$ST" = 400 ]'
api POST a=raid_verifier ''
verifie "raid_verifier : lancé" '[ "$ST" = 200 ]'
sleep 3	# la vérification (images de 4 Go creuses) écrit dans $R : la laisser finir
api GET 'a=log&f=stockage'
verifie "log stockage : journal de nas-raid" '[ "$ST" = 200 ]'
unset NAS_RAID_DISQUES

# ---------- divers ----------
api POST a=reboot '' ''
verifie "POST sans X-Diet refusé (403)" '[ "$ST" = 403 ]'
api GET 'a=md&d=md0'
verifie "md : mdadm --detail" 'case "$OUT" in *"State : clean"*) true;; *) false;; esac'
api GET 'a=md&d=md9'
verifie "md : volume inconnu refusé" '[ "$ST" = 400 ]'
api GET 'a=smart&d=sda'
verifie "smart sans smartctl : drivetemp et dmesg" 'case "$OUT" in *"38 °C (drivetemp)"*"[sda]"*) true;; *) false;; esac'
api GET 'a=smart&d=..%2Fetc'
verifie "smart : disque inconnu refusé" '[ "$ST" = 400 ]'

# ---------- diet-hwmon (un tour) ----------
echo "$DEGRADE" > "$R"/proc/mdstat
echo 'TG_TOKEN=1:x
TG_CHAT=1' > "$R"/etc/diet-notify.conf
PATH="$R/bin:$PATH" DIET_UNE_FOIS=1 $SH "$SRC"/usr/sbin/diet-hwmon
sleep 1
verifie "diet-hwmon : historique écrit" 'grep -q " 45 1800 120$" "$R"/var/run/hwmon.hist'
verifie "diet-hwmon : alerte notée et envoyée" 'grep -q "RAID dégradé" "$R"/var/run/alert.last && grep -q "ALERTE" "$R"/var/log/diet.log && grep -q "wget .*sendMessage" "$R"/cmd.log'

echo "$((N - ECHECS))/$N essais réussis (racine : $R)"
[ $ECHECS -eq 0 ] && rm -rf "$R"
[ $ECHECS -eq 0 ]
