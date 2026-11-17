#!/bin/sh
# Checks the relay on the PC, without a NAS:
# - decodes the 512-byte add-on headers (fields, size, md5 as Frontview does),
#   extracts the tars like linuxrc;
# - runs install.sh / the remove add-on in simulated system volumes (ROOT=...):
#   stock RAIDiator, DIET installed, hand-made install (two lines in DIET's
#   switch), DIET installed after the relay; install, install again, remove,
#   remove again, and the previous init back byte for byte;
# - runs relay-init's decisions (pid 1 check and paths redirected to the
#   simulated volume, relay-switch and the previous init replaced by stubs).
# Each scenario runs with sh and, if present, busybox sh.
#   test-addon.sh [install.bin remove.bin]   (default: output-relay/*_<VERSION>.bin)
#   DIET_INIT=/path/init-weiche   use DIET's real boot switch instead of the stand-in
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
VERSION=${VERSION:-1.0}
INST=${1:-$TOP/output-relay/ReadyNasNextGen_relay_$VERSION.bin}
REM=${2:-$TOP/output-relay/ReadyNasNextGen_relay_remove_$VERSION.bin}
L1='  # Linux 6.18 on a USB stick (padre_relay): returns only if DIET should start'
L2='  [ "$MODE" = "diet" ] && [ -x /relay/relay-switch ] && /relay/relay-switch'
ANCHOR='[ -x /diet/sbin/init ] || {'

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0
ok() { echo "  ok   $*"; }
ko() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { m=$1; shift; if "$@"; then ok "$m"; else ko "$m"; fi; }

# Stand-ins: RAIDiator's init, and DIET's boot switch (same marker and anchor line)
printf '#!/bin/sh\n# stand-in for RAIDiator init\necho stock init\n' > "$T/raidiator-init"
if [ -n "${DIET_INIT:-}" ]; then
	cp "$DIET_INIT" "$T/diet-switch"
else
	cat > "$T/diet-switch" <<'EOF'
#!/bin/sh
# Weichensteller: test stand-in for DIET's boot switch
if [ $$ -eq 1 ]; then
  MODE=diet; R=""
  [ -f /.raidiator_once ] && { rm -f /.raidiator_once; MODE=raidiator; R=requested; }
  [ -x /diet/sbin/init ] || { MODE=raidiator; R="/diet missing"; }
  if [ "$MODE" = "diet" ]; then
    exec /usr/sbin/chroot /diet /sbin/init
  fi
  echo "starting RAIDiator ($R)" >> /diet-boot.log
fi
exec /sbin/init.real "$@"
EOF
fi
# DIET's switch with the hand-made relay install (the two lines after the /diet test)
awk -v a="$ANCHOR" -v l1="$L1" -v l2="$L2" '{ print } !d && index($0, a) { print l1; print l2; d = 1 }' \
	"$T/diet-switch" > "$T/diet-switch-manual"
chmod 755 "$T/raidiator-init" "$T/diet-switch" "$T/diet-switch-manual"

# decode <bin>: prints the add-on name; checks the header like Frontview/linuxrc
decode() {
	ko() { echo "  FAIL $*" >&2; }
	hdr=$(head -c 512 "$1" | tr -d '\000' | head -n 1)
	echo "$hdr" | grep -Eq '^addon::name=[A-Za-z0-9_]+,version=[^,]+,time=[0-9]+,size=[0-9]+,md5sum=[0-9a-f]{32},unencrypted=1$' \
		|| { ko "$1: header '$hdr'"; return 1; }
	[ "$(head -c 512 "$1" | tr -d '\000' | wc -c)" = $((${#hdr} + 1)) ] || { ko "$1: header not zero padded"; return 1; }
	size=$(echo "$hdr" | sed 's/.*,size=\([0-9]*\),.*/\1/')
	md5=$(echo "$hdr" | sed 's/.*,md5sum=\([0-9a-f]*\),.*/\1/')
	[ "$size" = $(($(stat -c %s "$1") - 512)) ] || { ko "$1: size $size"; return 1; }
	[ "$(dd if="$1" skip=1 bs=512 2>/dev/null | md5sum | cut -d' ' -f1)" = "$md5" ] || { ko "$1: md5"; return 1; }
	echo "$hdr" | sed 's/^addon::name=\([^,]*\),.*/\1/'
}

echo "== headers"
NI=$(decode "$INST") || exit 1
ok "$(basename "$INST"): name $NI, size and md5 match"
NR=$(decode "$REM") || exit 1
ok "$(basename "$REM"): name $NR, size and md5 match"
mkdir "$T/pkg"
dd if="$INST" skip=1 bs=512 2>/dev/null | tar -xf - -C "$T/pkg"
check "install add-on holds install.sh, padre_relay.ko, relay-switch, relay-init" \
	test -f "$T/pkg/install.sh" -a -f "$T/pkg/padre_relay.ko" -a -x "$T/pkg/relay-switch" -a -x "$T/pkg/relay-init"

# run <shell> <bin> <name> <root>: unpack like linuxrc, then "sh install.sh" there like rc3
run() {
	mkdir -p "$4/tmp/addons/$3"
	dd if="$2" skip=1 bs=512 2>/dev/null | tar -xf - -C "$4/tmp/addons/$3"
	(cd "$4/tmp/addons/$3" && env -u RUNLEVEL ROOT="$4" $1 install.sh)
}
# newroot <dir> <init> [<init.real>]: simulated RAIDiator system volume
newroot() {
	rm -rf "$1"
	mkdir -p "$1/sbin" "$1/var/log" "$1/proc/sys/dev/boot" "$1/proc/sys/kernel"
	echo "model: ReadyNAS Duo" > "$1/proc/sys/dev/boot/info"
	echo "2.6.17.14ReadyNAS" > "$1/proc/sys/kernel/osrelease"
	cp -p "$2" "$1/sbin/init"
	[ -z "${3:-}" ] || cp -p "$3" "$1/sbin/init.real"
}
# state <root>: every file of the volume except logs, with md5 and mode
state() { (cd "$1" && find . -type f ! -name '*.log' ! -path './proc/*' | sort | while read f; do echo "$(md5sum < "$f") $(stat -c %a "$f") $f"; done); }

# scenario <shell> <label> <init> <init.real or ""> <expected init.before-relay> <expected init after remove>
#   [<expected init.real after install>]
scenario() {
	SH=$1; L=$2
	echo "-- $L"
	R=$T/root; newroot "$R" "$3" "$4"
	case "$L" in *hand-made*) mkdir -p "$R/relay"; cp "$T/pkg/relay-switch" "$T/pkg/padre_relay.ko" "$R/relay/";
		cp -p "$T/diet-switch" "$R/sbin/init.before-relay"; echo "old log" > "$R/relay/relay.log" ;; esac
	case "$L" in *after*) cp -p "$T/raidiator-init" "$R/sbin/init.before-relay" ;; esac
	[ -z "$4" ] || cp -p "$R/sbin/init.real" "$T/real-before"
	check "$L: install" run "$SH" "$INST" "$NI" "$R"
	check "$L: add-on directory removed" test ! -e "$R/tmp/addons/$NI"
	check "$L: /sbin/init is relay-init" cmp -s "$R/sbin/init" "$HERE/relay-init"
	check "$L: /sbin/init executable" test -x "$R/sbin/init"
	check "$L: /sbin/init.before-relay = $(basename "$5")" cmp -s "$R/sbin/init.before-relay" "$5"
	check "$L: /sbin/init.before-relay executable" test -x "$R/sbin/init.before-relay"
	[ -z "${7:-}" ] || check "$L: /sbin/init.real = $(basename "$7")" cmp -s "$R/sbin/init.real" "$7"
	[ -n "${7:-}" ] || [ -z "$4" ] || check "$L: /sbin/init.real untouched" cmp -s "$R/sbin/init.real" "$T/real-before"
	check "$L: /relay complete" sh -c 'cmp -s "$1/relay/padre_relay.ko" "$2/padre_relay.ko" && test -x "$1/relay/relay-switch" -a -x "$1/relay/relay-init"' - "$R" "$T/pkg"
	check "$L: install log" grep -q '^OK: relay' "$R/var/log/relay-install.log"
	case "$L" in *hand-made*) check "$L: old relay.log kept" grep -q "old log" "$R/relay/relay.log" ;; esac
	state "$R" > "$T/s1"
	echo x > "$R/relay/disabled"	# user state must survive a reinstall
	check "$L: install again" run "$SH" "$INST" "$NI" "$R"
	check "$L: user state kept (/relay/disabled)" test -f "$R/relay/disabled"
	rm -f "$R/relay/disabled"
	state "$R" > "$T/s2"
	check "$L: idempotent (same files, contents, modes)" cmp -s "$T/s1" "$T/s2"
	check "$L: remove" run "$SH" "$REM" "$NR" "$R"
	check "$L: remove directory removed" test ! -e "$R/tmp/addons/$NR"
	check "$L: /sbin/init back to $(basename "$6"), byte for byte" cmp -s "$R/sbin/init" "$6"
	check "$L: /sbin/init executable" test -x "$R/sbin/init"
	[ -z "$4" ] || check "$L: /sbin/init.real back to the original" cmp -s "$R/sbin/init.real" "$T/raidiator-init"
	check "$L: /relay and /sbin/init.before-relay removed" test ! -e "$R/relay" -a ! -e "$R/sbin/init.before-relay"
	state "$R" > "$T/s3"
	check "$L: remove again" run "$SH" "$REM" "$NR" "$R"
	state "$R" > "$T/s4"
	check "$L: remove again changes nothing" cmp -s "$T/s3" "$T/s4"
	check "$L: no leftover in /sbin" test -z "$(ls "$R/sbin" | grep -v '^init$' | grep -v '^init.real$')"
}

# relay-init decisions: R= set to the simulated volume, pid 1 check removed
sed -e "s|^R=\$|R=$T/ri|" -e 's|\[ \$\$ -eq 1 \]|true|' "$HERE/relay-init" > "$T/relay-init.test"
boot() {	# boot <shell>: runs relay-init once, prints what was called
	: > "$T/ri/calls"
	$1 "$T/relay-init.test" 3 >/dev/null 2>&1 || true
	tr '\n' ' ' < "$T/ri/calls"
}

SHELLS=sh
command -v busybox >/dev/null 2>&1 && SHELLS="sh|busybox sh"
IFS='|'
for SH in $SHELLS; do
	IFS=' '
	echo "== shell: $SH"
	R=$T/root; newroot "$R" "$T/raidiator-init"
	cp -p "$T/raidiator-init" "$T/orig"
	mv "$R/proc/sys/kernel/osrelease" "$T/osr"; echo 6.18.63 > "$R/proc/sys/kernel/osrelease"
	if run "$SH" "$INST" "$NI" "$R"; then ko "refused on another kernel"; else ok "refused on another kernel"; fi
	check "refusal: /sbin/init unchanged, nothing installed" sh -c 'cmp -s "$1/sbin/init" "$2" && test ! -e "$1/relay" -a ! -e "$1/sbin/init.before-relay"' - "$R" "$T/orig"
	check "refusal: error reported (/.update_fail), add-on directory removed" sh -c 'grep -q "not supported" "$1/.update_fail" && test ! -e "$1/tmp/addons/$2"' - "$R" "$NI"

	scenario "$SH" "stock RAIDiator" "$T/raidiator-init" "" "$T/raidiator-init" "$T/raidiator-init"
	scenario "$SH" "DIET installed" "$T/diet-switch" "$T/raidiator-init" "$T/diet-switch" "$T/diet-switch"
	scenario "$SH" "hand-made install under DIET" "$T/diet-switch-manual" "$T/raidiator-init" "$T/diet-switch" "$T/diet-switch"
	# DIET installed after the relay: /sbin/init = DIET's switch, /sbin/init.real = relay-init
	scenario "$SH" "DIET installed after the relay" "$T/diet-switch" "$HERE/relay-init" "$T/diet-switch" "$T/diet-switch" "$T/raidiator-init"

	echo "-- remove with DIET installed after the relay (no reinstall)"
	R=$T/root; newroot "$R" "$T/diet-switch" "$HERE/relay-init"
	cp -p "$T/raidiator-init" "$R/sbin/init.before-relay"; mkdir "$R/relay"
	check "remove" run "$SH" "$REM" "$NR" "$R"
	check "/sbin/init (DIET's switch) unchanged" cmp -s "$R/sbin/init" "$T/diet-switch"
	check "/sbin/init.real back to the original" cmp -s "$R/sbin/init.real" "$T/raidiator-init"
	check "/relay and /sbin/init.before-relay removed" test ! -e "$R/relay" -a ! -e "$R/sbin/init.before-relay"

	echo "-- relay-init decisions"
	rm -rf "$T/ri"; mkdir -p "$T/ri/relay" "$T/ri/sbin" "$T/ri/tmp/addons"
	printf '#!/bin/sh\necho switch >> %s/ri/calls\n' "$T" > "$T/ri/relay/relay-switch"
	printf '#!/bin/sh\necho "previous $*" >> %s/ri/calls\n' "$T" > "$T/ri/sbin/init.before-relay"
	chmod 755 "$T/ri/relay/relay-switch" "$T/ri/sbin/init.before-relay"
	check "normal boot: relay-switch, then the previous init with its arguments" test "$(boot "$SH")" = "switch previous 3 "
	touch "$T/ri/relay/disabled"
	check "/relay/disabled: previous init only" test "$(boot "$SH")" = "previous 3 "
	rm "$T/ri/relay/disabled"; touch "$T/ri/.raidiator_once"
	check "/.raidiator_once: previous init only, marker left for DIET" sh -c 'test "$1" = "previous 3 " && test -f "$2"' - "$(boot "$SH")" "$T/ri/.raidiator_once"
	rm "$T/ri/.raidiator_once"; touch "$T/ri/.new_addons"
	check "/.new_addons: previous init only" test "$(boot "$SH")" = "previous 3 "
	rm "$T/ri/.new_addons"; mkdir "$T/ri/tmp/addons/X"; touch "$T/ri/tmp/addons/X/install.sh"
	check "add-on waiting: previous init only" test "$(boot "$SH")" = "previous 3 "
	check "same add-on still there next boot: relay tried again" test "$(boot "$SH")" = "switch previous 3 "
	echo changed >> "$T/ri/tmp/addons/X/install.sh"
	check "add-on changed: previous init only" test "$(boot "$SH")" = "previous 3 "
	rm -r "$T/ri/tmp/addons/X"
	check "no add-on: relay, seen list cleared" sh -c 'test "$1" = "switch previous 3 " && test ! -e "$2"' - "$(boot "$SH")" "$T/ri/relay/addons-seen"
	rm "$T/ri/relay/relay-switch"
	check "no /relay/relay-switch: previous init only" test "$(boot "$SH")" = "previous 3 "
	IFS='|'
done
IFS=' '
check "relay-switch syntax" sh -n "$HERE/relay-switch"
check "relay-init syntax" sh -n "$HERE/relay-init"
[ $FAILS = 0 ] && echo "== all checks passed" || { echo "== $FAILS check(s) failed"; exit 1; }
