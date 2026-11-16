#!/bin/sh
# Throwaway TFTP server (Docker) for iboot: serves the given folder (default:
# output/images) on UDP port 69 of the machine.
#   tools/tftp-server.sh [folder]
# Then, at the iboot prompt (serial console, 9600 baud):
#   tftp <NAS-MAC> <NAS-IP> <PC-IP> vmlinux.k3 0x80004000
#   go 0x80004000
# (iboot decrypts the received file; vmlinux.k3 is produced by post-image.sh)
set -eu
FOLDER=$(cd "${1:-$(dirname "$0")/../output/images}" && pwd)
exec docker run --rm -it --name readynas-tftp -p 69:69/udp \
	-v "$FOLDER":/srv/tftp:ro alpine:3.20 \
	sh -c 'apk add --no-cache tftp-hpa >/dev/null && exec in.tftpd -L -v -s /srv/tftp'
