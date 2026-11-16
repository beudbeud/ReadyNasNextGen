#!/usr/bin/env python3
"""Interrompt iboot sur la console série puis tape des commandes une par une.

Usage : iboot-cmd.py JOURNAL "commande1" "commande2" ...
  ex. : iboot-cmd.py essai.log "tftp $NAS_MAC $NAS_IP $PC_IP vmlinux.k3 0x80004000" "go 0x80004000"

Variables d'environnement :
  NAS_SERIE  port série (défaut /dev/ttyUSB0), 9600 bauds
  NAS_SSH    facultatif, ex. root@<ip-du-nas> : redémarre le NAS par SSH au
             lieu d'attendre qu'on le mette sous tension à la main

Après chaque commande, attend le retour de l'invite (pour « go » : capture
jusqu'à « login: », « shell de secours » ou « Kernel panic », 15 min au plus).
Rien n'est écrit en flash : n'envoyez jamais de commande d'écriture NAND.
"""
import os, serial, subprocess, sys, time

log = open(sys.argv[1], "wb"); cmds = sys.argv[2:]
p = serial.Serial(os.environ.get("NAS_SERIE", "/dev/ttyUSB0"), 9600, timeout=0.05); vu = b""


def lire(d):
    global vu
    fin = time.time() + d
    while time.time() < fin:
        b = p.read(512)
        if b: vu += b; log.write(b); log.flush()


def note(t): print(time.strftime("%H:%M:%S"), t, flush=True)


def taper(t):
    for c in t.encode(): p.write(bytes([c])); lire(0.15)


p.reset_input_buffer()
if os.environ.get("NAS_SSH"):
    subprocess.Popen(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", os.environ["NAS_SSH"],
                      "sync; reboot"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    note("redemarrage demande")
else:
    note("mettez le NAS sous tension")
fin = time.time() + 300
while b"Reason:" not in vu and time.time() < fin: lire(0.2)
if b"Reason:" not in vu: sys.exit("pas de Reason:")
for _ in range(12):
    if b"iboot> " in vu or b"zlist" in vu: break
    p.write(b"i"); lire(0.2)
lire(2)
if b"iboot> " not in vu: sys.exit("invite non obtenue (demarrage normal en cours)")
note("invite obtenue ; vidage de la ligne")
taper("\r"); lire(1.5)
for c in cmds:
    debut = len(vu); taper(c + "\r")
    note("envoye : " + c)
    if c.startswith("go") or c == "auto":
        fin = time.time() + 900
        while time.time() < fin and not any(m in vu[debut:] for m in (b"login:", b"shell de secours", b"Kernel panic")):
            lire(1)
        note("fin : %d octets apres go" % (len(vu) - debut)); break
    fin = time.time() + 900
    while time.time() < fin and not vu[debut:].rstrip().endswith(b"iboot>"): lire(0.5)
    note("invite revenue" if vu[debut:].rstrip().endswith(b"iboot>") else "pas d'invite apres " + c)
