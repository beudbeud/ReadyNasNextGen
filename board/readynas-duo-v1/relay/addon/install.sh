#!/bin/sh
# ReadyNasNextGen relay: RAIDiator 4.1 add-on installer. Runs in RAIDiator
# (linuxrc unpacks the add-on into /tmp/addons/<name>, rc3 runs "sh install.sh"
# there). Installs /relay/{padre_relay.ko,relay-switch,relay-init} on the system
# volume and makes relay-init the boot switch (/sbin/init); the previous init
# (RAIDiator's, or DIET's boot switch) becomes /sbin/init.before-relay.
# Never writes the flash.
# - /sbin/init exists at every moment (linuxrc reinstalls the firmware if it is
#   missing): new files are written aside, checked, then moved into place.
# - Safe to run again: relay-init is updated, /sbin/init.before-relay is kept.
# - Migrates the hand-made install (two lines in DIET's switch) and repairs the
#   chain when DIET was installed after the relay.
# Only RAIDiator's old userland is used (no grep -F, sed -i, mktemp...).
# ROOT (tests only): prefix of every path of the system volume.
PATH=/bin:/sbin:/usr/bin:/usr/sbin
R=${ROOT:-}
SRC=$(pwd)
VER=$(cat ./relay-version 2>/dev/null)
LOG=$R/var/log/relay-install.log
exec >> $LOG 2>&1
cleanup() { cd /; rm -f $R/sbin/init.relay-new $R/sbin/init.real.relay-new; case "$SRC" in */tmp/addons/*) rm -rf "$SRC";; esac; }
fail() {
	echo "ERROR: $*"
	rm -f $R/.update_success
	echo "{RELAY_ERR} relay not installed: $* (details in /var/log/relay-install.log)" > $R/.update_fail
	cleanup
	exit 1
}
# has <string> <file>: the file contains the string (literally)
has() { awk -v s="$1" 'index($0, s) { f = 1 } END { exit !f }' "$2" 2>/dev/null; }
# ok_prev: /sbin/init.before-relay can be started and is not a relay-init (no loop)
ok_prev() { [ -x $PREV ] && ! has "$MARK" $PREV; }

INIT=$R/sbin/init
PREV=$R/sbin/init.before-relay
MARK='relay-init: boot switch of the ReadyNasNextGen relay'
# hand-made install of the first relay tests: these two lines in DIET's switch
L1='  # Linux 6.18 on a USB stick (padre_relay): returns only if DIET should start'
L2='  [ "$MODE" = "diet" ] && [ -x /relay/relay-switch ] && /relay/relay-switch'

echo "==== $(date) ReadyNasNextGen relay $VER installation (from $SRC) ===="
grep -q '^model:.*ReadyNAS Duo' $R/proc/sys/dev/boot/info 2>/dev/null || fail "only for the ReadyNAS Duo v1"
case "$(cat $R/proc/sys/kernel/osrelease 2>/dev/null)" in
2.6.17*) ;;
*) fail "kernel $(cat $R/proc/sys/kernel/osrelease 2>/dev/null) not supported (the stock 2.6.17 kernel is needed)" ;;
esac
[ -f ./padre_relay.ko ] && [ -f ./relay-switch ] && [ -f ./relay-init ] || fail "package incomplete"
has "$MARK" ./relay-init && sh -n ./relay-init || fail "package damaged (relay-init)"
[ -x $INIT ] || fail "/sbin/init missing"

mkdir -p $R/relay || fail "cannot create /relay"
for f in padre_relay.ko relay-switch relay-init; do
	cp ./$f $R/relay/$f.new && mv $R/relay/$f.new $R/relay/$f || fail "cannot copy $f to /relay"
done
chmod 755 $R/relay/relay-switch $R/relay/relay-init
echo "$VER" > $R/relay/version
echo "/relay: padre_relay.ko, relay-switch, relay-init installed"

if has "$MARK" $INIT; then
	ok_prev || fail "/sbin/init.before-relay missing or invalid, /sbin/init left unchanged"
	echo "relay-init already installed: updated, previous init kept"
else
	# the init that relay-init will start: the current one, without the two
	# lines of the hand-made install
	if has "$L2" $INIT; then
		awk -v l1="$L1" -v l2="$L2" '$0 != l1 && $0 != l2' $INIT > $R/sbin/init.relay-new || fail "cannot write /sbin/init.relay-new"
		chmod 755 $R/sbin/init.relay-new
		sh -n $R/sbin/init.relay-new || fail "cannot remove the hand-made relay lines, /sbin/init left unchanged"
		echo "hand-made relay install found in /sbin/init: migrated (two lines removed)"
	else
		cp -p $INIT $R/sbin/init.relay-new || fail "cannot copy /sbin/init"
	fi
	# DIET installed after the relay: DIET's switch starts RAIDiator through
	# /sbin/init.real = a relay-init; give it back the init behind it
	if has Weichensteller $INIT && has "$MARK" $R/sbin/init.real; then
		ok_prev || fail "/sbin/init.real is a relay-init but /sbin/init.before-relay is missing, /sbin/init left unchanged"
		cp -p $PREV $R/sbin/init.real.relay-new && mv $R/sbin/init.real.relay-new $R/sbin/init.real \
			|| fail "cannot restore /sbin/init.real"
		echo "DIET was installed after the relay: /sbin/init.real restored"
	fi
	mv $R/sbin/init.relay-new $PREV || fail "cannot write /sbin/init.before-relay"
	echo "previous /sbin/init kept as /sbin/init.before-relay"
fi
cp -p ./relay-init $R/sbin/init.relay-new && chmod 755 $R/sbin/init.relay-new || fail "cannot copy relay-init"
mv $R/sbin/init.relay-new $INIT || fail "cannot install relay-init as /sbin/init"
rm -f $R/relay/addons-seen
sync
echo "OK: relay $VER installed. With a prepared USB stick plugged in, the next boot starts Linux 6.18."
# Installed at boot (rc3, after an update through Frontview): reboot by itself after 2 minutes
if [ -n "$RUNLEVEL" ]; then
	echo "Installed at boot: automatic restart in 2 minutes"
	( sleep 120; $R/sbin/reboot ) </dev/null >/dev/null 2>&1 &
fi
cleanup
exit 0
