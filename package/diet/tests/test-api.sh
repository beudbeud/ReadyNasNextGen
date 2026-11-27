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
# By default only SMB, the web interface and SSH run (SVC_*=0); the tests below
# exercise every service, so they are switched on here.
SVC_DEFAULTS=$(grep '^SVC_' "$R"/etc/diet.conf)
sed -i 's/^\(SVC_[A-Z]*\)=0/\1=1/' "$R"/etc/diet.conf
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
# wget: the minidlnad status page (file counts, plain HTTP on 127.0.0.1)
stub wget 'case "$*" in *127.0.0.1:8200*) echo "<tr><td>Audio files</td><td>12</td></tr><tr><td>Video files</td><td>3</td></tr><tr><td>Image files</td><td>40</td></tr>";; esac'
# curl: HTTPS (Telegram); refuses to run without certificate checking
stub curl 'case "$*" in *--cacert\ /etc/ssl/certs/ca-certificates.crt*) ;; *) echo "no --cacert" >&2; exit 60;; esac; case "$*" in *--insecure*|*\ -k\ *) exit 60;; esac; echo "{\"ok\":true}"'
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
for s in S03fan S60nfs S70ksmbd S95diet S50avahi-daemon S51webdav S60minidlnad S61rsyncd S50lighttpd; do
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

# ---------- first setup (/cgi-bin/setup, no web administrator yet) ----------
# setup METHOD [body] [X-Diet] [Accept-Language]: the API through its "setup" name
setup() {
	body=${2:-}
	raw=$(printf '%s' "$body" | SCRIPT_NAME=/cgi-bin/setup REQUEST_METHOD=$1 QUERY_STRING="${SQ:-}" CONTENT_LENGTH=${#body} \
		HTTP_X_DIET=${3-1} HTTP_ACCEPT_LANGUAGE=${4:-} REMOTE_ADDR=10.0.0.9 $SH "$SRC/www/cgi-bin/setup")
	ST=$(printf '%s\n' "$raw" | sed -n 's/^Status: \([0-9]*\).*/\1/p' | head -n 1); ST=${ST:-200}
	OUT=$(printf '%s\n' "$raw" | tr -d '\r' | sed '1,/^$/d')
}
E=$R/etc; HTP=$E/lighttpd/htpasswd
printf 'root::::::::\nnobody:*:::::::\n' > "$E"/shadow
APW='Adm1n pw+&%é'; RPW='r00t pw=&x'; KEY1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl user@pc'
check "setup: the API has a \"setup\" name (link)" '[ -L "$SRC"/www/cgi-bin/setup ] && [ "$(readlink "$SRC"/www/cgi-bin/setup)" = api ]'
setup GET
check "setup, no account: page served without authentication" '[ "$ST" = 200 ] && case "$OUT" in *"<h1>First setup</h1>"*"name=\"pw\""*"name=\"rootpw\""*"name=\"key\""*) true;; *) false;; esac'
setup GET '' 1 'fr-FR,fr;q=0.9'
check "setup: page in the browser language (Accept-Language fr)" 'case "$OUT" in *"Première configuration"*) true;; *) false;; esac'
SQ='a=status' setup GET
check "setup: no other action reachable through this name (a=status gives the page)" 'case "$OUT" in *"First setup"*) true;; *) false;; esac && case "$OUT" in *uptime*) false;; *) true;; esac'
SQ='a=reboot' setup POST "pw=$(enc "$APW")" ''
check "setup POST without X-Diet refused (403), nothing written" '[ "$ST" = 403 ] && [ ! -e "$HTP" ]'
setup POST 'pw=abc'
check "setup: password too short refused, nothing written" '[ "$ST" = 400 ] && [ ! -e "$HTP" ]'
setup POST "pw=$(enc "$APW")&key=$(enc "command=\"sh\" $KEY1")"
check "setup: key with options refused before anything is written" '[ "$ST" = 400 ] && [ ! -e "$HTP" ] && grep -q "^root::" "$E"/shadow'
setup POST "pw=$(enc "$APW")&host=Bad_Name"
check "setup: invalid name refused, nothing written" '[ "$ST" = 400 ] && [ ! -e "$HTP" ]'
: > "$R"/cmd.log
setup POST "pw=$(enc "$APW")&host=nas-setup&rootpw=$(enc "$RPW")&key=$(enc "$KEY1
")"
check "setup: saved (200)" '[ "$ST" = 200 ]'
check "setup: admin account in htpasswd (SHA-512, 600, no temporary file left)" 'grep -q "^admin:[\$]6[\$]" "$HTP" && [ "$(wc -l < "$HTP")" = 1 ] && [ "$(stat -c %a "$HTP")" = 600 ] && ! ls "$HTP".* >/dev/null 2>&1'
H=$(cut -d: -f2- "$HTP"); S=$(echo "$H" | cut -d'$' -f3)
check "setup: htpasswd hash is the administrator password" '[ "$(printf "%s" "$APW" | openssl passwd -6 -salt "$S" -stdin)" = "$H" ]'
check "setup: root password in shadow (SHA-512, 600), other lines kept" 'grep -q "^root:[\$]6[\$]" "$E"/shadow && grep -q "^nobody:" "$E"/shadow && [ "$(stat -c %a "$E"/shadow)" = 600 ]'
check "setup: SSH key in /root/.ssh/authorized_keys (700/600)" '[ "$(cat "$R"/root/.ssh/authorized_keys)" = "$KEY1" ] && [ "$(stat -c %a "$R"/root/.ssh)" = 700 ] && [ "$(stat -c %a "$R"/root/.ssh/authorized_keys)" = 600 ]'
check "setup: NAS name applied" '[ "$(cat "$E"/hostname)" = nas-setup ] && grep -q "netbios name = NAS-SETUP" "$E"/ksmbd/ksmbd.conf'
i=0; while [ $i -lt 30 ] && ! grep -q "S50lighttpd restart" "$R"/cmd.log; do sleep 0.2; i=$((i + 1)); done
check "setup: lighttpd restarted (end of the redirection to the setup page)" 'grep -q "S50lighttpd restart" "$R"/cmd.log'
check "setup: passwords never logged nor stored in clear" '! grep -rqF "$APW" "$R" && ! grep -rqF "$RPW" "$R" && ! grep -rqF "r00t" "$R" && ! grep -rqF "Adm1n" "$R"'
cp "$HTP" "$R"/htp.before
setup GET
check "setup, account exists: page refused (403), no form" '[ "$ST" = 403 ] && case "$OUT" in *"<form"*) false;; *) true;; esac'
setup POST "pw=$(enc other-password)&rootpw=$(enc other-password)"
check "setup, account exists: action refused (403), nothing changed" '[ "$ST" = 403 ] && cmp -s "$HTP" "$R"/htp.before && ! grep -q "other-password" "$E"/shadow'
# race: several browsers at once, the first one wins, the others get 409 (or 403)
for n in 1 2 3 4 5 6; do
	rm -f "$HTP" "$R"/race.*
	for b in 1 2 3; do
		( setup POST "pw=browser-$b"; echo "$ST" > "$R/race.$b" ) &
	done
	wait
	W=$(grep -l '^200$' "$R"/race.* | sed 's/.*\.//'); NW=$(echo "$W" | grep -c .)
	S=$(cut -d'$' -f3 "$HTP")
	check "setup race $n: one winner, the others refused, htpasswd = winner's password" '[ "$NW" = 1 ] && [ "$(grep -c "^40[39]$" "$R"/race.*  | awk -F: "{ s += \$2 } END { print s }")" = 2 ] && [ "$(wc -l < "$HTP")" = 1 ] && [ "admin:$(printf "%s" "browser-$W" | openssl passwd -6 -salt "$S" -stdin)" = "$(cat "$HTP")" ] && ! ls "$HTP".* >/dev/null 2>&1'
done
cp "$R"/htp.before "$HTP"
# lighttpd: exception limited to /cgi-bin/setup, redirection only without an account
LC=$SRC/etc/lighttpd/lighttpd.conf
check "lighttpd.conf: authentication everywhere but /webdav, exactly /cgi-bin/setup and the token paths" 'grep -qxF "\$HTTP[\"url\"] !~ \"^/(webdav(/|\$)|cgi-bin/(setup|v1)\$|api/v1/|metrics\$)\" {" "$LC" && [ "$(grep -c "auth.require" "$LC")" = 1 ]'
check "lighttpd.conf: mod_redirect before mod_auth (port 80 and setup redirections without a password)" '[ "$(grep -n "\"mod_redirect\"" "$LC" | cut -d: -f1)" -lt "$(grep -n "\"mod_auth\"" "$LC" | cut -d: -f1)" ]'
FC=$(sed "s#/etc/lighttpd/htpasswd#$R/nohtp#g" "$SRC"/etc/init.d/S50lighttpd | sh -s firstconf)
check "S50lighttpd firstconf, no account: / redirected to /cgi-bin/setup (302)" 'case "$FC" in *"\"^/(index\\.html)?\$\""*"redirect-code = 302"*"\"/cgi-bin/setup\""*) true;; *) false;; esac'
check "S50lighttpd firstconf, account: nothing" '[ -z "$(sed "s#/etc/lighttpd/htpasswd#$HTP#g" "$SRC"/etc/init.d/S50lighttpd | sh -s firstconf)" ]'

# ---------- SSH access (Settings) ----------
KEY2='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTY= other'
NPW='n3w-root+pw'
api POST a=ssh_set "rootpw=$(enc "$NPW")&key=$(enc "$KEY2")"
check "ssh_set: root password changed, key appended" '[ "$ST" = 200 ] && [ "$(grep -c . "$R"/root/.ssh/authorized_keys)" = 2 ] && tail -n 1 "$R"/root/.ssh/authorized_keys | grep -qxF "$KEY2"'
S=$(grep '^root:' "$E"/shadow | cut -d'$' -f3)
check "ssh_set: shadow hash is the new password, never logged" '[ "$(grep "^root:" "$E"/shadow | cut -d: -f2)" = "$(printf "%s" "$NPW" | openssl passwd -6 -salt "$S" -stdin)" ] && ! grep -rqF "$NPW" "$R"'
api POST a=ssh_set "key=$(enc "$KEY2")"
check "ssh_set: same key not added twice" '[ "$(grep -c . "$R"/root/.ssh/authorized_keys)" = 2 ]'
for k in "from=\"*\" $KEY2" 'ssh-dss AAAA' 'ssh-ed25519 AAA;reboot' "$KEY1
$KEY2"; do
	api POST a=ssh_set "key=$(enc "$k")"
	check "ssh_set: invalid key refused ($(echo "$k" | head -n 1 | cut -c1-20))" '[ "$ST" = 400 ] && [ "$(grep -c . "$R"/root/.ssh/authorized_keys)" = 2 ]'
done
api POST a=ssh_set 'rootpw=abc'
check "ssh_set: short password refused" '[ "$ST" = 400 ]'
api POST a=ssh_set ''
check "ssh_set: nothing to save refused" '[ "$ST" = 400 ]'
api POST a=ssh_set "rootpw=$(enc "$NPW")" ''
check "ssh_set without X-Diet refused (403)" '[ "$ST" = 403 ]'
api GET a=sys
check "sys: root password set, 2 SSH keys" "json 'j[\"rootpw\"]==1 and j[\"keys\"]==2'"
echo readynas > "$E"/hostname

# ---------- status ----------
api GET a=status
check "status: valid JSON" "json 'True'"
check "status: healthy RAID1 UU" "json 'j[\"md\"][0][\"map\"]==\"UU\" and j[\"md\"][0][\"level\"]==\"raid1\"'"
check "status: 2 disks, drivetemp, bays" "json '[d[\"temp\"] for d in j[\"disks\"]]==[38,41] and [d[\"bay\"] for d in j[\"disks\"]]==[1,2]'"
# the system USB stick, named before the SATA disks (seen on the NAS: sda): never a bay
USBD="$R/sys/devices/pci0000:00/0000:00:17.2/usb1/1-3/1-3:1.0/host0/target0:0:0/0:0:0:0"
mkdir -p "$USBD" "$R/sys/block/sd0"; echo "USB Flash Drive" > "$USBD/model"; ln -s "$USBD" "$R/sys/block/sd0/device"
api GET a=status
check "status: the USB stick is not listed as a disk (no bay)" "json '[d[\"dev\"] for d in j[\"disks\"]]==[\"sda\",\"sdb\"] and [d[\"bay\"] for d in j[\"disks\"]]==[1,2]'"
rm -rf "$R/sys/block/sd0"; api GET a=status
check "status: fan (padre-fan)" "json 'j[\"temp\"]==45 and j[\"fan\"]==1800 and j[\"pwm\"]==120 and j[\"svc\"][\"fan\"]==1'"
check "status: services" "json 'j[\"svc\"][\"ksmbd\"]==1 and j[\"svc\"][\"nfs\"]==1 and j[\"svc\"][\"ntpd\"]==0 and j[\"svc\"][\"hwmon\"]==0'"
check "status: /c and memory" "json 'j[\"c\"][\"size\"]==1922000000 and j[\"mem\"][\"avail\"]==180000 and j[\"ip\"]==\"10.0.0.2\"'"
rm -f "$R"/var/run/diet/cnt.prev; api GET a=status
check "status: no previous sample, rate null (the page waits for its own)" "json 'j[\"rate\"] is None'"
echo "0 0 0 0 0 0 0" > "$R"/var/run/diet/cnt.prev; api GET a=status
check "status: first answer carries rates since the previous sample (cpu %, bytes/s)" "json 'j[\"rate\"][\"dt\"]==j[\"t\"] and j[\"rate\"][\"cpu\"]==j[\"cnt\"][\"busy\"]*100//j[\"cnt\"][\"tot\"] and j[\"rate\"][\"rx\"]==j[\"cnt\"][\"rx\"]*100//j[\"t\"] and j[\"rate\"][\"rd\"]==j[\"cnt\"][\"rd\"]*51200//j[\"t\"]'"
echo "x y" > "$R"/var/run/diet/cnt.prev; api GET a=status
check "status: unreadable previous sample ignored, rewritten" "json 'j[\"rate\"] is None' && read -r a _ < \"\$R\"/var/run/diet/cnt.prev && [ \"\$a\" -gt 0 ]"
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
check "config: reads fan.conf and diet.conf" "json 'j[\"FAN_PWM_MIN\"]==30 and j[\"PERIOD\"]==60 and j[\"SPINDOWN_MIN\"]==30'"
api POST a=config 'FAN_PWM_MIN=60&TEMP_HIGH=52&SPINDOWN_MIN=10'
check "config: saved (200)" '[ "$ST" = 200 ]'
check "config: fan.conf changed, comment kept" 'grep -q "^FAN_PWM_MIN=60 .*# idle setpoint" "$R"/etc/fan.conf && grep -q "^TEMP_HIGH=52" "$R"/etc/fan.conf'
check "config: padre-fan restarted, spin-down applied" 'grep -q "S03fan restart" "$R"/cmd.log && grep -q "hdparm -S 120 /dev/sda" "$R"/cmd.log'
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
check "notify_test: sent (simulated curl, certificate checked)" '[ "$ST" = 200 ] && grep -q "curl .*--cacert /etc/ssl/certs/ca-certificates.crt.*api.telegram.org/bot123456:ABC-test/sendMessage" "$R"/cmd.log'
api POST a=sys_set "host=nas-test&lang=en&tz=UTC0&net=dhcp&tgchat="
check "sys_set: DHCP and Telegram disabled" 'grep -q "iface eth0 inet dhcp" "$R"/etc/network/interfaces && [ ! -e "$R"/etc/diet-notify.conf ]'
api POST a=sys_set 'host=Bad_Name'
check "sys_set: invalid name refused" '[ "$ST" = 400 ] && [ "$OUT" = "Invalid NAS name: lowercase letters, digits and dashes" ]'
api POST 'a=sys_set&l=fr' 'host=Bad_Name'
check "API error in French (l=fr)" '[ "$ST" = 400 ] && [ "$OUT" = "Nom du NAS invalide : minuscules, chiffres et tirets" ]'
api POST 'a=sys_set&l=de' 'host=Bad_Name'
check "API error in German (l=de)" '[ "$ST" = 400 ] && [ "$OUT" = "Ungültiger NAS-Name: Kleinbuchstaben, Ziffern und Bindestriche" ]'

# ---------- SMB3 encryption (smb3 encryption of [global], ksmbd.conf) ----------
K=$R/etc/ksmbd/ksmbd.conf
printf '\n[photos]\n\tpath = /c/photos\n\tsmb3 encryption = disabled\n' >> "$K"	# a share line that must stay
shares() { awk '/^[ \t]*\[/ { g = (tolower($0) ~ /^[ \t]*\[global\]/) } !g' "$K"; }
SH0=$(shares)
api GET a=sys
check "smb_enc: shipped ksmbd.conf read (disabled)" "json 'j[\"smbenc\"]==\"disabled\"'"
: > "$R"/cmd.log
api POST a=smb_enc 'on=1'
i=0; while [ $i -lt 20 ] && ! grep -q "S70ksmbd restart" "$R"/cmd.log; do sleep 0.1; i=$((i + 1)); done
check "smb_enc on: auto in [global], once, comment and signing kept, ksmbd restarted" '[ "$ST" = 200 ] && [ "$(grep -c "smb3 encryption = auto" "$K")" = 1 ] && grep -q "server signing = auto" "$K" && grep -q "; SMB3 encryption is done" "$K" && grep -q "S70ksmbd restart" "$R"/cmd.log && [ ! -e "$K".tmp ]'
check "smb_enc on: share sections untouched" '[ "$(shares)" = "$SH0" ]'
api GET a=sys
check "smb_enc: read back (auto)" "json 'j[\"smbenc\"]==\"auto\"'"
sed -i '/^[ \t]*smb3 encryption = auto/d' "$K"
api GET a=sys
check "smb_enc: key missing (older install) = ksmbd default auto" "json 'j[\"smbenc\"]==\"auto\"'"
api POST a=smb_enc 'on=0'
check "smb_enc off: missing key added inside [global], shares untouched" '[ "$ST" = 200 ] && awk "/^\[global\]/ { g = 1; next } /^[ \t]*\[/ { g = 0 } g && /smb3 encryption = disabled/ { f = 1 } END { exit !f }" "$K" && [ "$(shares)" = "$SH0" ]'
api GET a=sys
check "smb_enc: read back (disabled)" "json 'j[\"smbenc\"]==\"disabled\"'"
api POST a=smb_enc 'on=mandatory'
check "smb_enc: invalid value refused" '[ "$ST" = 400 ]'
api POST a=smb_enc 'on=1' ''
check "smb_enc without X-Diet refused (403)" '[ "$ST" = 403 ] && grep -q "smb3 encryption = disabled" "$K"'
# SMB signing (server signing of [global]): auto or mandatory
api GET a=sys
check "smb_sign: shipped ksmbd.conf read (auto)" "json 'j[\"smbsign\"]==\"auto\"'"
: > "$R"/cmd.log
api POST a=smb_sign 'v=mandatory'
i=0; while [ $i -lt 20 ] && ! grep -q "S70ksmbd restart" "$R"/cmd.log; do sleep 0.1; i=$((i + 1)); done
check "smb_sign mandatory: in [global], once, other lines kept, ksmbd restarted, journal" '[ "$ST" = 200 ] && [ "$(grep -c "server signing" "$K")" = 1 ] && grep -q "^	server signing = mandatory" "$K" && grep -q "smb3 encryption = disabled" "$K" && grep -q "netbios name = " "$K" && grep -q "S70ksmbd restart" "$R"/cmd.log && [ ! -e "$K".tmp ] && grep -q "SMB: server signing = mandatory" "$R"/var/log/diet.log'
check "smb_sign: share sections untouched" '[ "$(shares)" = "$SH0" ]'
api GET a=sys
check "smb_sign: read back (mandatory)" "json 'j[\"smbsign\"]==\"mandatory\"'"
api POST a=smb_sign 'v=auto'
check "smb_sign auto: replaced in place" '[ "$ST" = 200 ] && [ "$(grep -c "server signing" "$K")" = 1 ] && grep -q "server signing = auto" "$K"'
sed -i 's/server signing = auto/server signing = disabled/' "$K"
api GET a=sys
check "smb_sign: disabled in the file read as auto (same in ksmbd)" "json 'j[\"smbsign\"]==\"auto\"'"
sed -i '/server signing/d' "$K"
api GET a=sys
check "smb_sign: key missing = auto" "json 'j[\"smbsign\"]==\"auto\"'"
api POST a=smb_sign 'v=auto'
check "smb_sign: missing key added inside [global]" '[ "$ST" = 200 ] && awk "/^\[global\]/ { g = 1; next } /^[ \t]*\[/ { g = 0 } g && /server signing = auto/ { f = 1 } END { exit !f }" "$K" && [ "$(shares)" = "$SH0" ]'
for bad in disabled enabled '' 'auto%0Amandatory'; do
	api POST a=smb_sign "v=$bad"
	check "smb_sign: invalid value refused ($bad)" '[ "$ST" = 400 ] && grep -q "server signing = auto" "$K"'
done
api POST a=smb_sign 'v=mandatory' ''
check "smb_sign without X-Diet refused (403)" '[ "$ST" = 403 ] && grep -q "server signing = auto" "$K"'
awk '/^\[photos\]/ { exit } { print }' "$K" | sed '$ { /^$/d }' > "$K".t && mv "$K".t "$K"

# ---------- services : MiniDLNA, Avahi, rsync, WebDAV ----------
api GET a=services
check "diet.conf: NFS, MiniDLNA, Avahi, rsync, WebDAV off by default" '[ "$(echo "$SVC_DEFAULTS" | grep -c "=0$")" = 5 ] && [ "$(echo "$SVC_DEFAULTS" | grep -c .)" = 5 ]'
check "services: JSON, everything on once enabled" "json 'j[\"host\"]==\"nas-test\" and all(j[k][\"on\"]==1 for k in (\"minidlna\",\"avahi\",\"rsync\",\"webdav\"))'"
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
check "lighttpd.conf: /webdav proxied to 127.0.0.1:8081, outside the interface account" 'grep -qF "\"host\" => \"127.0.0.1\", \"port\" => 8081" "$SRC"/etc/lighttpd/lighttpd.conf && grep -qF "\$HTTP[\"url\"] !~ \"^/(webdav(/|\$)|" "$SRC"/etc/lighttpd/lighttpd.conf'
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

# SMB on/off (Services card): SVC_SMB in diet.conf, honoured by S70ksmbd at start
: > "$R"/cmd.log
api POST a=svc_set 's=smb&on=0'
check "svc_set smb 0: SVC_SMB=0 in diet.conf, S70ksmbd stop" '[ "$ST" = 200 ] && grep -q "^SVC_SMB=0" "$R"/etc/diet.conf && grep -q "S70ksmbd stop" "$R"/cmd.log'
api GET a=services
check "services: smb off" "json 'j[\"smb\"][\"on\"]==0'"
api GET a=status
check "status: smb_on 0 (the page shows SMB as disabled, not failed)" "json 'j[\"smb_on\"]==0'"
o=$(sed "s#/etc/#$R/etc/#g; s#/var/#$R/var/#g" "$BOARD/etc/init.d/S70ksmbd" | PATH="$R/bin:$PATH" sh -s start)
check "S70ksmbd start with SVC_SMB=0: does not start ksmbd" 'case "$o" in *disabled*) true;; *) false;; esac'
api POST a=svc_set 's=smb&on=1'
check "svc_set smb 1: SVC_SMB=1, S70ksmbd start" '[ "$ST" = 200 ] && grep -q "^SVC_SMB=1" "$R"/etc/diet.conf && grep -q "S70ksmbd start" "$R"/cmd.log'
api GET a=services
check "services: smb on and running" "json 'j[\"smb\"]=={\"on\":1,\"run\":1}'"

# ---------- storage: X-RAID (compatibility) and Flex-RAID, through nas-raid ----------
# real nas-raid and xraid-info built for the host, on fake X-RAID images
XC=$HERE/../../xraid-compat
cc -O2 -o "$R"/bin/xraid-info "$XC"/src/xraid-info.c && cc -O2 -o "$R"/bin/xraid-sb "$XC"/src/xraid-sb.c && ln -s "$XC"/src/nas-raid "$R"/bin/nas-raid
for s in clean dirty degraded flexraid; do python3 "$XC"/tests/make-images.py "$R/img/$s" $s > /dev/null; done
stk() {	# stk scenario "content of nas-raid.mode"
	export NAS_RAID_DISKS="$(ls "$R/img/$1"/*.img | tr '\n' ' ')"
	echo "$2" > "$R"/var/run/nas-raid.mode; rm -f "$R"/var/run/xraid.json "$R"/var/run/flexraid.json
	api GET a=storage
}
stk clean xraid-rw
check "storage, clean X-RAID: rw, 2 sections, base/mirror" "json 'j[\"mode\"]==\"xraid-rw\" and j[\"xraid\"][\"mode\"]==\"rw\" and len(j[\"xraid\"][\"sections\"])==2 and j[\"xraid\"][\"mirror\"].endswith(\"sda.img\")'"
check "storage: superblock state for the card (clean, counters, disk states, writer)" "json 'j[\"xraid\"][\"clean\"]==1 and j[\"xraid\"][\"failed_disks\"]==0 and [d[\"state\"] for d in j[\"xraid\"][\"disks\"]]==[\"online\",\"online\"] and j[\"sb_writer\"]==\"yes\"'"
check "storage layout: raid1, one member per bay with its role and state, no rebuild" "json 'j[\"layout\"]=={\"level\":\"raid1\",\"members\":[{\"bay\":1,\"dev\":\"sda.img\",\"role\":\"mirror\",\"state\":\"online\"},{\"bay\":2,\"dev\":\"sdb.img\",\"role\":\"base\",\"state\":\"online\"}],\"rebuild\":None}'"
MDSTAT_L=$(cat "$R"/proc/mdstat 2>/dev/null)
printf 'md10 : active raid1 sdb3[1] sda3[0]\n      [=>...................]  recovery = 7.5%% (1/2) finish=1min\n' > "$R"/proc/mdstat
api GET a=storage
check "storage layout: rebuild = percentage of an md recovery" "json 'j[\"layout\"][\"rebuild\"]==7'"
printf '%s\n' "$MDSTAT_L" > "$R"/proc/mdstat
stk dirty 'xraid-ro unclean_shutdown'
check "storage, dirty X-RAID: read-only, reason unclean_shutdown" "json 'j[\"mode\"]==\"xraid-ro\" and [r[\"code\"] for r in j[\"xraid\"][\"reasons\"]]==[\"unclean_shutdown\"]'"
stk degraded 'xraid-ro missing_disk'
check "storage, degraded X-RAID: read-only, a single disk" "json 'j[\"xraid\"][\"mirror\"]==\"\" and j[\"xraid\"][\"reasons\"][0][\"code\"]==\"missing_disk\"'"
check "storage layout, degraded: the bay without its disk is missing" "json '[m[\"state\"] for m in j[\"layout\"][\"members\"]].count(\"missing\")==1 and len(j[\"layout\"][\"members\"])==2'"
echo "FR_DMS='fr-md2 fr-md3' FR_VGS='c d' FR_MNTS='/c /d'" > "$R"/var/run/flexraid.state
stk flexraid 'flexraid-ro'
check "storage Flex-RAID: mode flexraid-ro, mounted volumes, RAID 1 and RAID 0 arrays, no X-RAID layout" "json 'j[\"mode\"]==\"flexraid-ro\" and j[\"flexraid_mounts\"]==\"/c /d\" and [(a[\"minor\"],a[\"level\"],a[\"usable\"]) for a in j[\"flexraid\"][\"arrays\"]][2:]==[(2,\"raid1\",1),(3,\"raid0\",1)] and j[\"layout\"] is None'"
stk flexraid 'flexraid-rw failure_unrecorded'
check "storage Flex-RAID read-write: no X-RAID layout, nas-raid reasons passed on" "json 'j[\"mode\"]==\"flexraid-rw\" and j[\"reasons\"]==\"failure_unrecorded\" and j[\"layout\"] is None'"
rm -f "$R"/var/run/flexraid.state
stk clean xraid-rw
# md wizards: disabled for now (409), nas-raid not started
: > "$R"/cmd.log
api POST a=raid_plan 'op=migrate'
check "raid_plan: md disabled (409)" '[ "$ST" = 409 ] && case "$OUT" in *"md support is disabled"*) true;; *) false;; esac'
api POST a=raid_run 'op=create&d=sda&confirm=ERASE+sda&yes=1'
check "raid_run: md disabled (409), nas-raid not started" '[ "$ST" = 409 ] && ! grep -q "nas-raid" "$R"/cmd.log'
api POST a=raid_verify ''
check "raid_verify: started" '[ "$ST" = 200 ]'
sleep 3	# the check (sparse 4 GB images) writes in $R: let it finish
api GET 'a=log&f=storage'
check "storage log: nas-raid log" '[ "$ST" = 200 ]'
# "allow writing on the X-RAID" switch: real nas-raid remount on the images,
# dm/LVM/mount simulated; umount refuses while $R/busy exists (open files)
for c in dmsetup lvm mount; do stub $c; done
stub umount '[ ! -e "$DIET_ROOT/busy" ]'
# both X-RAID legs healthy for nas-raid (md10, md11 idle): a clean unmount marks the superblock clean
MDSTAT_SAVE=$(cat "$R"/proc/mdstat)
printf 'md10 : active raid1 dm-1[1] dm-0[0]\n      1 blocks [2/2] [UU]\nmd11 : active raid1 dm-3[1] dm-2[0]\n      1 blocks [2/2] [UU]\n' > "$R"/proc/mdstat
for i in 0 1; do mkdir -p "$R/sys/block/md1$i/md"; echo idle > "$R/sys/block/md1$i/md/sync_action"; done
i=0; while [ $i -lt 30 ] && grep -qs '^running' "$R"/var/lib/nas-raid/verify.state; do sleep 1; i=$((i + 1)); done
rm -f "$R"/var/lib/nas-raid/xraid-dirty
export NAS_RAID_DISKS="$(ls "$R/img/clean"/*.img | tr '\n' ' ')"
printf '# local settings\nSAMPLES=8\nVERIFY_MAX_DAYS=3\nXRAID_RESYNC=no\n' > "$R"/etc/nas-raid.conf
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
check "xraid_rw on: services stopped, /c unmounted then mounted rw, services started" 'grep -q "S70ksmbd stop" "$R"/cmd.log && grep -q "S60nfs stop" "$R"/cmd.log && grep -q "S60minidlnad stop" "$R"/cmd.log && grep -q "S61rsyncd stop" "$R"/cmd.log && grep -q "S51webdav stop" "$R"/cmd.log && grep -q "^umount /c" "$R"/cmd.log && grep -q "mount -t ext4 -o noatime /dev/mapper/c-c /c" "$R"/cmd.log && grep -q "S70ksmbd start" "$R"/cmd.log && awk "/umount \/c/ { u = NR } /S70ksmbd start/ { s = NR } /S70ksmbd stop/ { t = NR } END { exit !(t < u && u < s) }" "$R"/cmd.log'
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
echo flexraid-ro > "$R"/var/run/nas-raid.mode
api POST a=xraid_rw 'on=1&confirm=WRITE&yes=1'
check "xraid_rw: refused on Flex-RAID volumes (409)" '[ "$ST" = 409 ] && grep -qx "XRAID_RW=no" "$R"/etc/nas-raid.conf'
# the same switch for the Flex-RAID volumes (FLEXRAID_RW)
api POST a=flexraid_rw 'on=1'
check "flexraid_rw on: refused without the typed word" '[ "$ST" = 400 ] && ! grep -q FLEXRAID_RW "$R"/etc/nas-raid.conf'
: > "$R"/cmd.log
api POST a=flexraid_rw 'on=1&confirm=WRITE&yes=1'
check "flexraid_rw on (Flex-RAID mode): FLEXRAID_RW=yes written once, XRAID_RW kept, services stopped and started" '[ "$ST" = 200 ] && [ "$(grep -c "^FLEXRAID_RW=" "$R"/etc/nas-raid.conf)" = 1 ] && grep -qx "FLEXRAID_RW=yes" "$R"/etc/nas-raid.conf && grep -qx "XRAID_RW=no" "$R"/etc/nas-raid.conf && grep -q "S70ksmbd stop" "$R"/cmd.log && grep -q "S70ksmbd start" "$R"/cmd.log'
echo 'xraid-ro rw_disabled' > "$R"/var/run/nas-raid.mode
api POST a=flexraid_rw 'on=0'
check "flexraid_rw: refused on an X-RAID volume (409)" '[ "$ST" = 409 ] && grep -qx "FLEXRAID_RW=yes" "$R"/etc/nas-raid.conf'
api POST a=flexraid_rw 'on=2'
check "flexraid_rw: invalid value refused" '[ "$ST" = 400 ]'
api POST a=xraid_rw 'on=2'
check "xraid_rw: invalid value refused" '[ "$ST" = 400 ]'
echo 'xraid-rw' > "$R"/var/run/nas-raid.mode; rm -f "$R"/etc/nas-raid.conf "$R"/etc/nas-raid.conf.bak "$R"/var/lib/nas-raid/xraid-dirty
# quick check: unclean superblock (real crash), no difference -> acceptance with ACCEPT + box only
python3 "$XC"/tests/make-images.py "$R/img/fsdirty" fsdirty > /dev/null; rc=$?
if [ $rc = 77 ]; then echo "skip quick check tests: e2fsprogs missing"; else
export NAS_RAID_DISKS="$(ls "$R/img/fsdirty"/*.img | tr '\n' ' ')"; rm -f "$R"/var/run/xraid.json
echo 'xraid-ro unclean_shutdown unclean_shutdown_linux' > "$R"/var/run/nas-raid.mode; date +%s > "$R"/var/lib/nas-raid/xraid-dirty
api POST a=raid_quick ''
check "raid_quick: started" '[ "$ST" = 200 ] && json "\"Quick check started\" in j[\"msg\"]"'
i=0; while [ $i -lt 30 ] && { [ ! -s "$R"/var/lib/nas-raid/quick.state ] || grep -qs '^running' "$R"/var/lib/nas-raid/quick.state; }; do sleep 1; i=$((i + 1)); done
# diagnostics when the quick check did not end as expected (CI)
grep -qs '^confirm' "$R"/var/lib/nas-raid/quick.state || { echo "quick.state after ${i}s: $(cat "$R"/var/lib/nas-raid/quick.state 2>&1)"; head -n 30 "$R"/var/lib/nas-raid/quick.res "$R"/var/lib/nas-raid/quick.progress 2>&1; tail -n 15 "$R"/var/lib/nas-raid/log 2>&1; } >&2
api GET a=storage
check "storage: quick check done, no difference, confirmation offered (valid JSON)" "json 'j[\"quick\"][\"state\"]==\"confirm\" and j[\"quick\"][\"accept\"]==1 and j[\"quick\"][\"result\"][\"differences\"]==0 and j[\"quick\"][\"result\"][\"complete\"]==1'"
for b in 'confirm=ACCEPT' 'yes=1' 'confirm=accept&yes=1'; do
	api POST a=raid_quick_accept "$b"
	check "raid_quick_accept refused ($b): 400, mark kept" '[ "$ST" = 400 ] && [ -e "$R"/var/lib/nas-raid/xraid-dirty ]'
done
echo XRAID_RW=yes > "$R"/etc/nas-raid.conf; : > "$R"/cmd.log
api POST a=raid_quick_accept 'confirm=ACCEPT&yes=1'
check "raid_quick_accept (ACCEPT + box): mark lifted (log), state accepted" '[ "$ST" = 200 ] && grep -q "quick check accepted by the administrator" "$R"/var/lib/nas-raid/log && grep -q "^accepted " "$R"/var/lib/nas-raid/quick.state'
check "raid_quick_accept with writing on: /c remounted read-write at once, services around it" 'json "\"remounted read-write\" in j[\"msg\"]" && grep -q "^xraid-rw" "$R"/var/run/nas-raid.mode && awk "/S70ksmbd stop/ { t = NR } /umount \/c/ { u = NR } /S70ksmbd start/ { s = NR } END { exit !(t && t < u && u < s) }" "$R"/cmd.log'
: > "$R"/cmd.log; DIET_REMOUNT=1 $SH "$SRC"/www/cgi-bin/api
check "after a check, already read-write: DIET_REMOUNT does nothing" '! grep -q "umount /c" "$R"/cmd.log && ! grep -q "S70ksmbd stop" "$R"/cmd.log'
# writing switched off: clean unmount (superblock clean, mark removed), read-only
api POST a=xraid_rw 'on=0'; : > "$R"/cmd.log
DIET_REMOUNT=1 $SH "$SRC"/www/cgi-bin/api
check "after a check, writing off: DIET_REMOUNT leaves /c read-only" '! grep -q "umount /c" "$R"/cmd.log && grep -q "^xraid-ro" "$R"/var/run/nas-raid.mode'
echo XRAID_RW=yes > "$R"/etc/nas-raid.conf; : > "$R"/cmd.log
DIET_REMOUNT=1 $SH "$SRC"/www/cgi-bin/api
check "after a check, writing on and safeguards lifted: DIET_REMOUNT remounts read-write" 'grep -q "umount /c" "$R"/cmd.log && grep -q "^xraid-rw" "$R"/var/run/nas-raid.mode'
printf 'XRAID_RW=yes\nXRAID_RESYNC=no\n' > "$R"/etc/nas-raid.conf	# with the resync (default), a dirty mark is mounted rw
echo 'xraid-ro unclean_shutdown_linux' > "$R"/var/run/nas-raid.mode; date +%s > "$R"/var/lib/nas-raid/xraid-dirty; : > "$R"/cmd.log
DIET_REMOUNT=1 $SH "$SRC"/www/cgi-bin/api
check "after a check, a safeguard still there (dirty mark, XRAID_RESYNC=no): nothing remounted" '! grep -q "umount /c" "$R"/cmd.log && ! grep -q "S70ksmbd stop" "$R"/cmd.log'
rm -f "$R"/var/lib/nas-raid/xraid-dirty "$R"/etc/nas-raid.conf; echo 'xraid-rw' > "$R"/var/run/nas-raid.mode
api POST a=raid_quick_accept 'confirm=ACCEPT&yes=1'
check "raid_quick_accept again: refused by nas-raid (409, nothing to accept)" '[ "$ST" = 409 ]'
api GET a=storage
check "storage after acceptance: valid JSON, accept no longer offered" "json 'j[\"quick\"][\"state\"]==\"accepted\" and j[\"quick\"][\"accept\"]==0'"
fi
tr_ok=1; for k in 'Quick check' 'Accept the quick check…' 'Accept the quick check' 'Accept' 'I accept this residual risk.' 'no difference, unclean superblock: confirmation needed' '{0} differences ({1}): repair needed' 'incomplete: file system not located' 'accepted on {0}' '{0} compared'; do
	grep -qF "  \"$k\": [\"" "$SRC"/www/index.html || { tr_ok=; echo "  untranslated: $k"; }; done
check "index.html: quick check strings translated (fr, de)" '[ -n "$tr_ok" ]'
echo 'xraid-rw' > "$R"/var/run/nas-raid.mode; rm -f "$R"/var/run/xraid.json
echo "$MDSTAT_SAVE" > "$R"/proc/mdstat; rm -rf "$R"/sys/block/md10 "$R"/sys/block/md11
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

# ---------- Prometheus metrics (collector, METRICS of diet.conf, docs/DIET.md) ----------
C=$R/var/run/diet
DIET_COLLECT=once $SH "$SRC"/www/cgi-bin/api
check "metrics: off by default (no METRICS): no metrics.prom" '! grep -q "^METRICS=" "$R"/etc/diet.conf && [ ! -e "$C"/metrics.prom ]'
api GET a=sys
check "sys: metrics setting 0" "json 'j[\"metrics\"]==0'"
api POST a=metrics_set 'on=2'
check "metrics_set: invalid value refused" '[ "$ST" = 400 ] && ! grep -q "^METRICS=" "$R"/etc/diet.conf'
: > "$R"/cmd.log
api POST a=metrics_set 'on=1'
i=0; while [ $i -lt 30 ] && ! grep -q "S50lighttpd restart" "$R"/cmd.log; do sleep 0.2; i=$((i + 1)); done
check "metrics_set on (token): METRICS=1, lighttpd restarted for its /metrics rule" '[ "$ST" = 200 ] && grep -qx "METRICS=1" "$R"/etc/diet.conf && grep -q "S50lighttpd restart" "$R"/cmd.log'
api GET a=sys
check "sys: metrics setting 1" "json 'j[\"metrics\"]==1'"
# what the collector finds on a running NAS: SMART read by diet-hwmon, X-RAID
# superblock (xraid.json of nas-raid), last checks
echo 'health=PASSED realloc=3 pending=0 uncorr=0 hours=1000 cycles=369 celsius=33' > "$R"/var/run/smart.sda
"$R"/bin/xraid-info --json "$R"/img/clean/*.img > "$R"/var/run/xraid.json
echo 'xraid-rw' > "$R"/var/run/nas-raid.mode
echo 'ok 1700000000' > "$R"/var/lib/nas-raid/verify.state; echo 'accepted 1700000500' > "$R"/var/lib/nas-raid/quick.state
DIET_COLLECT=once $SH "$SRC"/www/cgi-bin/api
check "metrics: collector writes metrics.prom (atomic: no temporary file left)" '[ -s "$C"/metrics.prom ] && [ ! -e "$C"/.metrics.tmp ]'
check "metrics: valid exposition format (HELP/TYPE, contiguous families, counters _total, no NaN, readynas_ prefix)" 'python3 "$HERE"/promcheck.py "$C"/metrics.prom'
if command -v promtool >/dev/null; then
	check "metrics: promtool check metrics" 'promtool check metrics < "$C"/metrics.prom'
fi
# expected values, from the simulated /proc, /sys and /var/run (base units)
check "metrics: values in base units (seconds, bytes, Celsius) and states" 'python3 - "$C"/metrics.prom <<"PYEOF"
import sys
m = {}
for l in open(sys.argv[1]):
    if not l.startswith("#"):
        k, v = l.rsplit(" ", 1); m[k] = v.strip()
want = {
 "readynas_cpu_seconds_total{mode=\"user\"}": "1.00", "readynas_cpu_seconds_total{mode=\"system\"}": "0.50",
 "readynas_cpu_seconds_total{mode=\"idle\"}": "10.00", "readynas_cpu_seconds_total{mode=\"softirq\"}": "0.05",
 "readynas_load1": "0.10", "readynas_uptime_seconds": "12345",
 "readynas_memory_total_bytes": str(255000 * 1024), "readynas_memory_available_bytes": str(180000 * 1024),
 "readynas_temperature_celsius{sensor=\"board\"}": "45", "readynas_temperature_celsius{sensor=\"sda\"}": "38",
 "readynas_temperature_celsius{sensor=\"sdb\"}": "41", "readynas_fan_speed_rpm": "1800", "readynas_fan_pwm": "120",
 "readynas_network_receive_bytes_total{device=\"eth0\"}": "1000", "readynas_network_transmit_bytes_total{device=\"eth0\"}": "2000",
 "readynas_network_receive_packets_total{device=\"eth0\"}": "10", "readynas_network_transmit_packets_total{device=\"eth0\"}": "20",
 "readynas_network_receive_errors_total{device=\"eth0\"}": "0",
 "readynas_disk_read_bytes_total{device=\"sda\"}": str(800 * 512), "readynas_disk_written_bytes_total{device=\"sdb\"}": str(400 * 512),
 "readynas_disk_reads_completed_total{device=\"sda\"}": "10", "readynas_disk_writes_completed_total{device=\"sda\"}": "5",
 "readynas_filesystem_size_bytes{mountpoint=\"/c\"}": str(1922000000 * 1024), "readynas_filesystem_free_bytes{mountpoint=\"/c\"}": str(1000000000 * 1024),
 "readynas_storage_mode_info{mode=\"xraid-rw\",reasons=\"\"}": "1", "readynas_xraid_writable": "1",
 "readynas_xraid_superblock_clean": "1", "readynas_xraid_disks_online": "2", "readynas_xraid_disks_failed": "0",
 "readynas_xraid_sections": "2", "readynas_xraid_sections_synced": "2",
 "readynas_xraid_check_result{check=\"full\",result=\"ok\"}": "1", "readynas_xraid_check_timestamp_seconds{check=\"full\"}": "1700000000",
 "readynas_xraid_check_result{check=\"quick\",result=\"accepted\"}": "1",
 "readynas_disk_smart_passed{device=\"sda\"}": "1", "readynas_disk_reallocated_sectors{device=\"sda\"}": "3",
 "readynas_disk_power_on_seconds{device=\"sda\"}": "3600000",
 "readynas_disk_power_cycles{device=\"sda\"}": "369", "readynas_disk_smart_temperature_celsius{device=\"sda\"}": "33",
 "readynas_service_up{service=\"ksmbd\"}": "1", "readynas_service_up{service=\"ntpd\"}": "0",
}
bad = [(k, v, m.get(k)) for k, v in want.items() if m.get(k) != v]
bad += [(k, "1", None) for k in m if k.startswith("readynas_info{version=") and m[k] != "1"]
if bad or not any(k.startswith("readynas_info{version=") for k in m) or "readynas_disk_smart_passed{device=\"sdb\"}" in m:
    print("  ", bad); sys.exit(1)
PYEOF'
check "metrics: computed by the shell, no awk (floating point emulated on the NAS)" '! sed -n "/^metrics() {/,/^}/p" "$SRC"/www/cgi-bin/api | grep -qw awk'
api POST a=metrics_set 'on=0'
DIET_COLLECT=once $SH "$SRC"/www/cgi-bin/api
check "metrics_set off: METRICS=0, metrics.prom removed by the collector" '[ "$ST" = 200 ] && grep -qx "METRICS=0" "$R"/etc/diet.conf && [ ! -e "$C"/metrics.prom ]'
MC() { sed "s#/etc/diet.conf#$R/etc/diet.conf#g; s#/var/run/diet/#${1:-/var/run/diet/}#g" "$SRC"/etc/init.d/S50lighttpd | sh -s metricsconf; }
check "S50lighttpd metricsconf, off: /metrics refused" 'case "$(MC)" in *"\"/metrics\""*"url.access-deny"*) true;; *) false;; esac'

# ---------- API access tokens (Settings; /api/v1 = the API under its "v1" name) ----------
# v1 METHOD query token [body] [X-Diet]: like api, through /cgi-bin/v1 with "Authorization: Bearer token"
v1() {
	body=${4:-}
	raw=$(printf '%s' "$body" | SCRIPT_NAME=/cgi-bin/v1 HTTP_AUTHORIZATION="$3" REQUEST_METHOD=$1 QUERY_STRING="$2&l=en" CONTENT_LENGTH=${#body} \
		HTTP_X_DIET=${5-1} REMOTE_ADDR=10.0.0.9 $SH "$SRC/www/cgi-bin/v1")
	ST=$(printf '%s\n' "$raw" | sed -n 's/^Status: \([0-9]*\).*/\1/p' | head -n 1); ST=${ST:-200}
	HDR=$(printf '%s\n' "$raw" | tr -d '\r' | sed '/^$/q')
	OUT=$(printf '%s\n' "$raw" | tr -d '\r' | sed '1,/^$/d')
}
check "tokens: the API has a \"v1\" name (link)" '[ -L "$SRC"/www/cgi-bin/v1 ] && [ "$(readlink "$SRC"/www/cgi-bin/v1)" = api ]'
api POST a=token_add 'name=prometheus&perm=ro'
TRO=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'); IRO=${TRO%%.*}
check "token_add read-only: token shown once (id.secret, 8 + 32 characters)" '[ "$ST" = 200 ] && printf "%s" "$TRO" | grep -qxE "[A-Za-z0-9]{8}\.[A-Za-z0-9]{32}"'
api POST a=token_add "name=$(enc 'backup script')&perm=full"
TFU=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'); IFU=${TFU%%.*}
check "token_add full: second token" '[ "$ST" = 200 ] && [ "$IFU" != "$IRO" ]'
api POST a=token_add 'name=x&perm=admin'
check "token_add: invalid rights refused" '[ "$ST" = 400 ]'
api POST a=token_add "name=$(enc 'a:b')&perm=ro"
check "token_add: invalid name refused" '[ "$ST" = 400 ]'
check "tokens: stored hashed (salted SHA-256, file 600), secret in no file" 'S1=${TRO#*.}; L1=$(grep "^$IRO:" "$E"/diet-tokens); [ "$(stat -c %a "$E"/diet-tokens)" = 600 ] && [ "$(echo "$L1" | cut -d: -f2,3)" = prometheus:ro ] && [ "$(printf "%s" "$(echo "$L1" | cut -d: -f4)$S1" | sha256sum | cut -d" " -f1)" = "$(echo "$L1" | cut -d: -f5)" ] && ! grep -rqF "$S1" "$R"/etc "$R"/var "$R"/cmd.log && ! grep -rqF "${TFU#*.}" "$R"/etc "$R"/var "$R"/cmd.log'
api GET a=tokens
check "tokens: list (id, name, rights, date), never the hash" "json '[(t[\"name\"], t[\"perm\"]) for t in j]==[(\"prometheus\",\"ro\"),(\"backup script\",\"full\")] and all(set(t)=={\"id\",\"name\",\"perm\",\"created\"} for t in j)'"
v1 GET a=status ''
check "v1 without token: 401, WWW-Authenticate Bearer" '[ "$ST" = 401 ] && case "$HDR" in *"WWW-Authenticate: Bearer"*) true;; *) false;; esac'
v1 GET a=status "Basic $(printf admin:x | base64)"
check "v1 with Basic credentials: 401" '[ "$ST" = 401 ]'
v1 GET a=status "Bearer $IRO.wrongsecretwrongsecretwrongsecre"
check "v1 with a wrong secret: 401" '[ "$ST" = 401 ]'
v1 GET a=status "Bearer $TRO"
check "v1 read-only token: GET status answered (JSON)" '[ "$ST" = 200 ] && json "\"host\" in j"'
v1 GET 'a=log&f=diet' "Bearer $TRO"
check "v1 read-only token: GET log" '[ "$ST" = 200 ]'
: > "$R"/cmd.log
v1 POST a=ntp "Bearer $TRO"
check "v1 read-only token: POST refused (403), nothing done" '[ "$ST" = 403 ] && [ ! -s "$R"/cmd.log ]'
v1 POST a=smb_sign "Bearer $TRO" 'v=mandatory'
check "v1 read-only token: smb_sign refused (403), ksmbd.conf unchanged" '[ "$ST" = 403 ] && [ ! -s "$R"/cmd.log ] && ! grep -q "server signing = mandatory" "$R"/etc/ksmbd/ksmbd.conf'
v1 POST a=ntp "Bearer $TFU" '' ''
check "v1 full token: POST without X-Diet refused (403)" '[ "$ST" = 403 ]'
v1 POST a=share_add "Bearer $TFU" 'name=viatoken'
check "v1 full token: POST with X-Diet done, journal names the token (not its value)" '[ "$ST" = 200 ] && grep -q "Share viatoken created (10.0.0.9, token backup script)" "$R"/var/log/diet.log'
v1 POST a=share_del "Bearer $TFU" 'name=viatoken'
v1 GET a=tokens "Bearer $TFU"
check "v1: tokens not listed through a token (403)" '[ "$ST" = 403 ]'
v1 POST a=token_add "Bearer $TFU" 'name=more&perm=full'
check "v1: no token created through a token (403)" '[ "$ST" = 403 ] && [ "$(grep -c . "$E"/diet-tokens)" = 2 ]'
v1 GET a=metrics "Bearer $TRO"
check "v1 metrics while METRICS=0: refused (403)" '[ "$ST" = 403 ]'
api POST a=metrics_set 'on=1'
v1 GET a=metrics "Bearer $TRO"
check "v1 metrics (METRICS=1), no collector file: computed, text format 0.0.4, valid" '[ "$ST" = 200 ] && case "$HDR" in *"Content-Type: text/plain; version=0.0.4"*) true;; *) false;; esac && printf "%s\n" "$OUT" > "$R"/m.prom && python3 "$HERE"/promcheck.py "$R"/m.prom'
DIET_COLLECT=once $SH "$SRC"/www/cgi-bin/api
echo '# from the collector file' >> "$C"/metrics.prom
v1 GET a=metrics "Bearer $TRO"
check "v1 metrics: the collector file is sent as is" 'case "$OUT" in *"# from the collector file"*) true;; *) false;; esac'
TRV=$TRO
api POST a=token_del "id=$IRO"
check "token_del: revoked" '[ "$ST" = 200 ] && ! grep -q "^$IRO:" "$E"/diet-tokens && grep -q "^$IFU:" "$E"/diet-tokens'
v1 GET a=status "Bearer $TRV"
check "v1 revoked token: 401" '[ "$ST" = 401 ]'
api POST a=token_del "id=$IRO"
check "token_del unknown: 404" '[ "$ST" = 404 ]'
tr_ok=1; for k in 'API access tokens' 'Read-only token' 'Full-access token' 'Revoke' 'Prometheus metrics' 'Serve the metrics on /metrics' 'Without authentication (any device of the local network)' 'created {0}' 'No tokens.'; do
	grep -qF "  \"$k\": [\"" "$SRC"/www/index.html || { tr_ok=; echo "  untranslated: $k"; }; done
check "index.html: token and metrics strings translated (fr, de), settings wired" '[ -n "$tr_ok" ] && grep -q "post(.token_add." "$SRC"/www/index.html && grep -q "post(.metrics_set." "$SRC"/www/index.html && grep -q "get(.tokens.)" "$SRC"/www/index.html'
check "tokens: no token value in the logs" '! grep -rqF "${TRV#*.}" "$R"/var/log "$R"/cmd.log && ! grep -rqF "${TFU#*.}" "$R"/var/log "$R"/cmd.log'

# ---------- misc ----------
api POST a=reboot '' ''
check "POST without X-Diet refused (403)" '[ "$ST" = 403 ]'

# ---------- protections: reboot / poweroff / update_switch refused (409) while something runs ----------
stub reboot; stub poweroff
cp "$R"/proc/mdstat "$R"/mdstat.save; echo "$HEALTHY" > "$R"/proc/mdstat
mkdir -p "$R"/var/run/nas-update "$R"/var/lib/nas-raid; NR=$R/var/lib/nas-raid
for f in verify quick; do [ -e "$NR/$f.state" ] && mv "$NR/$f.state" "$NR/$f.state.save"; done
api GET a=status
check "status: busy empty when nothing runs" "json 'j[\"busy\"]==[]'"
echo 'busy Installing 2.0' > "$R"/var/run/nas-update/state; echo $$ > "$R"/var/run/nas-update/pid
for a in reboot poweroff; do
	api POST a=$a
	check "$a during an update job: 409, explained" '[ "$ST" = 409 ] && case "$OUT" in *"system update"*force=1*) true;; *) false;; esac'
done
api GET a=status
check "status: busy update" "json 'j[\"busy\"]==[\"update\"]'"
rm -f "$R"/var/run/nas-update/pid
api POST a=reboot
check "reboot: busy state of a dead update job ignored (200)" '[ "$ST" = 200 ]'
rm -f "$R"/var/run/nas-update/state
echo "running $(date +%s)" > "$NR/verify.state"
api POST a=reboot
check "reboot during a full mirror check: 409" '[ "$ST" = 409 ] && case "$OUT" in *"full mirror check"*) true;; *) false;; esac'
api POST a=reboot 'force=1'
check "reboot force=1 without the word FORCE: still 409" '[ "$ST" = 409 ]'
api POST a=reboot 'force=1&confirm=force'
check "reboot force=1 with a wrong word: still 409" '[ "$ST" = 409 ]'
api POST a=poweroff 'force=1&confirm=FORCE'
check "poweroff force=1&confirm=FORCE: 200, logged" '[ "$ST" = 200 ] && grep -q "poweroff forced while running: verify" "$R"/var/log/diet.log'
cp "$R"/proc/stat "$R"/stat.save; printf 'cpu  100 0 50 1000 10 0 5 0\nbtime %s\n' "$(( $(date +%s) + 100 ))" > "$R"/proc/stat
api POST a=reboot
check "reboot: \"running\" left over from an earlier boot ignored (200)" '[ "$ST" = 200 ]'
cp "$R"/stat.save "$R"/proc/stat
rm -f "$NR/verify.state"; echo "running $(date +%s)" > "$NR/quick.state"
api POST a=reboot
check "reboot during a quick check: 409" '[ "$ST" = 409 ] && case "$OUT" in *"quick mirror check"*) true;; *) false;; esac'
api GET a=status
check "status: busy quick" "json 'j[\"busy\"]==[\"quick\"]'"
rm -f "$NR/quick.state"; echo "$DEGRADED" > "$R"/proc/mdstat
api POST a=poweroff
check "poweroff during a RAID resync/repair: 409" '[ "$ST" = 409 ] && case "$OUT" in *"resync or repair"*) true;; *) false;; esac'
api POST a=reboot 'force=1&confirm=FORCE'
check "reboot force=1&confirm=FORCE during a resync: 200" '[ "$ST" = 200 ]'
cp "$R"/mdstat.save "$R"/proc/mdstat
echo "5 aaaa resync 12" > "$R"/var/run/flexraid.sync
api POST a=reboot
check "reboot while a written Flex-RAID RAID 5 recomputes its parity (dm-raid, nas-raid's note): 409" '[ "$ST" = 409 ] && case "$OUT" in *"resync or repair"*) true;; *) false;; esac'
echo "5 AAAA idle 100" > "$R"/var/run/flexraid.sync
api GET a=status
check "status: a RAID 5 idle is not busy" "json 'j[\"busy\"]==[]'"
rm -f "$R"/var/run/flexraid.sync
for f in verify quick; do [ -e "$NR/$f.state.save" ] && mv "$NR/$f.state.save" "$NR/$f.state"; done
sleep 3	# the reboot/poweroff stubs run 2 s after the answer
check "protections: forced actions really ran (stubs called)" 'grep -q "^reboot" "$R"/cmd.log && grep -q "^poweroff" "$R"/cmd.log'
api GET 'a=md&d=md0'
check "md: mdadm --detail" 'case "$OUT" in *"State : clean"*) true;; *) false;; esac'
api GET 'a=md&d=md9'
check "md: unknown volume refused" '[ "$ST" = 400 ]'
api GET 'a=smart&d=sda'
check "smart without smartctl: drivetemp and dmesg" 'case "$OUT" in *"38 °C (drivetemp)"*"[sda]"*) true;; *) false;; esac'
# smart-lite (package/smart-lite): -s = diet-hwmon summary line, exit 2 = disk in standby
mkdir -p "$R"/usr/sbin; cat > "$R"/usr/sbin/smart-lite <<'SLEOF'
#!/bin/sh
echo "smart-lite $*" >> "${0%/usr/sbin/smart-lite}"/cmd.log
case "$*" in
-s*/dev/sdb) echo power=standby; exit 2;;
-t*/dev/sdb) echo "/dev/sdb: a self-test is already running" >&2; exit 1;;
-t*) ;;
-s*) echo 'health=PASSED realloc=0 pending=2 uncorr=2 hours=2551 cycles=369 celsius=33';;
*) echo "Device:   $2"; echo 'SMART overall-health self-assessment test result: PASSED';;
esac
SLEOF
chmod 755 "$R"/usr/sbin/smart-lite
api GET 'a=smart&d=sda'
check "smart with smart-lite: full report, forced (-f: the user asked for it)" 'case "$OUT" in *"Device:   /dev/sda"*"result: PASSED"*) true;; *) false;; esac && grep -q "^smart-lite -f /dev/sda$" "$R"/cmd.log'
api GET 'a=smart&d=..%2Fetc'
check "smart: unknown disk refused" '[ "$ST" = 400 ]'
# SMART self-test from the interface (POST ?a=smart_test d= t=short|long|abort)
api POST a=smart_test 'd=sda&t=short'
check "smart_test: short test started, summary refreshed, logged" '[ "$ST" = 200 ] && grep -q "^smart-lite -t short /dev/sda$" "$R"/cmd.log && grep -q "^smart-lite -s /dev/sda$" "$R"/cmd.log && grep -q "SMART self-test short on sda" "$R"/var/log/diet.log'
api POST a=smart_test 'd=sda&t=long'
check "smart_test: extended test" '[ "$ST" = 200 ] && grep -q "^smart-lite -t long /dev/sda$" "$R"/cmd.log'
api POST a=smart_test 'd=sda&t=erase'
check "smart_test: unknown kind refused" '[ "$ST" = 400 ] && ! grep -q "smart-lite -t erase" "$R"/cmd.log'
api POST a=smart_test 'd=..%2Fetc&t=short'
check "smart_test: unknown disk refused" '[ "$ST" = 400 ]'
api POST a=smart_test 'd=sdb&t=short'
check "smart_test: refusal of the disk passed on (409)" '[ "$ST" = 409 ] && case "$OUT" in *"already running"*) true;; *) false;; esac'
api POST a=smart_test 'd=sda&t=short' '' ''
check "smart_test: POST without X-Diet refused" '[ "$ST" = 403 ]'
cp "$R"/var/run/smart.sda "$R"/smart.sda.keep
echo 'health=PASSED realloc=0 pending=0 uncorr=0 hours=10 cycles=5 celsius=30 selftest=15 left=40 short_min=2 long_min=95' > "$R"/var/run/smart.sda
api GET a=status
check "status: self-test state of the disk" "json 'any(d[\"smart\"] and d[\"smart\"][\"selftest\"]==15 and d[\"smart\"][\"left\"]==40 and d[\"smart\"][\"long_min\"]==95 for d in j[\"disks\"])'"
mv "$R"/smart.sda.keep "$R"/var/run/smart.sda

# ---------- system update (nas-update: two slots on a simulated USB stick) ----------
# The stick is a folder (DIET_STICK, no mount), the jobs run in the foreground
# (NAS_UPDATE_SYNC). relay-switch and the initramfs on the same layout:
# board/readynas-duo-v1/relay/test-slots.sh.
K=$R/stick; export DIET_STICK="$K" NAS_UPDATE_SYNC=1
NL0=$(wc -l < "$R"/cmd.log); : > "$R/update.start"
ln -s "$SRC/usr/sbin/nas-update" "$R/bin/nas-update"
nu() { DIET_ROOT="$R" "$R/bin/nas-update" "$@"; }
mkdir -p "$K/boot" "$K/rootfs-6.18/sbin" "$R/proc/self"
echo old-init > "$K/rootfs-6.18/sbin/init"; echo old-kernel > "$K/boot/vmlinux.bin"
running() { echo "25 1 8:33 /$1 / rw,noatime shared:1 - ext4 /dev/sdc1 rw" > "$R/proc/self/mountinfo"; }
running rootfs-6.18
# df: free kB of the stick from $R/stick.free, otherwise the /c volume
stub df 'case "$*" in *stick*) echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/sdc1 1900000 1 $(cat "$DIET_ROOT/stick.free") 1% /s";; *) echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/md0 1922000000 922000000 1000000000 48% /c";; esac'
echo 1000000 > "$R/stick.free"
# settings of this NAS that must follow the update
mkdir -p "$R/root/.ssh" "$R/etc/dropbear" "$R/etc/lighttpd/ssl" "$R/var/lib/nas-raid"
echo "ssh-ed25519 AAAA test" > "$R/root/.ssh/authorized_keys"; echo hostkey > "$R/etc/dropbear/dropbear_ed25519_host_key"
echo "admin:\$6\$x" > "$R/etc/lighttpd/htpasswd"; echo key > "$R/etc/lighttpd/ssl/server.key"
echo state > "$R/var/lib/nas-raid/mark"; echo "XRAID_RW=no" > "$R/etc/nas-raid.conf"
echo 1 > "$R/var/lib/nas-raid/xraid-dirty"	# /c mounted read-write while the update is installed
printf 'root:$6$runninghash:19000:0:99999:7:::\n' > "$R/etc/shadow"
grep -q '^nas:' "$R/etc/passwd" || echo "nas:x:105:105:DIET WebDAV:/:/bin/false" >> "$R/etc/passwd"
grep -q '^zoe:' "$R/etc/passwd" || { echo "zoe:x:1007:1007::/c/home/zoe:/bin/false" >> "$R/etc/passwd"; echo "zoe:x:1007:nas" >> "$R/etc/group"; }
[ -f "$R/etc/avahi/services/rsync.service" ] && mv "$R/etc/avahi/services/rsync.service" "$R/etc/avahi/services/rsync.service.off"
# images of a new version: a small rootfs.tar (./ prefix, like Buildroot's) and a kernel
IMG=$R/images; mkdir -p "$IMG/root/sbin" "$IMG/root/etc/avahi/services" "$IMG/root/bin"
echo "new-init" > "$IMG/root/sbin/init"; chmod 755 "$IMG/root/sbin/init"; echo tool > "$IMG/root/bin/newtool"
printf 'root:x:0:0:root:/root:/bin/sh\nnas:x:101:102:DIET WebDAV:/:/bin/false\nnewsys:x:103:104::/:/bin/false\n' > "$IMG/root/etc/passwd"
printf 'root:x:0:\nusers:x:100:\nnas:x:102:\nnewsys:x:104:\n' > "$IMG/root/etc/group"
printf 'root::::::::\nnewsys:*:::::::\n' > "$IMG/root/etc/shadow"
echo "SPINDOWN_MIN=0" > "$IMG/root/etc/diet.conf"
echo x > "$IMG/root/etc/avahi/services/rsync.service"; echo x > "$IMG/root/etc/avahi/services/ssh.service"
tar -C "$IMG/root" -cf "$IMG/rootfs.tar" .
head -c 204800 /dev/urandom > "$IMG/vmlinux.bin"
MK=$HERE/../../../board/readynas-duo-v1/mkupdate.sh
VERSION=2.0 sh "$MK" "$IMG" "$IMG" >/dev/null && VERSION=3.0 sh "$MK" "$IMG" "$IMG" >/dev/null
P2=$IMG/readynasng-update-2.0.tar; P3=$IMG/readynasng-update-3.0.tar
upload() {	# upload <file>: POST a=update_upload, the file as body
	raw=$(REQUEST_METHOD=POST QUERY_STRING="a=update_upload&l=en" CONTENT_LENGTH=$(stat -c %s "$1") \
		HTTP_X_DIET=1 REMOTE_ADDR=10.0.0.9 $SH "$SRC/www/cgi-bin/api" < "$1")
	ST=$(printf '%s\n' "$raw" | sed -n 's/^Status: \([0-9]*\).*/\1/p' | head -n 1); ST=${ST:-200}
	OUT=$(printf '%s\n' "$raw" | tr -d '\r' | sed '1,/^$/d')
}

api GET a=update
check "update: first install seen (rootfs-6.18 active and running, no other version, relay without slots)" "json 'j[\"stick\"]==1 and j[\"running\"]==j[\"active\"]==\"rootfs-6.18\" and j[\"other\"]==\"rootfs-b\" and j[\"relay\"]==0 and j[\"slots\"][0][\"ok\"]==1 and j[\"slots\"][1][\"ok\"]==0 and j[\"job\"][\"state\"]==\"idle\"'"
# refusals: damaged package, not a package, not enough room, job running
mkdir "$R/bad"; tar -C "$R/bad" -xf "$P2"; sed -i '1s/^./0/; 1s/^0/1/' "$R/bad/SHA256SUMS"
tar -C "$R/bad" -cf "$R/bad.tar" manifest SHA256SUMS rootfs.tar.gz vmlinux.bin
upload "$R/bad.tar"
api GET a=update
check "update: damaged package refused (checksum), nothing installed, package removed" "json 'j[\"job\"][\"state\"]==\"failed\" and \"Checksum\" in j[\"job\"][\"msg\"] and j[\"slots\"][1][\"ok\"]==0 and j[\"try\"]==\"\"' && [ ! -e \"$K/update/package.tar\" ]"
head -c 4096 /dev/urandom > "$R/junk.tar"; upload "$R/junk.tar"
api GET a=update
check "update: something else than a package refused" "json 'j[\"job\"][\"state\"]==\"failed\" and \"Invalid update package\" in j[\"job\"][\"msg\"]'"
echo 16400 > "$R/stick.free"; upload "$P2"
check "update: not enough room for the package: refused at once (409)" '[ "$ST" = 409 ] && case "$OUT" in *"Not enough room"*) true;; *) false;; esac'
echo $(( 16384 + $(stat -c %s "$P2") / 1024 + 2 )) > "$R/stick.free"; upload "$P2"
api GET a=update
check "update: room for the package but not for the system: refused, active slot untouched" "json 'j[\"job\"][\"state\"]==\"failed\" and \"Not enough room\" in j[\"job\"][\"msg\"]' && [ \"\$(cat $K/rootfs-6.18/sbin/init)\" = old-init ]"
echo 1000000 > "$R/stick.free"
mkdir -p "$R/var/run/nas-update"; echo $$ > "$R/var/run/nas-update/pid"; upload "$P2"
check "update: refused while another update runs" '[ "$ST" = 409 ] && case "$OUT" in *"already in progress"*) true;; *) false;; esac'
rm -f "$R/var/run/nas-update/pid"
# relay add-on 1.0 (no /boot/relay-slots): installed, no trial
upload "$P2"
check "update: upload accepted" '[ "$ST" = 200 ]'
api GET a=update
check "update: installed in rootfs-b but relay too old: no trial scheduled" "json 'j[\"job\"][\"state\"]==\"done\" and \"too old\" in j[\"job\"][\"msg\"] and j[\"try\"]==\"\" and j[\"slots\"][1][\"ok\"]==1 and j[\"slots\"][1][\"ver\"]==\"2.0\"'"
B=$K/rootfs-b
check "update: system extracted, kernel and its md5 in the slot, package removed" '[ "$(cat "$B/sbin/init")" = new-init ] && [ -f "$B/bin/newtool" ] && cmp -s "$B/boot/vmlinux.bin" "$IMG/vmlinux.bin" && (cd "$B/boot" && md5sum -c vmlinux.bin.md5 >/dev/null) && [ ! -e "$B/.incomplete" ] && [ ! -e "$K/update/package.tar" ] && [ "$(cat "$K/boot/vmlinux.bin")" = old-kernel ]'
check "update: settings copied (diet.conf, ksmbd, nas-raid, SSH keys, host keys, web password, API tokens, certificate)" 'cmp -s "$R/etc/diet.conf" "$B/etc/diet.conf" && cmp -s "$R/etc/ksmbd/ksmbd.conf" "$B/etc/ksmbd/ksmbd.conf" && cmp -s "$R/etc/nas-raid.conf" "$B/etc/nas-raid.conf" && cmp -s "$R/root/.ssh/authorized_keys" "$B/root/.ssh/authorized_keys" && cmp -s "$R/etc/dropbear/dropbear_ed25519_host_key" "$B/etc/dropbear/dropbear_ed25519_host_key" && cmp -s "$R/etc/lighttpd/htpasswd" "$B/etc/lighttpd/htpasswd" && cmp -s "$R/etc/diet-tokens" "$B/etc/diet-tokens" && [ -f "$B/etc/lighttpd/ssl/server.key" ] && [ -f "$B/var/lib/nas-raid/mark" ] && cmp -s "$R/etc/hostname" "$B/etc/hostname"'
check "update: the X-RAID read-write mark (xraid-dirty) is not carried into the new slot" '[ ! -e "$B/var/lib/nas-raid/xraid-dirty" ]'
rm -f "$R/var/lib/nas-raid/xraid-dirty"
check "update: accounts merged (users and uids of this NAS, root password, new system account kept)" 'grep -q "^zoe:x:1007:" "$B/etc/passwd" && grep -q "^nas:x:105:" "$B/etc/passwd" && grep -q "^newsys:x:103:" "$B/etc/passwd" && grep -q "^zoe:x:1007:nas" "$B/etc/group" && grep -q "^newsys:" "$B/etc/group" && grep -q "^root:\$6\$runninghash:" "$B/etc/shadow" && grep -q "^newsys:" "$B/etc/shadow" && [ $(grep -c "^root:" "$B/etc/passwd") = 1 ]'
check "update: Avahi announcement of a stopped service stays off" '[ -f "$B/etc/avahi/services/rsync.service.off" ] && [ ! -f "$B/etc/avahi/services/rsync.service" ] && [ -f "$B/etc/avahi/services/ssh.service" ]'
# relay add-on 1.1: the other version can be tried
echo 1 > "$K/boot/relay-slots"
echo "running $(date +%s)" > "$R/var/lib/nas-raid/verify.state.t"; mv "$R/var/lib/nas-raid/verify.state" "$R/var/lib/nas-raid/verify.state.k" 2>/dev/null; mv "$R/var/lib/nas-raid/verify.state.t" "$R/var/lib/nas-raid/verify.state"
api POST a=update_switch
check "update: switch refused during a mirror check (409), no trial scheduled" '[ "$ST" = 409 ] && [ ! -e "$K/boot/slot.try" ]'
rm -f "$R/var/lib/nas-raid/verify.state"; mv "$R/var/lib/nas-raid/verify.state.k" "$R/var/lib/nas-raid/verify.state" 2>/dev/null
api POST a=update_switch
check "update: switch schedules a trial of rootfs-b" '[ "$ST" = 200 ] && [ "$(cat "$K/boot/slot.try")" = rootfs-b ]'
api POST a=update_cancel
check "update: cancel removes the trial" '[ "$ST" = 200 ] && [ ! -e "$K/boot/slot.try" ]'
upload "$P2"
api GET a=update
check "update: package installed again, trial of rootfs-b scheduled" "json 'j[\"job\"][\"state\"]==\"done\" and j[\"try\"]==\"rootfs-b\" and \"restart\" in j[\"job\"][\"msg\"]'"
echo "SPINDOWN_MIN=7" >> "$R/etc/diet.conf"
nu sync
check "update: setting changed before the restart copied again at shutdown (sync)" 'grep -q "^SPINDOWN_MIN=7" "$B/etc/diet.conf"'
# boot of rootfs-b complete (relay-switch marked it, S99relay-confirm)
: > "$B/.relay_pending"; running rootfs-b; rm -f "$B/.relay_pending"; nu confirm
api GET a=update
check "update: completed boot of the trial makes it active" "json 'j[\"active\"]==\"rootfs-b\" and j[\"running\"]==\"rootfs-b\" and j[\"try\"]==\"\" and j[\"other\"]==\"rootfs-6.18\"' && [ \"\$(cat $K/boot/slot)\" = rootfs-b ]"
# manual return to the previous version (the first install)
api POST a=update_switch
check "update: going back schedules the previous version (rootfs-6.18), settings copied into it" '[ "$ST" = 200 ] && [ "$(cat "$K/boot/slot.try")" = rootfs-6.18 ] && grep -q "^SPINDOWN_MIN=7" "$K/rootfs-6.18/etc/diet.conf"'
api POST a=update_cancel
# 3.0 goes into the slot of the first install; its kernel /boot/vmlinux.bin is no longer used
upload "$P3"
api GET a=update
check "update: 3.0 installed into rootfs-6.18 (the slot not running), first-install kernel removed" "json 'j[\"try\"]==\"rootfs-6.18\" and j[\"slots\"][0][\"ver\"]==\"3.0\" and j[\"slots\"][0][\"ok\"]==1' && [ ! -e $K/boot/vmlinux.bin ] && [ -f $K/rootfs-6.18/boot/vmlinux.bin ] && [ \"\$(cat $K/rootfs-6.18/sbin/init)\" = new-init ] && [ \"\$(cat $K/rootfs-b/etc/system-version)\" = 2.0 ]"
# trial that does not complete: relay-switch drops it at the next boot (test-slots.sh)
# and the active slot starts again; the interface reports it
rm -f "$K/boot/slot.try"; echo rootfs-6.18 > "$K/boot/slot.failed"; nu confirm
api GET a=update
check "update: failed trial reported, rootfs-b still active" "json 'j[\"failed\"]==\"rootfs-6.18\" and j[\"active\"]==\"rootfs-b\" and j[\"try\"]==\"\"'"
api POST a=update_switch
check "update: the failed version can be tried again (switch)" '[ "$(cat "$K/boot/slot.try")" = rootfs-6.18 ] && [ ! -e "$K/boot/slot.failed" ]'
api POST a=update_cancel
# while a trial runs (not confirmed yet), nothing is installed
echo rootfs-6.18 > "$K/boot/slot.try"; running rootfs-6.18
upload "$P2"
api GET a=update
check "update: refused while the running system is not the active one" "json 'j[\"job\"][\"state\"]==\"failed\" and \"not the active slot\" in j[\"job\"][\"msg\"]' && [ \"\$(cat $K/rootfs-b/sbin/init)\" = new-init ]"
running rootfs-b; rm -f "$K/boot/slot.try"
# download (GitHub release URL + SHA-256)
stub curl 'case "$*" in *--cacert\ /etc/ssl/certs/ca-certificates.crt*) ;; *) exit 60;; esac; case "$*" in *github.com*) cat "$DIET_ROOT/images/readynasng-update-2.0.tar";; *) echo "{\"ok\":true}";; esac'
U=https://github.com/example/ReadyNasNextGen/releases/download/v2.0/readynasng-update-2.0.tar
S2=$(cut -d' ' -f1 "$P2.sha256")
api POST a=update_url "url=$(enc http://example.com/x.tar)&sha=$S2"
check "update URL: other sites refused" '[ "$ST" = 409 ]'
api POST a=update_url "url=$(enc "$U")&sha="
check "update URL: SHA-256 required" '[ "$ST" = 409 ] && case "$OUT" in *SHA-256*) true;; *) false;; esac'
api POST a=update_url "url=$(enc "$U")&sha=$(echo "$S2" | tr 0-9a-f 1-9a-f0)"
api GET a=update
check "update URL: download with another SHA-256 refused" "json 'j[\"job\"][\"state\"]==\"failed\" and \"SHA-256\" in j[\"job\"][\"msg\"]'"
api POST a=update_url "url=$(enc "$U")&sha=$S2"
api GET a=update
check "update URL: downloaded, checked, installed into rootfs-6.18" "json 'j[\"job\"][\"state\"]==\"done\" and j[\"try\"]==\"rootfs-6.18\" and j[\"slots\"][0][\"ver\"]==\"2.0\"'"
api GET 'a=log&f=update'
check "update: log (received, checked, confirmed, refused)" 'case "$OUT" in *"package received"*"is now the active system"*"refused"*) true;; *) false;; esac'
check "update: data disks never touched (no mount, nothing written under /c)" '! tail -n +$((NL0 + 1)) "$R"/cmd.log | grep -q "^u*mount" && [ -z "$(find "$R/c" -newer "$R/update.start")" ]'
unset DIET_STICK NAS_UPDATE_SYNC

# ---------- diet-hwmon (one round) ----------
echo "$DEGRADED" > "$R"/proc/mdstat
echo 'TG_TOKEN=1:x
TG_CHAT=1' > "$R"/etc/diet-notify.conf
echo 'health=PASSED realloc=0 pending=0 uncorr=0 hours=7' > "$R"/var/run/smart.sdb
PATH="$R/bin:$PATH" DIET_ONCE=1 $SH "$SRC"/usr/sbin/diet-hwmon
sleep 1
check "diet-hwmon: history written" 'grep -q " 45 1800 120$" "$R"/var/run/hwmon.hist'
check "diet-hwmon: alert logged and sent" 'grep -q "RAID degraded" "$R"/var/run/alert.last && grep -q "ALERT" "$R"/var/log/diet.log && grep -q "curl .*sendMessage" "$R"/cmd.log'
check "diet-hwmon: SMART by smart-lite -s, disk in standby left alone (previous reading kept)" 'grep -qx "health=PASSED realloc=0 pending=2 uncorr=2 hours=2551 cycles=369 celsius=33" "$R"/var/run/smart.sda && [ "$(cat "$R"/var/run/smart.sdb)" = "health=PASSED realloc=0 pending=0 uncorr=0 hours=7" ] && grep -q "^smart-lite -s /dev/sdb$" "$R"/cmd.log && ! grep -q "^smart-lite -f /dev/sdb" "$R"/cmd.log'
check "diet-hwmon: SMART problems in the alert" 'grep -q "sda : 2 pending sectors, 2 unreadable sectors" "$R"/var/run/alert.last'

# ---------- real lighttpd (host build: LIGHTTPD=/path/to/lighttpd, otherwise lighttpd from PATH; skipped if absent) ----------
# lighttpd.conf of the NAS with only paths, port and the :80 redirect changed:
# collector answers served as static files under /cache/, with the interface
# authentication, nothing else of /var/run/diet; HTTP/2; keep-alive; TLS tickets.
LT=${LIGHTTPD:-$(command -v lighttpd)}
if [ -x "$LT" ] && command -v curl >/dev/null && command -v openssl >/dev/null; then
	LTD=$R/lt; LTP=$((20000 + $$ % 20000)); mkdir -p "$LTD/diet" "$LTD/www"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=t -days 2 -keyout "$LTD/key" -out "$LTD/pem" 2>/dev/null
	echo "admin:$(openssl passwd -6 secret1)" > "$LTD/htpasswd"
	echo '{"host":"readynas"}' > "$LTD/diet/status.json"; echo 1 > "$LTD/diet/pid"; echo x > "$LTD/diet/.status.tmp"; mkfifo "$LTD/diet/wake"; echo '"x"' > "$LTD/diet/hist.frag"
	python3 - "$SRC/etc/lighttpd/lighttpd.conf" "$LTD" "$LTP" "$R" > "$LTD/lighttpd.conf" <<'PYEOF'
import sys
c, L, P = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3]
c = c[:c.index('$SERVER["socket"] == ":80"')]
for a, b in (('server.port = 443', 'server.port = %s\nserver.bind = "127.0.0.1"' % P), ('"/www"', '"%s/www"' % L),
             ('"/var/run/lighttpd.pid"', '"%s/pid"' % L), ('server.errorlog-use-syslog = "enable"', 'server.errorlog = "%s/error.log"' % L),
             ('"/etc/lighttpd/ssl/server.pem"', '"%s/pem"' % L), ('"/etc/lighttpd/ssl/server.key"', '"%s/key"' % L),
             ('"/etc/lighttpd/htpasswd"', '"%s/htpasswd"' % L), ('"/var/run/diet/"', '"%s/diet/"' % L),
             ('include_shell "/etc/init.d/S50lighttpd firstconf"', ''),
             ('include_shell "/etc/init.d/S50lighttpd metricsconf"', 'include "%s/metrics.conf"\nsetenv.add-environment = ( "DIET_ROOT" => "%s" )' % (L, sys.argv[4]))):
    assert a in c, a
    c = c.replace(a, b)
print(c)
PYEOF
	echo '<html></html>' > "$LTD/www/index.html"; ln -s "$SRC/www/cgi-bin" "$LTD/www/cgi-bin"
	sed -i 's/^METRICS=.*/METRICS=0/' "$R"/etc/diet.conf; MC "$LTD/diet/" > "$LTD/metrics.conf"
	check "lighttpd (host): configuration accepted (-tt)" '"$LT" -tt -f "$LTD/lighttpd.conf" 2>/dev/null'
	"$LT" -D -f "$LTD/lighttpd.conf" 2>/dev/null & LTPID=$!
	i=0; while [ $i -lt 50 ] && ! curl -sk -o /dev/null "https://127.0.0.1:$LTP/" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
	cu() { curl -sk -o "$LTD/out" -D "$LTD/hdr" -w '%{http_code}' "$@"; }
	check "lighttpd: /cache/status.json without password -> 401" '[ "$(cu "https://127.0.0.1:$LTP/cache/status.json")" = 401 ]'
	check "lighttpd: /cache/status.json with the interface account -> 200, the file, JSON, no-store, Last-Modified" '[ "$(cu -u admin:secret1 "https://127.0.0.1:$LTP/cache/status.json")" = 200 ] && grep -q readynas "$LTD/out" && grep -qi "^content-type: application/json" "$LTD/hdr" && grep -qi "^cache-control: no-store" "$LTD/hdr" && grep -qi "^last-modified:" "$LTD/hdr"'
	check "lighttpd: missing cache file -> 404 (the page falls back to the API)" '[ "$(cu -u admin:secret1 "https://127.0.0.1:$LTP/cache/storage.json")" = 404 ]'
	ko=; for f in pid wake .status.tmp hist.frag "" ../diet/pid; do c=$(cu -u admin:secret1 "https://127.0.0.1:$LTP/cache/$f"); [ "$c" = 403 ] || [ "$c" = 404 ] || ko="$ko $f:$c"; done
	check "lighttpd: nothing else of /var/run/diet (pid, FIFO, temporary files, listing)" '[ -z "$ko" ] || { echo "  served:$ko"; false; }'
	check "lighttpd: HTTP/2" '[ "$(curl -sk -u admin:secret1 --http2 -o /dev/null -w "%{http_version}" "https://127.0.0.1:$LTP/cache/status.json")" = 2 ]'
	# one TLS handshake for several requests spaced out (keep-alive), then a new
	# connection resumes the session with a ticket (no full handshake)
	check "lighttpd: keep-alive (3 requests 2 s apart: 1 handshake) and TLS session resumption" 'python3 "$HERE"/tls-reuse.py 127.0.0.1 "$LTP" admin:secret1 3 2'
	# token API and /metrics through lighttpd: the real API as CGI (DIET_ROOT
	# passed by setenv), Basic for the interface, Bearer for /api/v1 and /metrics
	cu() { curl -sk -o "$LTD/out" -D "$LTD/hdr" -w '%{http_code}' "$@"; }
	U=https://127.0.0.1:$LTP
	api POST a=token_add 'name=lt-ro&perm=ro'; LRO=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
	api POST a=token_add 'name=lt-full&perm=full'; LFU=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
	check "lighttpd: interface API with Basic -> 200 JSON" '[ "$(cu -u admin:secret1 "$U/cgi-bin/api?a=status")" = 200 ] && jsonok < "$LTD/out"'
	check "lighttpd: interface API without password or with a token -> 401" '[ "$(cu "$U/cgi-bin/api?a=status")" = 401 ] && [ "$(cu -H "Authorization: Bearer $LRO" "$U/cgi-bin/api?a=status")" = 401 ]'
	check "lighttpd: /api/v1/status without token -> 401 (WWW-Authenticate Bearer), with Basic -> 401" '[ "$(cu "$U/api/v1/status")" = 401 ] && grep -qi "^www-authenticate: bearer" "$LTD/hdr" && [ "$(cu -u admin:secret1 "$U/api/v1/status")" = 401 ]'
	check "lighttpd: /api/v1/status with a read-only token -> 200 JSON" '[ "$(cu -H "Authorization: Bearer $LRO" "$U/api/v1/status")" = 200 ] && jsonok < "$LTD/out" && grep -q "\"host\"" "$LTD/out"'
	check "lighttpd: /api/v1/log?f=diet (parameters kept) -> 200" '[ "$(cu -H "Authorization: Bearer $LRO" "$U/api/v1/log?f=diet")" = 200 ] && grep -q "token" "$LTD/out"'
	check "lighttpd: /api/v1/ with a path that is not an action -> 404" '[ "$(cu -H "Authorization: Bearer $LRO" "$U/api/v1/status/x")" = 404 ]'
	check "lighttpd: /cgi-bin/v1 needs the token too" '[ "$(cu -u admin:secret1 "$U/cgi-bin/v1?a=status")" = 401 ]'
	check "lighttpd: POST /api/v1/ntp with a read-only token -> 403" '[ "$(cu -X POST -H "X-Diet: 1" -H "Authorization: Bearer $LRO" "$U/api/v1/ntp")" = 403 ]'
	check "lighttpd: POST /api/v1/ntp with a full token: 403 without X-Diet, 200 with it" '[ "$(cu -X POST -H "Authorization: Bearer $LFU" "$U/api/v1/ntp")" = 403 ] && [ "$(cu -X POST -H "X-Diet: 1" -H "Authorization: Bearer $LFU" "$U/api/v1/ntp")" = 200 ] && jsonok < "$LTD/out"'
	check "lighttpd: /metrics while off -> 403 (even with a token)" '[ "$(cu "$U/metrics")" = 403 ] && [ "$(cu -H "Authorization: Bearer $LRO" "$U/metrics")" = 403 ]'
	ltrestart() {	# ltrestart METRICS: diet.conf, /metrics rule (S50lighttpd metricsconf), lighttpd restarted
		sed -i '/^METRICS=/d' "$R"/etc/diet.conf; echo "METRICS=$1" >> "$R"/etc/diet.conf; MC "$LTD/diet/" > "$LTD/metrics.conf"
		kill $LTPID 2>/dev/null; wait $LTPID 2>/dev/null
		"$LT" -D -f "$LTD/lighttpd.conf" 2>>"$LTD/stderr" & LTPID=$!
		i=0; while [ $i -lt 50 ] && ! curl -sk -o /dev/null "$U/" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
	}
	ltrestart 1
	check "lighttpd: /metrics with token mode: 401 without token or with Basic" '[ "$(cu "$U/metrics")" = 401 ] && [ "$(cu -u admin:secret1 "$U/metrics")" = 401 ]'
	check "lighttpd: /metrics with a read-only token -> 200, text format 0.0.4, valid" '[ "$(cu -H "Authorization: Bearer $LRO" "$U/metrics")" = 200 ] && grep -qi "^content-type: text/plain; version=0.0.4" "$LTD/hdr" && python3 "$HERE"/promcheck.py "$LTD/out"'
	api POST a=token_del "id=${LRO%%.*}"
	check "lighttpd: revoked token refused at once (/api/v1 and /metrics -> 401)" '[ "$(cu -H "Authorization: Bearer $LRO" "$U/api/v1/status")" = 401 ] && [ "$(cu -H "Authorization: Bearer $LRO" "$U/metrics")" = 401 ]'
	ltrestart 2
	check "lighttpd: /metrics open, file not written yet (collector stopped) -> 404" '[ "$(cu "$U/metrics")" = 404 ]'
	cp "$C"/metrics.prom "$LTD/diet/metrics.prom"
	check "lighttpd: /metrics open (local network): static file, no authentication, no CGI" '[ "$(cu "$U/metrics")" = 200 ] && cmp -s "$LTD/out" "$LTD/diet/metrics.prom" && grep -qi "^last-modified:" "$LTD/hdr" && grep -qi "^content-type: text/plain; version=0.0.4" "$LTD/hdr" && grep -qi "^cache-control: no-store" "$LTD/hdr"'
	ltrestart 0
	check "lighttpd: /metrics off again -> 403" '[ "$(cu "$U/metrics")" = 403 ]'
	check "lighttpd: no token value in the server logs" '! grep -qF "${LRO#*.}" "$LTD/error.log" "$LTD/stderr" 2>/dev/null && ! grep -qF "${LFU#*.}" "$LTD/error.log" "$LTD/stderr" 2>/dev/null'
	kill $LTPID 2>/dev/null; wait $LTPID 2>/dev/null
else
	echo "skip lighttpd (host) tests: no lighttpd (LIGHTTPD=...)"
fi

# index.html: every text of the page has its French and German translation (I18N):
# the texts of the markup (elements and placeholder/title/data-q/aria-label), every
# t('…') of the script and the tables passed to t() (reasons, modes, states; city names of the time zones excepted)
I18NKO=$(python3 -I - "$SRC"/www/index.html <<'PYEOF'
import re, sys, html.parser
src = open(sys.argv[1], encoding='utf-8').read()
keys = {k.replace('\\"', '"') for k in re.findall(r'^  "((?:[^"\\]|\\.)*)": \["[^"]+", "[^"]+"\]', src, re.M)}
js = src[src.index('<script>'):]
need = set(m.group(2) for m in re.finditer(r"\bt\((['\"])((?:(?!\1).)*)\1", js))
for tb in re.finditer(r'const (?:XR|NR|FRR|XRM|BUSYT|MST) = \{(.*?)\};', js, re.S):
    need |= set(re.findall(r":\s*'([^']*)'", tb.group(1)))
class P(html.parser.HTMLParser):
    skip = 0
    def handle_starttag(self, tag, a):
        if tag in ('script', 'style', 'code', 'pre'): self.skip += 1
        for k, v in a:
            if k in ('placeholder', 'title', 'data-q', 'aria-label') and v and re.search('[a-z]{3}', v) and not re.match(r'(https?:|ssh-)', v): need.add(v)
    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'code', 'pre'): self.skip -= 1
    def handle_data(self, d):
        k = re.sub(r'\s+', ' ', d).strip()
        if not self.skip and re.search('[a-z]{2}', k) and k not in ('Français', 'Deutsch', 'English'): need.add(k)
P().feed(src[src.index('<body>'):src.index('<script>')])
print(' | '.join(sorted(need - keys)))
PYEOF
)
check "index.html: every text of the page translated (fr, de)" '[ -z "$I18NKO" ] || { echo "  untranslated: $I18NKO"; false; }'
check "index.html: the page asks for the layout of the volume and does not assume 2 bays" 'grep -q "stk.layout" "$SRC"/www/index.html && ! grep -q "bays || 2" "$SRC"/www/index.html && ! grep -q "repeat(2,1fr)" "$SRC"/www/index.html'

# The NAS runs busybox awk, stricter than the PC's (e.g. split(s, a, "},{") fails there):
# every read again with busybox awk first in PATH, answers must stay valid JSON
if command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{}' 2>/dev/null; then
	# the API puts $R/bin first in its PATH: the busybox awk goes there for this check
	[ ! -e "$R/bin/awk" ] || mv "$R/bin/awk" "$R/bin/awk.pc"
	printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$R/bin/awk"; chmod +x "$R/bin/awk"
	bbko=
	# a real X-RAID volume, so that the X-RAID parts (layout...) are computed
	export NAS_RAID_DISKS="$(ls "$R/img/clean"/*.img | tr '\n' ' ')"; rm -f "$R"/var/run/xraid.json
	echo 'xraid-rw' > "$R"/var/run/nas-raid.mode
	for a in status all services shares nfs sys users config storage; do	# storage last: checked below
		rm -rf "$R"/var/run/diet; api GET "a=$a"; printf '%s' "$OUT" | jsonok || bbko="$bbko $a"
	done
	rm -f "$R/bin/awk"; [ ! -e "$R/bin/awk.pc" ] || mv "$R/bin/awk.pc" "$R/bin/awk"
	check "busybox awk (as on the NAS): every read answer is valid JSON, X-RAID layout computed" '[ -z "$bbko" ] && json "j[\"layout\"][\"level\"]==\"raid1\" and len(j[\"layout\"][\"members\"])==2" || { echo "  invalid with busybox awk:$bbko"; false; }'
else echo "skip busybox awk check: busybox missing"; fi
check "all JSON answers of the API are valid ($NJSON)" '[ -z "$JSONKO" ] || { echo "  invalid:$JSONKO"; false; }'
echo "$((N - FAILS))/$N tests passed (root: $R)"
[ $FAILS -eq 0 ] && rm -rf "$R"
[ $FAILS -eq 0 ]
