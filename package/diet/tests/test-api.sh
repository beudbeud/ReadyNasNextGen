#!/bin/sh
# Tests of the DIET API on a PC, without the NAS: fake root (DIET_ROOT) with
# simulated /proc, /sys, /etc and /var, NAS commands replaced by scripts that
# log their arguments. Checks the JSON (python3) and the files.
#   sh package/diet/tests/test-api.sh           tests (dash; not as root)
# NB: the host busybox prefers its own applets over the simulated commands
# (pidof, ifconfig, hostname...); that is why the tests run under dash.
#   sh package/diet/tests/test-api.sh --serve   interface on http://127.0.0.1:8080/
#                                               (busybox httpd, simulated data)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../src
BOARD=$HERE/../../../board/readynas-duo-v1/rootfs-overlay
SH=${SH:-sh}
R=$(mktemp -d "${TMPDIR:-/tmp}/diet-test.XXXXXX")
export DIET_ROOT="$R"
FAILS=0; N=0

# ---------- fake root ----------
mkdir -p "$R"/bin "$R"/etc/init.d "$R"/etc/ksmbd "$R"/etc/network "$R"/var/run "$R"/var/log "$R"/c \
	"$R"/proc/sys/kernel "$R"/proc/sys/dev/boot "$R"/proc/net "$R"/proc/fs/nfsd
cp "$SRC"/etc/diet-lang.sh "$SRC"/etc/diet.conf "$BOARD"/etc/fan.conf "$BOARD"/etc/exports "$R"/etc/
cp "$BOARD"/etc/ksmbd/ksmbd.conf "$R"/etc/ksmbd/
# services: MiniDLNA, rsync, Avahi announcements, lighttpd (WebDAV included separately)
mkdir -p "$R"/etc/lighttpd "$R"/etc/avahi "$R"/var/run/minidlna "$R"/var/run/avahi-daemon "$R"/var/lib/minidlna
cp "$BOARD"/etc/minidlna.conf "$BOARD"/etc/rsyncd.conf "$R"/etc/
cp -R "$BOARD"/etc/avahi/services "$R"/etc/avahi/
cp "$SRC"/etc/lighttpd/lighttpd.conf "$SRC"/etc/lighttpd/webdav.conf "$R"/etc/lighttpd/
cp "$BOARD"/etc/rsyncd.conf "$R"/etc/
head -c 2048 /dev/zero > "$R"/var/lib/minidlna/files.db
echo $$ > "$R"/var/run/minidlna/minidlna.pid
echo en > "$R"/etc/diet-lang
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
# running processes (the API reads /proc/<pid>/comm)
for p in 101:ksmbd.mountd 102:lighttpd 103:dropbear 104:sh; do mkdir -p "$R/proc/${p%%:*}"; echo "${p#*:}" > "$R/proc/${p%%:*}/comm"; done
for d in sda:38000 sdb:41000; do
	mkdir -p "$R/sys/block/${d%%:*}/device/hwmon/hwmon0"
	echo "TEST-DISK ${d%%:*}" > "$R/sys/block/${d%%:*}/device/model"
	echo 3907029168 > "$R/sys/block/${d%%:*}/size"
	echo "${d#*:}" > "$R/sys/block/${d%%:*}/device/hwmon/hwmon0/temp1_input"
done
HEALTHY='Personalities : [raid1]
md0 : active raid1 sdb1[1] sda1[0]
      1953382464 blocks super 1.2 [2/2] [UU]

unused devices: <none>'
DEGRADED='Personalities : [raid1]
md0 : active raid1 sdb1[1](F) sda1[0]
      1953382464 blocks super 1.2 [2/1] [U_]
      [=>...................]  recovery =  7.5% (146503680/1953382464) finish=300.1min speed=100000K/sec

unused devices: <none>'
echo "$HEALTHY" > "$R"/proc/mdstat
echo "temp=45 disks=41 fan=1800 pwm=120" > "$R"/var/run/fan.state
echo $$ > "$R"/var/run/fan.pid
echo "INVALID" > "$R"/var/run/diet-hwmon.pid

# ---------- simulated commands (they log their arguments in cmd.log) ----------
stub() { printf '#!/bin/sh\necho "%s $*" >> "$DIET_ROOT/cmd.log"\n%s\n' "$1" "${2:-}" > "$R/bin/$1"; chmod 755 "$R/bin/$1"; }
stub ifconfig 'echo "eth0 Link encap:Ethernet"; echo "  inet addr:10.0.0.2  Bcast:10.0.0.255  Mask:255.255.255.0"'
stub route 'printf "Kernel\nDestination Gateway\n0.0.0.0 10.0.0.1 0.0.0.0 UG 0 0 0 eth0\n"'
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/md0 1922000000 922000000 1000000000 48% /c"'
stub pidof 'case "$1" in ksmbd.mountd|dropbear|lighttpd) echo 123;; *) exit 1;; esac'
stub ksmbd.control
stub exportfs
for c in rpc.statd rpc.nfsd rpc.mountd killall; do stub $c; done
stub hdparm
stub hostname 'echo readynas'
stub mdadm 'echo "/dev/md0: simulated"; echo "  State : clean"'
stub dmesg 'echo "[    1.0] sd 0:0:0:0: [sda] 3907029168 512-byte logical blocks"'
# wget: Telegram, or the minidlnad status page (file counts)
stub wget 'case "$*" in *127.0.0.1:8200*) echo "<tr><td>Audio files</td><td>12</td></tr><tr><td>Video files</td><td>3</td></tr><tr><td>Image files</td><td>40</td></tr>";; *) echo "{\"ok\":true}";; esac'
stub start-stop-daemon
stub lighttpd '[ ! -e "$DIET_ROOT/lighttpd.ko" ]'
stub chown
# mkpasswd -m sha512 -S salt -P 0: password read on standard input (real SHA-512 hash)
stub mkpasswd 'IFS= read -r p; printf "%s" "$p" | openssl passwd -6 -stdin'
# ksmbd.adduser: password read on standard input, written to password.log
cat > "$R"/bin/ksmbd.adduser <<'EOF'
#!/bin/sh
echo "ksmbd.adduser $*" >> "$DIET_ROOT/cmd.log"
db=""; del=""
while [ $# -gt 1 ]; do case "$1" in -P) db=$2; shift;; -C) shift;; -d) del=1;; esac; shift; done
if [ -n "$del" ]; then grep -v "^$1:" "$db" > "$db.t"; mv "$db.t" "$db"
else IFS= read -r p1; IFS= read -r p2; [ "$p1" = "$p2" ] || exit 1; printf '%s' "$p1" > "$DIET_ROOT/password.log"; echo "$1:SIMULATED" >> "$db"; fi
EOF
chmod 755 "$R"/bin/ksmbd.adduser
for s in S45fan S60nfs S70ksmbd S95diet S50avahi-daemon S51webdav S60minidlnad S61rsyncd; do
	printf '#!/bin/sh\necho "%s $*" >> "$DIET_ROOT/cmd.log"\n' "$s" > "$R/etc/init.d/$s"; chmod 755 "$R/etc/init.d/$s"
done
for s in diet-notify diet-alerts; do ln -s "$SRC/usr/sbin/$s" "$R/bin/$s"; done

if [ "${1:-}" = --serve ]; then
	echo "Fake root: $R; interface: http://127.0.0.1:8080/ (Ctrl-C to stop)"
	exec busybox httpd -f -p 127.0.0.1:8080 -h "$SRC/www"
fi

# ---------- test helpers ----------
# api METHOD query [body] [X-Diet]: output without headers in $OUT, status in $ST
api() {
	body=${3:-}
	raw=$(printf '%s' "$body" | REQUEST_METHOD=$1 QUERY_STRING="$2&l=en" CONTENT_LENGTH=${#body} \
		HTTP_X_DIET=${4-1} REMOTE_ADDR=10.0.0.9 $SH "$SRC/www/cgi-bin/api")
	ST=$(printf '%s\n' "$raw" | sed -n 's/^Status: \([0-9]*\).*/\1/p' | head -n 1); ST=${ST:-200}
	OUT=$(printf '%s\n' "$raw" | tr -d '\r' | sed '1,/^$/d')
	# every JSON answer must be valid (no 00000000000, NaN, trailing comma...)
	case $raw in *"Content-Type: application/json"*)
		NJSON=$((NJSON + 1)); printf '%s' "$OUT" | jsonok || JSONKO="$JSONKO $1:$2" ;;
	esac
}
NJSON=0; JSONKO=
jsonok() { python3 -I -c 'import json,sys; json.load(sys.stdin, parse_constant=lambda c: 1/0)' 2>/dev/null; }
check() {	# check "description" shell-condition
	N=$((N + 1))
	if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); fi
}
json() {	# json 'python expression on j': true if the expression is true
	printf '%s' "$OUT" | python3 -c "import json,sys; j=json.load(sys.stdin); sys.exit(0 if ($1) else 1)" 2>/dev/null
}
enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote_plus(sys.argv[1]))' "$1"; }

# ---------- status ----------
api GET a=status
check "status: valid JSON" "json 'True'"
check "status: healthy RAID1 UU" "json 'j[\"md\"][0][\"map\"]==\"UU\" and j[\"md\"][0][\"level\"]==\"raid1\"'"
check "status: 2 disks, drivetemp, bays" "json '[d[\"temp\"] for d in j[\"disks\"]]==[38,41] and [d[\"bay\"] for d in j[\"disks\"]]==[1,2]'"
check "status: fan (padre-fan)" "json 'j[\"temp\"]==45 and j[\"fan\"]==1800 and j[\"pwm\"]==120 and j[\"svc\"][\"fan\"]==1'"
check "status: services" "json 'j[\"svc\"][\"ksmbd\"]==1 and j[\"svc\"][\"nfs\"]==1 and j[\"svc\"][\"ntpd\"]==0 and j[\"svc\"][\"hwmon\"]==0'"
check "status: /c and memory" "json 'j[\"c\"][\"size\"]==1922000000 and j[\"mem\"][\"avail\"]==180000 and j[\"ip\"]==\"10.0.0.2\"'"
echo "$DEGRADED" > "$R"/proc/mdstat
api GET a=status
check "status degraded: U_, sdb failed, resync" "json 'j[\"md\"][0][\"map\"]==\"U_\" and j[\"disks\"][1][\"faulty\"]==1 and j[\"disks\"][0][\"faulty\"]==0 and \"recovery\" in j[\"md\"][0][\"sync\"]'"
A=$($SH "$SRC"/usr/sbin/diet-alerts)
check "diet-alerts: degraded RAID + failed disk" 'case "$A" in *"RAID degraded (md0)"*"failed disk in the RAID (sdb1)"*) true;; *) false;; esac'
echo fr > "$R"/etc/diet-lang; A=$($SH "$SRC"/usr/sbin/diet-alerts)
check "diet-alerts in French" 'case "$A" in *"RAID dégradé (md0)"*"disque en panne dans le RAID (sdb1)"*) true;; *) false;; esac'
echo de > "$R"/etc/diet-lang; A=$($SH "$SRC"/usr/sbin/diet-alerts)
check "diet-alerts in German" 'case "$A" in *"RAID beeinträchtigt (md0)"*"Platte im RAID ausgefallen (sdb1)"*) true;; *) false;; esac'
echo en > "$R"/etc/diet-lang
echo "$HEALTHY" > "$R"/proc/mdstat
check "diet-alerts: nothing if healthy" '[ -z "$($SH "$SRC"/usr/sbin/diet-alerts)" ]'

# ---------- hardware settings ----------
api GET a=config
check "config: reads fan.conf and diet.conf" "json 'j[\"FAN_PWM_MIN\"]==50 and j[\"PERIOD\"]==60 and j[\"SPINDOWN_MIN\"]==30'"
api POST a=config 'FAN_PWM_MIN=60&TEMP_HIGH=52&SPINDOWN_MIN=10'
check "config: saved (200)" '[ "$ST" = 200 ]'
check "config: fan.conf changed, comment kept" 'grep -q "^FAN_PWM_MIN=60 .*# idle setpoint" "$R"/etc/fan.conf && grep -q "^TEMP_HIGH=52" "$R"/etc/fan.conf'
check "config: padre-fan restarted, spin-down applied" 'grep -q "S45fan restart" "$R"/cmd.log && grep -q "hdparm -S 120 /dev/sda" "$R"/cmd.log'
api POST a=config 'FAN_PWM_MIN=5'
check "config: minimum too low refused (400)" '[ "$ST" = 400 ]'
api POST a=config 'PERIOD=600'
check "config: period > 240 s refused" '[ "$ST" = 400 ]'

# ---------- SMB shares ----------
api GET a=shares
check "shares: [c] only, no [global]" "json 'j==[{\"name\":\"c\",\"path\":\"/c\",\"ro\":0,\"guest\":0,\"exists\":1}]'"
# format written by share_add (tabs) and variants: never a ghost "c]" share
cp "$R"/etc/ksmbd/ksmbd.conf "$R"/ksmbd.bak
cat >> "$R"/etc/ksmbd/ksmbd.conf <<'EOF'

[photos]
	path = /c/photos
	create mask = 0666
	writeable = yes
	guest ok = yes
  [Docs]   ; comment
path=/c/docs
read only = yes
EOF
api GET a=shares
check "shares: name without \"]\", path read, permissions (share_add format)" "json '[(s[\"name\"],s[\"path\"],s[\"ro\"],s[\"guest\"]) for s in j]==[(\"c\",\"/c\",0,0),(\"photos\",\"/c/photos\",0,1),(\"Docs\",\"/c/docs\",1,0)]'"
check "shares: ksmbd.conf read without substr/index (floating point in the NAS awk)" '! sed -n "/^shares_list()/,/^}/p" "$SRC"/www/cgi-bin/api | grep -qE "substr|index\("'
mv "$R"/ksmbd.bak "$R"/etc/ksmbd/ksmbd.conf
api POST a=share_add 'name=photos'
check "share_add: section, folder, ksmbd reload" 'grep -q "^\[photos\]" "$R"/etc/ksmbd/ksmbd.conf && [ -d "$R"/c/photos ] && grep -q "ksmbd.control -r" "$R"/cmd.log'
api POST a=share_add 'name=photos'
check "share_add: duplicate refused (409)" '[ "$ST" = 409 ]'
api POST a=share_add 'name=global'
check "share_add: reserved name refused" '[ "$ST" = 400 ]'
api POST a=share_add 'name=a%2Fb'
check "share_add: forbidden characters refused" '[ "$ST" = 400 ]'
api POST a=share_set 'name=photos&ro=1&guest=0'
api GET a=shares
check "share_set: read-only, with account" "json '[s for s in j if s[\"name\"]==\"photos\"][0][\"ro\"]==1 and [s for s in j if s[\"name\"]==\"photos\"][0][\"guest\"]==0'"
api POST a=share_del 'name=photos'
api GET a=shares
check "share_del: removed, folder kept" "json 'len(j)==1' && [ -d \"\$R\"/c/photos ]"

# ---------- users (SMB, WebDAV, rsync: same password) ----------
E=$R/etc
PW='s3cret é+&%x'
api POST a=user_set "name=alice&pw=$(enc "$PW")"
check "user_set: account created (uid 1000, personal group alice, member nas)" 'grep -q "^alice:x:1000:1000:" "$E"/passwd && grep -qx "alice:x:1000:nas" "$E"/group'
check "user_set: decoded password passed on stdin, never logged" '[ "$(cat "$R"/password.log)" = "$PW" ] && ! grep -q "s3cret" "$R"/cmd.log "$R"/var/log/diet.log'
check "user_set: WebDAV (htpasswd-users SHA-512, 640, root:nas)" 'grep -q "^alice:[\$]6[\$]" "$E"/lighttpd/htpasswd-users && [ "$(stat -c %a "$E"/lighttpd/htpasswd-users)" = 640 ] && grep -q "chown root:nas $E/lighttpd/htpasswd-users" "$R"/cmd.log'
check "user_set: rsync (rsyncd.secrets 600)" 'grep -qxF "alice:$PW" "$E"/rsyncd.secrets && [ "$(stat -c %a "$E"/rsyncd.secrets)" = 600 ]'
check "user_set: personal folder 2770 owned by alice" '[ "$(stat -c %a "$R"/c/home/alice)" = 2770 ] && grep -q "chown alice:alice $R/c/home/alice" "$R"/cmd.log'
check "rsyncd.conf: module [alice] (uid/gid alice, auth alice), no [c]" 'awk "/^\[alice\]/,0" "$E"/rsyncd.conf | grep -q "uid = alice" && grep -q "auth users = alice" "$E"/rsyncd.conf && grep -q "path = /c/home/alice" "$E"/rsyncd.conf && ! grep -q "^\[c\]" "$E"/rsyncd.conf'
check "webdav.conf: /webdav/alice for alice only, checked (-tt), instance restarted" 'grep -q "\"require\" => \"user=alice\"" "$E"/lighttpd/webdav.conf && grep -q "\"/webdav/alice\" => \"/c/home/alice\"" "$E"/lighttpd/webdav.conf && grep -q "lighttpd -tt -f $E/lighttpd/webdav.conf.tmp" "$R"/cmd.log && grep -q "S51webdav restart" "$R"/cmd.log && grep -q "server.username = \"nas\"" "$E"/lighttpd/webdav.conf'
api GET a=users
check "users: alice with SMB and WebDAV/rsync passwords" "json 'j==[{\"name\":\"alice\",\"uid\":1000,\"smb\":1,\"dav\":1}]'"
api POST a=share_add 'name=commun'
check "share_add: share root:users 2777, rsync module and WebDAV for the accounts" '[ "$(stat -c %a "$R"/c/commun)" = 2777 ] && grep -q "chown root:users $R/c/commun" "$R"/cmd.log && awk "/^\[commun\]/,0" "$E"/rsyncd.conf | grep -q "uid = nas" && grep -q "\"/webdav/commun\" => \"/c/commun\"" "$E"/lighttpd/webdav.conf'
api POST a=share_set 'name=commun&ro=1&guest=0'
check "share_set read-only: no more rsync module, read-only WebDAV" '! grep -q "^\[commun\]" "$E"/rsyncd.conf && awk "/webdav.commun/,0" "$E"/lighttpd/webdav.conf | grep -q "is-readonly = \"enable\""'
# account created earlier (users group, no WebDAV/rsync): to be set again
echo "carol:x:1001:100::/c/home/carol:/bin/false" >> "$E"/passwd
api GET a=users
check "users: old account without WebDAV/rsync (dav 0)" "json '[u[\"dav\"] for u in j]==[1,0]'"
api POST a=user_set "name=carol&pw=$(enc carol-2026)"
check "user_set old account: personal group, WebDAV/rsync enabled" 'grep -q "^carol:x:1001:1001:" "$E"/passwd && grep -qx "carol:x:1001:nas" "$E"/group && grep -q "^carol:" "$E"/lighttpd/htpasswd-users && grep -q "^\[carol\]" "$E"/rsyncd.conf'
api POST a=share_set 'name=commun&ro=0&guest=0'
check "share_set writable: share rsync module for every account" 'awk "/^\[commun\]/,0" "$E"/rsyncd.conf | grep -q "auth users = alice,carol"'
api POST a=user_set 'name=root&pw=abcdefgh'
check "user_set: system account refused (403)" '[ "$ST" = 403 ]'
api POST a=user_set 'name=bob&pw=abc'
check "user_set: password too short refused" '[ "$ST" = 400 ] && ! grep -q "^bob:" "$E"/passwd'
for n in sauvegarde nas c a%2Fb "$(enc 'x"y')" "$(enc 'x y')" -x "$(enc 'x/../y')" "$(enc 'x]
[c')"; do
	api POST a=user_set "name=$n&pw=abcdefgh"
	check "user_set: dangerous or reserved name \"$n\" refused" '[ "$ST" = 400 ]'
done
echo "video:x:28:" >> "$E"/group
api POST a=user_set 'name=video&pw=abcdefgh'
check "user_set: system group name refused (409)" '[ "$ST" = 409 ] && ! grep -q "^video:" "$E"/passwd'
touch "$R"/lighttpd.ko; cp "$E"/lighttpd/webdav.conf "$R"/dav.before
api POST a=user_set 'name=dave&pw=abcdefgh'
check "WebDAV conf rejected by lighttpd -tt: old one kept, reported" '[ "$ST" = 200 ] && cmp -s "$E"/lighttpd/webdav.conf "$R"/dav.before && [ ! -e "$E"/lighttpd/webdav.conf.tmp ] && json "\"lighttpd -tt\" in j[\"msg\"]"'
rm -f "$R"/lighttpd.ko
api POST a=user_del 'name=dave'
api POST a=user_del 'name=alice'
api GET a=users
check "user_del: removed from passwd, ksmbdpwd.db, htpasswd-users, secrets, group" "json '[u[\"name\"] for u in j]==[\"carol\"]' && ! grep -q alice \"\$E\"/ksmbd/ksmbdpwd.db \"\$E\"/lighttpd/htpasswd-users \"\$E\"/rsyncd.secrets \"\$E\"/group"
check "user_del: rsync and WebDAV modules removed, folder kept" '! grep -q alice "$E"/rsyncd.conf "$E"/lighttpd/webdav.conf && [ -d "$R"/c/home/alice ]'

# ---------- NFS ----------
api GET a=nfs
check "nfs: reads /etc/exports" "json 'j[0][\"path\"]==\"/c\" and j[0][\"client\"]==\"10.0.0.0/8\" and j[0][\"ro\"]==0'"
check "nfs: host and options split at \"(\" (no \"10.0.0.0/8(\")" "json 'j==[{\"path\":\"/c\",\"client\":\"10.0.0.0/8\",\"ro\":0,\"opts\":\"rw,no_subtree_check,fsid=0\",\"exists\":1}]'"
cp "$R"/etc/exports "$R"/exports.bak
printf '# comment\n\n  /c 10.0.0.0/8(rw,no_subtree_check,fsid=0)   192.168.1.0/24(ro,sync)\n/c/absent *\n' > "$R"/etc/exports
api GET a=nfs
check "nfs: two clients on one line, client without options, missing folder" "json '[(x[\"client\"],x[\"opts\"],x[\"ro\"],x[\"exists\"]) for x in j]==[(\"10.0.0.0/8\",\"rw,no_subtree_check,fsid=0\",0,1),(\"192.168.1.0/24\",\"ro,sync\",1,1),(\"*\",\"\",0,0)]'"
check "nfs: read by the shell, no awk (floating point in the NAS awk)" '! sed -n "/^nfs_get()/,/^}/p" "$SRC"/www/cgi-bin/api | grep -q awk'
mv "$R"/exports.bak "$R"/etc/exports
mkdir -p "$R"/c/films
api POST a=nfs_add "path=$(enc /c/films)&client=$(enc 10.1.0.0/16)&ro=1"
check "nfs_add: line added, exportfs -ra" 'grep -qx "/c/films 10.1.0.0/16(ro,no_subtree_check)" "$R"/etc/exports && grep -q "exportfs -ra" "$R"/cmd.log'
api POST a=nfs_add "path=$(enc /etc)&client=$(enc '*')"
check "nfs_add: folder outside /c refused" '[ "$ST" = 400 ]'
api POST a=nfs_add "path=$(enc /c/films)&client=$(enc '10.0.0.0/8;reboot')"
check "nfs_add: invalid client refused" '[ "$ST" = 400 ]'
api POST a=nfs_del "path=$(enc /c/films)&client=$(enc 10.1.0.0/16)"
check "nfs_del: line removed, /c kept" '! grep -q films "$R"/etc/exports && grep -q "^/c " "$R"/etc/exports'

# ---------- system, network, Telegram ----------
api POST a=sys_set "host=nas-test&lang=de&tz=$(enc 'CET-1CEST,M3.5.0,M10.5.0/3')&net=static&ip=10.0.0.5&mask=255.255.255.0&gw=10.0.0.1&dns=$(enc '10.0.0.53 10.0.0.54')&tgtoken=$(enc 123456:ABC-test)&tgchat=42"
check "sys_set: saved" '[ "$ST" = 200 ]'
check "sys_set: static interfaces" 'grep -q "iface eth0 inet static" "$R"/etc/network/interfaces && grep -q "address 10.0.0.5" "$R"/etc/network/interfaces'
check "sys_set: name, NetBIOS, language" '[ "$(cat "$R"/etc/hostname)" = nas-test ] && grep -q "netbios name = NAS-TEST" "$R"/etc/ksmbd/ksmbd.conf && [ "$(cat "$R"/etc/diet-lang)" = de ]'
check "sys_set: diet-notify.conf mode 600" '[ "$(stat -c %a "$R"/etc/diet-notify.conf)" = 600 ]'
api GET a=sys
check "sys: reads back network, DNS, Telegram" "json 'j[\"net\"]==\"static\" and j[\"ip\"]==\"10.0.0.5\" and j[\"gw\"]==\"10.0.0.1\" and j[\"dns\"]==\"10.0.0.53 10.0.0.54\" and j[\"tgset\"]==1 and j[\"tgchat\"]==\"42\"'"
api POST a=notify_test ''
check "notify_test: sent (simulated wget)" '[ "$ST" = 200 ] && grep -q "wget .*api.telegram.org/bot123456:ABC-test/sendMessage" "$R"/cmd.log'
api POST a=sys_set "host=nas-test&lang=en&tz=UTC0&net=dhcp&tgchat="
check "sys_set: DHCP and Telegram disabled" 'grep -q "iface eth0 inet dhcp" "$R"/etc/network/interfaces && [ ! -e "$R"/etc/diet-notify.conf ]'
api POST a=sys_set 'host=Bad_Name'
check "sys_set: invalid name refused" '[ "$ST" = 400 ] && [ "$OUT" = "Invalid NAS name: lowercase letters, digits and dashes" ]'
api POST 'a=sys_set&l=fr' 'host=Bad_Name'
check "API error in French (l=fr)" '[ "$ST" = 400 ] && [ "$OUT" = "Nom du NAS invalide : minuscules, chiffres et tirets" ]'
api POST 'a=sys_set&l=de' 'host=Bad_Name'
check "API error in German (l=de)" '[ "$ST" = 400 ] && [ "$OUT" = "Ungültiger NAS-Name: Kleinbuchstaben, Ziffern und Bindestriche" ]'

# ---------- services : MiniDLNA, Avahi, rsync, WebDAV ----------
api GET a=services
check "services: JSON, everything on by default" "json 'j[\"host\"]==\"nas-test\" and all(j[k][\"on\"]==1 for k in (\"minidlna\",\"avahi\",\"rsync\",\"webdav\"))'"
check "services: MiniDLNA read from minidlna.conf, files and database" "json 'j[\"minidlna\"][\"name\"]==\"ReadyNAS\" and j[\"minidlna\"][\"dirs\"]==[\"/c/media\"] and j[\"minidlna\"][\"files\"]==[12,3,40] and j[\"minidlna\"][\"db\"]==2048 and j[\"minidlna\"][\"run\"]==1'"
check "services: rsync without password" "json 'j[\"rsync\"][\"pw\"]==0'"
mkdir -p "$R"/c/films "$R/c/mes photos"; ln -s "$R"/etc "$R"/c/lien
: > "$R"/cmd.log
mkdir -p "$R"/c/media
api POST a=dlna_set "name=$(enc 'Salon TV')&dirs=$(enc 'V,/c/films
P,/c/mes photos
/c/media')"
check "dlna_set: name and folders written, minidlna restarted" '[ "$ST" = 200 ] && [ "$(grep -c "^media_dir=" "$R"/etc/minidlna.conf)" = 3 ] && grep -qx "media_dir=P,/c/mes photos" "$R"/etc/minidlna.conf && [ "$(grep "^friendly_name=" "$R"/etc/minidlna.conf)" = "friendly_name=Salon TV" ] && grep -q "S60minidlnad restart" "$R"/cmd.log && grep -q "^inotify=yes" "$R"/etc/minidlna.conf'
for d in /etc /c/../etc /c/lien 'X,/c/films' '/c/films/'; do
	api POST a=dlna_set "name=x&dirs=$(enc "$d")"
	check "dlna_set: folder \"$d\" refused" '[ "$ST" = 400 ]'
done
api POST a=dlna_set "name=x&dirs=$(enc /c/absent)"
check "dlna_set: missing folder refused (404)" '[ "$ST" = 404 ]'
api POST a=dlna_set "name=$(enc 'a
media_dir=/etc')&dirs=$(enc /c/films)"
check "dlna_set: name with a newline refused, conf intact" '[ "$ST" = 400 ] && ! grep -q "/etc" "$R"/etc/minidlna.conf'
api POST a=svc_set 's=minidlna&on=0'
check "svc_set minidlna 0: diet.conf and stop" '[ "$ST" = 200 ] && grep -q "^SVC_MINIDLNA=0" "$R"/etc/diet.conf && grep -q "S60minidlnad stop" "$R"/cmd.log'
api POST a=dlna_scan ''
check "dlna_scan: refused if stopped (409)" '[ "$ST" = 409 ]'
api POST a=svc_set 's=minidlna&on=1'
api POST a=dlna_scan ''
check "dlna_scan: rescan (force-reload)" '[ "$ST" = 200 ] && grep -q "S60minidlnad start" "$R"/cmd.log && grep -q "S60minidlnad force-reload" "$R"/cmd.log'
PW='r5ync é+&%x:y'
api POST a=rsync_pw "pw=$(enc "$PW")"
check "rsync_pw: sauvegarde in rsyncd.secrets (600), other accounts kept" '[ "$ST" = 200 ] && grep -qxF "sauvegarde:$PW" "$R"/etc/rsyncd.secrets && grep -q "^carol:" "$R"/etc/rsyncd.secrets && [ "$(stat -c %a "$R"/etc/rsyncd.secrets)" = 600 ]'
check "rsync_pw: password absent from the logs" '! grep -q r5ync "$R"/cmd.log "$R"/var/log/diet.log'
api POST a=rsync_pw "pw=$(enc 'abcdef
x:y')"
check "rsync_pw: newline refused" '[ "$ST" = 400 ] && grep -qxF "sauvegarde:$PW" "$R"/etc/rsyncd.secrets && ! grep -q "^x:" "$R"/etc/rsyncd.secrets'
api POST a=rsync_c 'on=1'
check "rsync_c 1: module [c] of the sauvegarde account" 'grep -q "^RSYNC_C=1" "$R"/etc/diet.conf && awk "/^\\[c\\]/,0" "$R"/etc/rsyncd.conf | grep -q "auth users = sauvegarde"'
api POST a=rsync_c 'on=0'
check "rsync_c 0: module [c] removed" '! grep -q "^\[c\]" "$R"/etc/rsyncd.conf && grep -q "^\[carol\]" "$R"/etc/rsyncd.conf'
api POST a=rsync_pw 'pw=abc'
check "rsync_pw: too short refused" '[ "$ST" = 400 ]'
api POST a=svc_set 's=rsync&on=0'
check "svc_set rsync 0: stop, Avahi announcement removed, avahi reloaded" '[ ! -e "$R"/etc/avahi/services/rsync.service ] && [ -e "$R"/etc/avahi/services/rsync.service.off ] && grep -q "S61rsyncd stop" "$R"/cmd.log && grep -q "S50avahi-daemon reload" "$R"/cmd.log'
api POST a=svc_set 's=rsync&on=1'
check "svc_set rsync 1: announcement back, start" '[ -e "$R"/etc/avahi/services/rsync.service ] && grep -q "S61rsyncd start" "$R"/cmd.log'
api POST a=svc_set 's=avahi&on=0'
check "svc_set avahi 0" 'grep -q "^SVC_AVAHI=0" "$R"/etc/diet.conf && grep -q "S50avahi-daemon stop" "$R"/cmd.log'
api POST a=svc_set 's=webdav&on=0'
check "svc_set webdav 0: WebDAV instance stopped, announcement removed" '[ "$ST" = 200 ] && grep -q "^SVC_WEBDAV=0" "$R"/etc/diet.conf && grep -q "S51webdav stop" "$R"/cmd.log && [ -e "$R"/etc/avahi/services/webdav.service.off ]'
api GET a=services
check "services: states read back" "json 'j[\"webdav\"][\"on\"]==0 and j[\"avahi\"][\"on\"]==0 and j[\"rsync\"][\"pw\"]==1 and j[\"rsync\"][\"c\"]==0 and j[\"minidlna\"][\"name\"]==\"Salon TV\"'"
api POST a=svc_set 's=sshd&on=0'
check "svc_set: unknown service refused" '[ "$ST" = 400 ]'
api POST a=svc_set "s=webdav&on=$(enc '1;reboot')"
check "svc_set: invalid value refused" '[ "$ST" = 400 ]'
api POST a=svc_set 's=rsync&on=0' ''
check "svc_set without X-Diet refused (403)" '[ "$ST" = 403 ]'
api POST a=svc_set 's=webdav&on=1'
check "svc_set webdav 1: instance started, announcement back" 'grep -q "S51webdav start" "$R"/cmd.log && [ -e "$R"/etc/avahi/services/webdav.service ]'
check "lighttpd.conf: /webdav proxied to 127.0.0.1:8081, outside the interface account" 'grep -qF "\"host\" => \"127.0.0.1\", \"port\" => 8081" "$SRC"/etc/lighttpd/lighttpd.conf && grep -qF "\$HTTP[\"url\"] !~ \"^/webdav(/|\$)\" {" "$SRC"/etc/lighttpd/lighttpd.conf'
# init scripts: a service set to 0 in diet.conf does not start
for s in S50avahi-daemon:AVAHI S51webdav:WEBDAV S60minidlnad:MINIDLNA S61rsyncd:RSYNC S60nfs:NFS; do
	f=$BOARD/etc/init.d/${s%%:*}; [ -e "$f" ] || f=$SRC/etc/init.d/${s%%:*}; : > "$R"/cmd.log
	sed -i "s/^SVC_${s#*:}=.*/SVC_${s#*:}=0/" "$R"/etc/diet.conf
	sed "s#/etc/#$R/etc/#g; s#/var/#$R/var/#g; s#/usr/sbin/avahi-daemon#start-stop-daemon#" "$f" | PATH="$R/bin:$PATH" sh -s start >/dev/null
	check "${s%%:*}: no start if SVC_${s#*:}=0" '[ ! -s "$R"/cmd.log ]'
	sed -i "s/^SVC_${s#*:}=.*/SVC_${s#*:}=1/" "$R"/etc/diet.conf
	sed "s#/etc/#$R/etc/#g; s#/var/#$R/var/#g; s#/usr/sbin/avahi-daemon#start-stop-daemon#" "$f" | PATH="$R/bin:$PATH" sh -s start >/dev/null
	check "${s%%:*}: start if SVC_${s#*:}=1" '[ -s "$R"/cmd.log ]'
done

# NFS on/off (Services card): S60nfs of the overlay, exports kept and editable
f=$BOARD/etc/init.d/S60nfs; : > "$R"/cmd.log
sed "s#/etc/#$R/etc/#g; s#/var/#$R/var/#g" "$f" | PATH="$R/bin:$PATH" sh -s stop >/dev/null
check "S60nfs stop: mountd and statd stopped, nfsd threads stopped by rpc.nfsd 0, exports withdrawn" 'grep -q "killall -q rpc.mountd" "$R"/cmd.log && grep -qx "rpc.nfsd 0" "$R"/cmd.log && grep -q "exportfs -au" "$R"/cmd.log && grep -q "killall -q rpc.statd" "$R"/cmd.log'
: > "$R"/cmd.log
api POST a=svc_set 's=nfs&on=0'
check "svc_set nfs 0: SVC_NFS=0 in diet.conf, S60nfs stop" '[ "$ST" = 200 ] && grep -q "^SVC_NFS=0" "$R"/etc/diet.conf && grep -q "S60nfs stop" "$R"/cmd.log'
echo 0 > "$R"/proc/fs/nfsd/threads
api GET a=services
check "services: nfs off and not running" "json 'j[\"nfs\"]=={\"on\":0,\"run\":0}'"
api GET a=status
check "status: nfs_on 0 (Restart NFS disabled)" "json 'j[\"nfs_on\"]==0'"
api POST a=nfsd ''
check "Restart NFS refused while NFS is stopped (409)" '[ "$ST" = 409 ] && ! grep -q "S60nfs restart" "$R"/cmd.log'
: > "$R"/cmd.log
api POST a=nfs_add "path=$(enc /c/films)&client=$(enc 10.2.0.0/16)"
check "nfs_add while NFS is stopped: export written, no exportfs, message says so" '[ "$ST" = 200 ] && grep -qx "/c/films 10.2.0.0/16(rw,no_subtree_check)" "$R"/etc/exports && ! grep -q exportfs "$R"/cmd.log && json "\"stopped\" in j[\"msg\"]"'
api POST a=nfs_del "path=$(enc /c/films)&client=$(enc 10.2.0.0/16)"
check "nfs_del while NFS is stopped: export removed" '[ "$ST" = 200 ] && ! grep -q films "$R"/etc/exports'
api POST a=svc_set 's=nfs&on=1'
echo 8 > "$R"/proc/fs/nfsd/threads
api GET a=services
check "svc_set nfs 1: S60nfs start, nfs on and running" 'grep -q "S60nfs start" "$R"/cmd.log && grep -q "^SVC_NFS=1" "$R"/etc/diet.conf'
check "services: nfs on and running" "json 'j[\"nfs\"]=={\"on\":1,\"run\":1}'"
api POST a=nfsd ''
check "Restart NFS allowed again" '[ "$ST" = 200 ] && grep -q "S60nfs restart" "$R"/cmd.log'

# ---------- storage: X-RAID (compatibility) and md, through nas-raid ----------
# real nas-raid and xraid-info built for the host, on fake X-RAID images
XC=$HERE/../../xraid-compat
cc -O2 -o "$R"/bin/xraid-info "$XC"/src/xraid-info.c && ln -s "$XC"/src/nas-raid "$R"/bin/nas-raid
for s in clean dirty degraded md; do python3 "$XC"/tests/make-images.py "$R/img/$s" $s > /dev/null; done
stk() {	# stk scenario "content of nas-raid.mode"
	export NAS_RAID_DISKS="$(ls "$R/img/$1"/*.img | tr '\n' ' ')"
	echo "$2" > "$R"/var/run/nas-raid.mode; rm -f "$R"/var/run/xraid.json
	api GET a=storage
}
stk clean xraid-rw
check "storage, clean X-RAID: rw, 2 sections, base/mirror" "json 'j[\"mode\"]==\"xraid-rw\" and j[\"xraid\"][\"mode\"]==\"rw\" and len(j[\"xraid\"][\"sections\"])==2 and j[\"xraid\"][\"mirror\"].endswith(\"sda.img\")'"
stk dirty 'xraid-ro unclean_shutdown'
check "storage, dirty X-RAID: read-only, reason unclean_shutdown" "json 'j[\"mode\"]==\"xraid-ro\" and [r[\"code\"] for r in j[\"xraid\"][\"reasons\"]]==[\"unclean_shutdown\"]'"
stk degraded 'xraid-ro missing_disk'
check "storage, degraded X-RAID: read-only, a single disk" "json 'j[\"xraid\"][\"mirror\"]==\"\" and j[\"xraid\"][\"reasons\"][0][\"code\"]==\"missing_disk\"'"
stk md md
check "storage md: mode md" "json 'j[\"mode\"]==\"md\" and j[\"migration\"][\"step\"]==\"\"'"
stk clean xraid-rw
cp "$R"/proc/mounts "$R"/mounts.bak; echo '/dev/root / ext4 rw 0 0' > "$R"/proc/mounts	# simulated /c too full for the image
api POST a=raid_plan 'op=migrate'
mv "$R"/mounts.bak "$R"/proc/mounts
check "raid_plan migrate: dry run (mdadm --create, rsync)" 'case "$OUT" in *"mdadm --create /dev/md/donnees"*"rsync -aH"*) true;; *) false;; esac'
api POST a=raid_run 'op=migrate&yes=1'
check "raid_run: refused without phrase" '[ "$ST" = 400 ]'
api POST a=raid_run 'op=migrate&confirm=MIGRATE'
check "raid_run: refused without the second confirmation" '[ "$ST" = 400 ]'
api POST a=raid_run "op=migrate&confirm=$(enc "MIGRATE';reboot")&yes=1"
check "raid_run: phrase with forbidden characters refused" '[ "$ST" = 400 ]'
api POST a=raid_run 'op=create&d=sdz&confirm=ERASE+sdz&yes=1'
check "raid_run: unknown disk refused" '[ "$ST" = 400 ]'
api POST a=raid_plan 'op=rm'
check "raid_plan: unknown operation refused" '[ "$ST" = 400 ]'
api POST a=raid_verify ''
check "raid_verify: started" '[ "$ST" = 200 ]'
sleep 3	# the check (sparse 4 GB images) writes in $R: let it finish
api GET 'a=log&f=storage'
check "storage log: nas-raid log" '[ "$ST" = 200 ]'
# "allow writing on the X-RAID" switch: real nas-raid remount on the images,
# dm/LVM/fuse2fs simulated; umount refuses while $R/busy exists (open files)
for c in dmsetup lvm fuse2fs; do stub $c; done
stub umount '[ ! -e "$DIET_ROOT/busy" ]'
i=0; while [ $i -lt 30 ] && grep -qs '^running' "$R"/var/lib/nas-raid/verify.state; do sleep 1; i=$((i + 1)); done
rm -f "$R"/var/lib/nas-raid/xraid-dirty
export NAS_RAID_DISKS="$(ls "$R/img/clean"/*.img | tr '\n' ' ')"
printf '# local settings\nSAMPLES=8\nVERIFY_MAX_DAYS=3\n' > "$R"/etc/nas-raid.conf
echo 'xraid-ro rw_disabled' > "$R"/var/run/nas-raid.mode
api GET a=storage
check "xraid_rw: state read from nas-raid.conf (no), X-RAID read-only" "json 'j[\"xraid_rw\"]==\"no\" and j[\"mode\"]==\"xraid-ro\"'"
api POST a=xraid_rw 'on=1'
check "xraid_rw on: refused without the typed word" '[ "$ST" = 400 ] && ! grep -q XRAID_RW "$R"/etc/nas-raid.conf'
api POST a=xraid_rw 'on=1&confirm=WRITE'
check "xraid_rw on: refused without the second confirmation" '[ "$ST" = 400 ] && ! grep -q XRAID_RW "$R"/etc/nas-raid.conf'
api POST a=xraid_rw 'on=1&confirm=write&yes=1'
check "xraid_rw on: wrong word refused" '[ "$ST" = 400 ]'
: > "$R"/cmd.log
api POST a=xraid_rw 'on=1&confirm=WRITE&yes=1'
check "xraid_rw on: XRAID_RW=yes written once, other keys and comment kept" '[ "$ST" = 200 ] && [ "$(grep -c "^XRAID_RW=" "$R"/etc/nas-raid.conf)" = 1 ] && grep -qx "XRAID_RW=yes" "$R"/etc/nas-raid.conf && grep -qx "SAMPLES=8" "$R"/etc/nas-raid.conf && grep -qx "VERIFY_MAX_DAYS=3" "$R"/etc/nas-raid.conf && grep -qx "# local settings" "$R"/etc/nas-raid.conf && [ ! -e "$R"/etc/nas-raid.conf.tmp ]'
check "xraid_rw on: services stopped, /c unmounted then mounted rw, services started" 'grep -q "S70ksmbd stop" "$R"/cmd.log && grep -q "S60nfs stop" "$R"/cmd.log && grep -q "S60minidlnad stop" "$R"/cmd.log && grep -q "S61rsyncd stop" "$R"/cmd.log && grep -q "S51webdav stop" "$R"/cmd.log && grep -q "^umount /c" "$R"/cmd.log && grep -q "fuse2fs -o allow_other" "$R"/cmd.log && grep -q "S70ksmbd start" "$R"/cmd.log && awk "/umount \/c/ { u = NR } /S70ksmbd start/ { s = NR } /S70ksmbd stop/ { t = NR } END { exit !(t < u && u < s) }" "$R"/cmd.log'
api GET a=storage
check "xraid_rw on: mode xraid-rw, switch on" "json 'j[\"mode\"]==\"xraid-rw\" and j[\"xraid_rw\"]==\"yes\"'"
# a safeguard refuses (RAIDiator unclean shutdown): read-only is kept, with the reason
export NAS_RAID_DISKS="$(ls "$R/img/dirty"/*.img | tr '\n' ' ')"
rm -f "$R"/var/lib/nas-raid/xraid-dirty "$R"/var/lib/nas-raid/xraid-verified "$R"/var/run/xraid.json
echo 'xraid-ro unclean_shutdown' > "$R"/var/run/nas-raid.mode
api POST a=xraid_rw 'on=1&confirm=WRITE&yes=1'
check "xraid_rw on, safeguard refuses: answer says read-only and why" '[ "$ST" = 200 ] && json "\"xraid-ro\" in j[\"msg\"] and \"unclean_shutdown\" in j[\"msg\"]"'
api GET a=storage
check "xraid_rw on, safeguard refuses: mode stays xraid-ro, reason shown" "json 'j[\"mode\"]==\"xraid-ro\" and j[\"reasons\"]==\"unclean_shutdown\" and j[\"xraid_rw\"]==\"yes\"'"
# open files on /c: umount refused, nothing changed
touch "$R"/busy; : > "$R"/cmd.log
api POST a=xraid_rw 'on=0'
check "xraid_rw off, /c busy: refused (409), XRAID_RW unchanged, services started again" '[ "$ST" = 409 ] && grep -qx "XRAID_RW=yes" "$R"/etc/nas-raid.conf && grep -q "S70ksmbd start" "$R"/cmd.log && ! grep -q "dmsetup remove" "$R"/cmd.log'
rm -f "$R"/busy
export NAS_RAID_DISKS="$(ls "$R/img/clean"/*.img | tr '\n' ' ')"; rm -f "$R"/var/run/xraid.json
echo 'xraid-rw' > "$R"/var/run/nas-raid.mode
api POST a=xraid_rw 'on=0'
check "xraid_rw off: no heavy confirmation, XRAID_RW=no, remounted read-only (rw_disabled)" '[ "$ST" = 200 ] && grep -qx "XRAID_RW=no" "$R"/etc/nas-raid.conf && grep -qx "SAMPLES=8" "$R"/etc/nas-raid.conf && grep -q "xraid-ro rw_disabled" "$R"/var/run/nas-raid.mode'
echo md > "$R"/var/run/nas-raid.mode
api POST a=xraid_rw 'on=1&confirm=WRITE&yes=1'
check "xraid_rw: refused on an md volume (409)" '[ "$ST" = 409 ] && grep -qx "XRAID_RW=no" "$R"/etc/nas-raid.conf'
api POST a=xraid_rw 'on=2'
check "xraid_rw: invalid value refused" '[ "$ST" = 400 ]'
echo 'xraid-rw' > "$R"/var/run/nas-raid.mode; rm -f "$R"/etc/nas-raid.conf "$R"/etc/nas-raid.conf.bak "$R"/var/lib/nas-raid/xraid-dirty
unset NAS_RAID_DISKS

# ---------- collector cache (S95diet: the API with DIET_COLLECT=1) ----------
C=$R/var/run/diet
DIET_COLLECT=once $SH "$SRC"/www/cgi-bin/api
cache_ok=1; for k in status all services shares nfs sys users config storage; do [ -s "$C/$k.json" ] && jsonok < "$C/$k.json" || { cache_ok=; echo "  $k.json missing or invalid"; }; done
check "collector (one round): valid JSON answers in /var/run/diet" '[ -n "$cache_ok" ] && [ ! -e "$C"/.status.tmp ]'
OUT=$(cat "$C"/all.json)
check "collector: all = status + storage + history" "json 'j[\"status\"][\"host\"]==\"nas-test\" or j[\"status\"][\"host\"]==\"readynas\"' && json 'j[\"storage\"][\"mode\"]==\"xraid-rw\" and isinstance(j[\"hist\"], str)'"
mkfifo "$C"/wake; exec 3<> "$C"/wake
echo $$ > "$C"/pid	# collector "running": this shell
echo cache-test > "$R"/proc/sys/kernel/hostname
api GET a=status
check "cache present: read as is (not recomputed)" "json 'j[\"host\"]==\"readynas\"'"
check "cache: request noted, collector woken up (seen)" '[ -s "$C"/seen ] && [ "$(timeout 2 head -n 1 <&3)" = seen ]'
: > "$C"/active
api GET a=all
check "cache: ?a=all read, no wake-up if the collector is active" "json 'j[\"status\"][\"host\"]==\"readynas\" and \"mode\" in j[\"storage\"]' && ! timeout 1 head -n 1 <&3 >/dev/null"
rm -f "$C"/status.json
api GET a=status
check "cache missing: direct computation" "json 'j[\"host\"]==\"cache-test\"'"
DIET_COLLECT=once $SH "$SRC"/www/cgi-bin/api
echo 99999999 > "$C"/pid
api GET a=status
check "collector stopped: cache ignored, direct computation" "json 'j[\"host\"]==\"cache-test\"'"
echo $$ > "$C"/pid
echo readynas > "$R"/proc/sys/kernel/hostname
api POST a=share_add 'name=cache'
check "POST: cache emptied, invalid mark, collector woken up (all)" '[ "$ST" = 200 ] && ! ls "$C"/*.json >/dev/null 2>&1 && [ -e "$C"/invalid ] && [ "$(timeout 2 head -n 1 <&3)" = all ]'
api GET a=shares
check "after POST: up-to-date direct read" "json 'any(s[\"name\"]==\"cache\" for s in j)'"
DIET_COLLECT=once $SH "$SRC"/www/cgi-bin/api
check "collector: a round after the POST removes invalid and fills the cache" '[ ! -e "$C"/invalid ] && grep -q "\"cache\"" "$C"/shares.json'
api POST a=share_del 'name=cache'
exec 3>&-
# real loop (ash read -t): host busybox if available
if command -v busybox >/dev/null 2>&1; then
	rm -f "$C"/*.json "$C"/pid "$C"/seen "$C"/active
	DIET_COLLECT=1 busybox sh "$SRC"/www/cgi-bin/api & CP=$!
	i=0; while [ $i -lt 50 ] && [ ! -s "$C"/all.json ]; do sleep 0.2; i=$((i + 1)); done
	check "collector (busybox ash loop): cache filled, pid written" '[ -s "$C"/all.json ] && [ "$(cat "$C"/pid)" = "$CP" ] && jsonok < "$C"/status.json'
	rm -f "$C"/shares.json; echo all 1<> "$C"/wake
	i=0; while [ $i -lt 50 ] && [ ! -s "$C"/shares.json ]; do sleep 0.2; i=$((i + 1)); done
	check "collector (loop): woken up by \"all\", cache recomputed" '[ -s "$C"/shares.json ]'
	kill $CP; i=0; while [ $i -lt 25 ] && kill -0 $CP 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
	check "collector (loop): clean stop (TERM), cache removed" '! kill -0 $CP 2>/dev/null && [ ! -e "$C"/pid ] && ! ls "$C"/*.json >/dev/null 2>&1'
fi

# ---------- misc ----------
api POST a=reboot '' ''
check "POST without X-Diet refused (403)" '[ "$ST" = 403 ]'
api GET 'a=md&d=md0'
check "md: mdadm --detail" 'case "$OUT" in *"State : clean"*) true;; *) false;; esac'
api GET 'a=md&d=md9'
check "md: unknown volume refused" '[ "$ST" = 400 ]'
api GET 'a=smart&d=sda'
check "smart without smartctl: drivetemp and dmesg" 'case "$OUT" in *"38 °C (drivetemp)"*"[sda]"*) true;; *) false;; esac'
api GET 'a=smart&d=..%2Fetc'
check "smart: unknown disk refused" '[ "$ST" = 400 ]'

# ---------- diet-hwmon (one round) ----------
echo "$DEGRADED" > "$R"/proc/mdstat
echo 'TG_TOKEN=1:x
TG_CHAT=1' > "$R"/etc/diet-notify.conf
PATH="$R/bin:$PATH" DIET_ONCE=1 $SH "$SRC"/usr/sbin/diet-hwmon
sleep 1
check "diet-hwmon: history written" 'grep -q " 45 1800 120$" "$R"/var/run/hwmon.hist'
check "diet-hwmon: alert logged and sent" 'grep -q "RAID degraded" "$R"/var/run/alert.last && grep -q "ALERT" "$R"/var/log/diet.log && grep -q "wget .*sendMessage" "$R"/cmd.log'

check "all JSON answers of the API are valid ($NJSON)" '[ -z "$JSONKO" ] || { echo "  invalid:$JSONKO"; false; }'
echo "$((N - FAILS))/$N tests passed (root: $R)"
[ $FAILS -eq 0 ] && rm -rf "$R"
[ $FAILS -eq 0 ]
