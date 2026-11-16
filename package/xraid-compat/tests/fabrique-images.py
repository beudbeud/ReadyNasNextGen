#!/usr/bin/env python3
"""Fabrique des images disque X-RAID factices (fichiers creux) pour les essais.

Disposition d'après docs/XRAID.md (installation RAIDiator, Duo, RAID 1) :
superbloc « WGao » en N-4096 (+ copies N-4072, N-4048, N-4024), marque
« WGam » en N-2, MBR seulement sur le disque base, sections 0 (32, 4 096 000)
et 1 (4 096 032, V - 4 096 002), p1/p2/p3 étendue/p5 LVM.
Rien n'est repris d'un vrai disque : identifiants et dates sont inventés.

  fabrique-images.py DOSSIER SCENARIO [N]
SCENARIO : propre | sale | degrade | synchro | different | md | grand
Écrit DOSSIER/sda.img (miroir, canal SATA 0) et DOSSIER/sdb.img (base,
canal SATA 1), comme sur le Duo où la base était hde ; « degrade » n'écrit
que sdb.img ; « md » ajoute un superbloc md 1.2 sur sda.img (disque déjà migré).
"""
import os
import struct
import sys

SB_LEN = 0x24E0
V_FIXE = {  # classes de taille (§2) : fenêtre de N -> V fixe
    0x575416F0: (0x575426F0, 0x585426EF),
}


def taille_visible(n):
    for v, (lo, hi) in V_FIXE.items():
        if lo <= n <= hi:
            return v
    return n - 0x5000


def mbr(parts):
    b = bytearray(512)
    for i, (typ, deb, nb) in enumerate(parts):
        o = 0x1BE + 16 * i
        b[o + 4] = typ
        struct.pack_into("<II", b, o + 8, deb, nb)
    b[510:512] = b"\x55\xaa"
    return b


def superbloc(n, v, sections, disques, propre=True, init_mark=0, this=1, table_mbr=b""):
    sb = bytearray(SB_LEN)
    struct.pack_into(">IIII", sb, 0, 0x5747616F, 0, 1, 0)
    struct.pack_into(">II", sb, 0x14, 0x0A0B0C0D, 1200000000)    # id et date inventés
    struct.pack_into(">IIII", sb, 0x1C, 1, v, 2, 2)
    sb[0x30:0x34] = bytes([0, 1, 1, 0])     # parité = canal 0, LBA48, base = canal 1, pas de fictif
    struct.pack_into(">I", sb, 0x84, 1 if propre else 0)
    struct.pack_into(">IIII", sb, 0x88, 2, 2, 0, 0)
    struct.pack_into(">I", sb, 0x100, len(sections))
    for idx, (miroir, etat) in disques.items():
        o = 0x200 + 128 * idx
        sb[o] = 1 if miroir else 0
        sb[o + 1] = 0 if miroir else 1
        sb[o + 2] = idx
        sb[o + 3] = idx - 1
        sb[o + 7] = 22 if idx == 1 else 33
        struct.pack_into(">III", sb, o + 0x0C, idx - 1, etat, 1)
        if not miroir:
            sb[o + 0x18:o + 0x58] = table_mbr[0x1C0:0x200]
        struct.pack_into(">I", sb, o + 0x58, v)
    for k, (deb, nb) in enumerate(sections):
        o = 0x800 + 32 * k
        sb[o + 1], sb[o + 2], sb[o + 3], sb[o + 4], sb[o + 5], sb[o + 6] = k, 1, 0, 6, 1, 1
        struct.pack_into(">I", sb, o + 8, init_mark if k == 1 else 0)
        struct.pack_into(">I", sb, o + 0x10, deb)
        struct.pack_into(">I", sb, o + 0x18, nb)
    sb[0x1460:0x14E0] = sb[0x200 + 128 * this:0x280 + 128 * this]
    return sb


def ecrire(f, lba, data):
    f.seek(lba * 512)
    f.write(data)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    dossier, scen = sys.argv[1], sys.argv[2]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else (1465149168 if scen == "grand" else 8388608)
    v = taille_visible(n)
    data = v - 4624384
    parts = [(0x83, 32, 4096000), (0x82, 4096032, 512000), (0x05, 4608032, data)]
    table = mbr(parts)
    ebr = mbr([(0x8E, 8, data - 8)])
    sections = [(32, 4096000), (4096032, v - 4096000 - 2)]
    etat_miroir = 8 if scen == "synchro" else 1
    disques = {1: (True, etat_miroir), 2: (False, 1)}
    os.makedirs(dossier, exist_ok=True)
    for nom, canal in (("sda", 1), ("sdb", 2)):
        chemin = os.path.join(dossier, nom + ".img")
        if os.path.exists(chemin):
            os.unlink(chemin)
        if scen == "degrade" and nom == "sda":
            continue
        with open(chemin, "wb") as f:
            f.truncate(n * 512)
            if nom == "sdb":
                ecrire(f, 0, table)                       # MBR : disque base seulement
            ecrire(f, 4608032, ebr)                       # EBR dans la section 1 (sur les deux)
            ecrire(f, 32 + 2, b"\x53\xef")                # contenu identique sur les deux
            ecrire(f, 4608040 + 1, b"LABELONE")
            if scen == "different" and nom == "sda":
                ecrire(f, 4096032, b"ECART")              # 1er échantillon de la section 1
            sb = superbloc(n, v, sections, disques, propre=(scen != "sale"),
                           init_mark=(123456 if scen == "synchro" else 0), this=canal, table_mbr=table)
            for dec in (4096, 4072, 4048, 4024):
                ecrire(f, n - dec, sb)
            ecrire(f, n - 2, b"WGam")
            if scen == "md" and nom == "sda":
                for dec in (4096, 4072, 4048, 4024):     # nas-raid efface la zone X-RAID
                    ecrire(f, n - dec, bytes(SB_LEN))
                f.seek(4096)
                f.write(struct.pack("<I", 0xa92b4efc))   # superbloc md 1.2
    print("N=%d V=%d donnees=%d" % (n, v, data))


if __name__ == "__main__":
    main()
