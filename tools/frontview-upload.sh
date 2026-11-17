#!/bin/sh
# Install a RAIDiator add-on (.bin) through Frontview from a PC, without a browser.
# RAIDiator 4.1 only speaks TLS 1.0 with DHE-RSA-AES256-SHA, which current browsers
# refuse; curl can still be told to use it for this one connection.
#
#   sh tools/frontview-upload.sh <nas-address> <addon.bin> [admin-user]
#   (without a terminal: FRONTVIEW_PASSWORD=... and FRONTVIEW_YES=1 to skip the questions;
#    FRONTVIEW_NO_REBOOT=1 to leave the restart to you)
#
# Same requests as Frontview: "System > Update > Local" uploads and verifies
# (CheckUpdateFile), then "Perform System Update" (LocalUpdate). RAIDiator does not restart
# by itself after that: Frontview sends the user to "System > Shutdown", and so does this
# script (reboot). RAIDiator installs the add-on during that boot, then the add-on restarts
# the NAS once more about 2 minutes later.
set -e
NAS=${1:?usage: $0 <nas-address> <addon.bin> [admin-user]}
BIN=${2:?usage: $0 <nas-address> <addon.bin> [admin-user]}
USER=${3:-admin}
[ -f "$BIN" ] || { echo "no such file: $BIN"; exit 1; }

# Password: FRONTVIEW_PASSWORD, or asked on the terminal.
PASS=${FRONTVIEW_PASSWORD:-}
if [ -z "$PASS" ]; then
	[ -t 0 ] || { echo "no terminal: set FRONTVIEW_PASSWORD"; exit 1; }
	printf 'Frontview password for %s@%s: ' "$USER" "$NAS"
	stty -echo; read -r PASS; stty echo; echo
fi

# The password goes to curl on stdin (-K -), never on the command line.
fv() {
	printf 'user = "%s:%s"\n' "$USER" "$PASS" | curl -sS -k -K - \
		--tlsv1.0 --tls-max 1.0 --ciphers 'DHE-RSA-AES256-SHA:@SECLEVEL=0' \
		-m 600 "$@" "https://$NAS/get_handler"
}
text() { sed -e 's/<[^>]*>/ /g' -e 's/&nbsp;/ /g' | tr -s ' \t' ' ' | grep -v '^ *$' || true; }

echo "1/3 upload and verify $(basename "$BIN")..."
R=$(fv -F PAGE=System -F OPERATION=set -F command=CheckUpdateFile -F "update_file=@$BIN")
echo "$R" | text | head -20
case "$R" in
	*401*|*Authorization*) echo "authentication failed"; exit 1 ;;
esac

if [ "${FRONTVIEW_YES:-}" != 1 ]; then
	[ -t 0 ] || { echo "verified only; set FRONTVIEW_YES=1 to perform the update"; exit 0; }
	printf 'Perform the update now (the NAS will reboot)? [y/N] '
	read -r ok
	[ "$ok" = y ] || { echo "not installed"; exit 0; }
fi

echo "2/3 perform system update..."
fv --data 'OPERATION=set&command=LocalUpdate&PAGE=System&OUTER_TAB=NONE&INNER_TAB=NONE' | text | head -20

if [ "${FRONTVIEW_NO_REBOOT:-}" = 1 ]; then
	echo "update staged; restart the NAS to install it (Frontview: System > Shutdown, or the power button)"
	exit 0
fi
echo "3/3 reboot..."
# "System > Shutdown > Shutdown and reboot". Request as documented by RAIDiator 4.x users
# (the shutdown page itself is not in our Frontview extract). The NAS may drop the
# connection while it goes down: not an error.
fv -m 30 --data 'PAGE=System&OUTER_TAB=tab_shutdown&INNER_TAB=NONE&shutdown_option2=1&command=reboot&OPERATION=set' \
	| text | head -5 || true
cat <<EOM
reboot requested. Now wait, the NAS restarts twice:
  1. RAIDiator reboots and installs the add-on (a few minutes);
  2. about 2 minutes after it is up, the add-on restarts the NAS again by itself.
Do not power it off in between. Install log on the NAS: /var/log/relay-install.log
EOM
