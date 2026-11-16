#!/bin/sh
# Serveur TFTP éphémère (Docker) pour iboot : sert le dossier donné (défaut :
# output/images) sur le port UDP 69 de la machine.
#   tools/tftp-serveur.sh [dossier]
# Puis, à l'invite iboot (console série 9600 bauds) :
#   tftp <MAC-du-NAS> <IP-du-NAS> <IP-du-PC> vmlinux.k3 0x80004000
#   go 0x80004000
# (iboot déchiffre le fichier reçu ; vmlinux.k3 est produit par post-image.sh)
set -eu
DOSSIER=$(cd "${1:-$(dirname "$0")/../output/images}" && pwd)
exec docker run --rm -it --name readynas-tftp -p 69:69/udp \
	-v "$DOSSIER":/srv/tftp:ro alpine:3.20 \
	sh -c 'apk add --no-cache tftp-hpa >/dev/null && exec in.tftpd -L -v -s /srv/tftp'
