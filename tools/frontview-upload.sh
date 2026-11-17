#!/bin/sh
# Install a RAIDiator add-on (.bin) through Frontview from a PC, without a browser.
# RAIDiator 4.1 only speaks TLS 1.0 with DHE-RSA-AES256-SHA, which current browsers
# refuse; curl can still be told to use it for this one connection.
#
#   sh tools/frontview-upload.sh <nas-address> <addon.bin> [admin-user]
#   (without a terminal: FRONTVIEW_PASSWORD=... and FRONTVIEW_YES=1 to skip the questions)
#
# Same two requests as Frontview's "System > Update > Local" page: upload and verify
# (CheckUpdateFile), then "Perform System Update" (LocalUpdate). The NAS then reboots
# to install the add-on.
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

echo "1/2 upload and verify $(basename "$BIN")..."
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

echo "2/2 perform system update..."
fv --data 'OPERATION=set&command=LocalUpdate&PAGE=System&OUTER_TAB=NONE&INNER_TAB=NONE' | text | head -20
echo "done: the NAS installs the add-on while it reboots"
