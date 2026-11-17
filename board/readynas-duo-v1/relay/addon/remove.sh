#!/bin/sh
# ReadyNasNextGen relay: RAIDiator 4.1 add-on that removes the relay (shipped as
# install.sh of the "remove" add-on). Puts the init that was there before the
# relay back as /sbin/init (byte for byte: it is moved back, not rewritten) and
# deletes /relay. Also handles DIET installed after the relay (relay-init behind
# DIET's switch as /sbin/init.real) and the hand-made install (two lines in DIET's
# switch). DIET itself is left alone. Safe to run again.
# ROOT (tests only): prefix of every path of the system volume.
PATH=/bin:/sbin:/usr/bin:/usr/sbin
R=${ROOT:-}
SRC=$(pwd)
LOG=$R/var/log/relay-install.log
exec >> $LOG 2>&1
cleanup() { cd /; rm -f $R/sbin/init.relay-new; case "$SRC" in */tmp/addons/*) rm -rf "$SRC";; esac; }
fail() {
	echo "ERROR: $*"
	rm -f $R/.update_success
	echo "{RELAY_ERR} relay not removed: $* (details in /var/log/relay-install.log)" > $R/.update_fail
	cleanup
	exit 1
}
has() { awk -v s="$1" 'index($0, s) { f = 1 } END { exit !f }' "$2" 2>/dev/null; }
ok_prev() { [ -x $PREV ] && ! has "$MARK" $PREV; }

INIT=$R/sbin/init
PREV=$R/sbin/init.before-relay
MARK='relay-init: boot switch of the ReadyNasNextGen relay'
L1='  # Linux 6.18 on a USB stick (padre_relay): returns only if DIET should start'
L2='  [ "$MODE" = "diet" ] && [ -x /relay/relay-switch ] && /relay/relay-switch'

echo "==== $(date) ReadyNasNextGen relay removal ===="
if has "$MARK" $INIT; then
	ok_prev || fail "/sbin/init.before-relay missing or invalid, /sbin/init left unchanged"
	mv $PREV $INIT || fail "cannot restore /sbin/init"
	echo "/sbin/init: previous init restored"
elif has Weichensteller $INIT && has "$MARK" $R/sbin/init.real; then
	ok_prev || fail "/sbin/init.before-relay missing or invalid, /sbin/init.real left unchanged"
	mv $PREV $R/sbin/init.real || fail "cannot restore /sbin/init.real"
	echo "/sbin/init.real (behind DIET's switch): previous init restored"
elif has "$L2" $INIT; then
	awk -v l1="$L1" -v l2="$L2" '$0 != l1 && $0 != l2' $INIT > $R/sbin/init.relay-new || fail "cannot write /sbin/init.relay-new"
	chmod 755 $R/sbin/init.relay-new
	sh -n $R/sbin/init.relay-new && ! has "$L2" $R/sbin/init.relay-new || fail "cleaned boot switch is invalid, /sbin/init left unchanged"
	mv $R/sbin/init.relay-new $INIT || fail "cannot restore /sbin/init"
	echo "/sbin/init: hand-made relay lines removed"
fi
rm -f $PREV $R/.relay_skip_once
rm -rf $R/relay
sync
echo "OK: relay removed"
cleanup
exit 0
