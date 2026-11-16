#!/bin/sh
# post-image.sh (Buildroot, BR2_ROOTFS_POST_IMAGE_SCRIPT) pour le noyau 6.18
# du ReadyNAS Duo v1 : vmlinux.bin brut pour iboot, contrôles statiques,
# copie chiffrée -k3 pour la commande tftp d'iboot.
# N'écrit que dans $BINARIES_DIR et $BUILD_DIR (aucun accès au NAS ni à la flash).
set -eu

B="$BINARIES_DIR"
ICI="$(cd "$(dirname "$0")" && pwd)"
X="$HOST_DIR/bin/sparc-buildroot-linux-uclibc-"
[ -x "${X}objcopy" ] || X="$HOST_DIR/bin/sparc-linux-"

"${X}objcopy" -O binary "$B/vmlinux" "$B/vmlinux.bin"

echo "== contrôles de $B/vmlinux"
echo "-- point d'entrée et adresse de chargement (attendu 0x80004000)"
entree=$("${X}readelf" -h "$B/vmlinux" | sed -n 's/.*Entry point address: *//p')
debut=$("${X}nm" "$B/vmlinux" | sed -n 's/^\([0-9a-f]*\) [Tt] _start$/0x\1/p')
fin=$("${X}nm" "$B/vmlinux" | sed -n 's/^\([0-9a-f]*\) [A-Za-z] _end$/0x\1/p')
echo "   entrée $entree, _start $debut, _end $fin"
[ "$debut" = "0x80004000" ] || { echo "ERREUR : _start n'est pas en 0x80004000"; exit 1; }
# Sans initrd séparé (initramfs intégré), le noyau peut dépasser 0x8100_0000 ;
# il doit rester sous les tampons d'iboot (0x860f_f000).
if [ $((fin)) -gt $((0x860f0000)) ]; then
	echo "ERREUR : _end ($fin) atteint les tampons d'iboot (0x860f_f000)"
	exit 1
elif [ $((fin)) -gt $((0x81000000)) ]; then
	echo "   NB : _end > 0x81000000 : ne pas charger d'initrd d'iboot avec ce noyau"
fi
taille=$(stat -c %s "$B/vmlinux.bin")
echo "   vmlinux.bin : $taille octets (max $((0x81000000 - 0x80004000)))"

echo "-- instructions interdites (sdiv/sdivcc : faux sur Padre ; casa : absente)"
"${X}objdump" -d --no-show-raw-insn "$B/vmlinux" > "$BUILD_DIR/vmlinux.dis"
if grep -E '[[:space:]](sdiv|sdivcc|casa)[[:space:]]' "$BUILD_DIR/vmlinux.dis"; then
	echo "ERREUR : instruction interdite dans vmlinux"
	exit 1
fi
echo "   aucune"

# Chemin d'émulation FPU (le Padre n'a pas de FPU) : aucune instruction
# flottante exécutée par le noyau, et pas de last_task_used_math (jamais mis
# sur Padre : NULL, cause de l'arrêt au 1er FPop arithmétique).
echo "-- chemin d'émulation FPU (aucune instruction FPU, pas de last_task_used_math)"
for fn in fpd_trap_handler do_fpd_trap do_mathemu do_one_mathemu \
	  padre_ldst_mathemu padre_fbranch_mathemu record_exception \
	  safe_compute_effective_address safe_fetch_reg maybe_flush_windows; do
	corps=$(awk -v f="<$fn>:" '$2 == f { p = 1; next } p && /^$/ { exit } p' "$BUILD_DIR/vmlinux.dis")
	if [ -z "$corps" ]; then
		case $fn in
		fpd_trap_handler|do_fpd_trap|do_mathemu)
			echo "ERREUR : $fn absent de vmlinux"; exit 1 ;;
		*)	continue ;;	# fonction statique intégrée à son appelant
		esac
	fi
	if printf '%s\n' "$corps" | grep -E '%f[0-9]|%fsr|%fq|[[:space:]]fb[a-z,]*[[:space:]]|[[:space:]]f(add|sub|mul|div|sqrt|mov|neg|abs|cmp|ito|sto|dto|qto|smul|dmul)[a-z]*[[:space:]]|<last_task_used_math>'; then
		echo "ERREUR : instruction FPU ou last_task_used_math dans $fn"
		exit 1
	fi
	echo "   $fn : propre"
done
# Tout l'espace utilisateur (programmes, bibliothèques, modules)
n=0
mauvais=0
for f in $(find "$TARGET_DIR" -type f); do
	[ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || continue
	n=$((n + 1))
	if "${X}objdump" -d "$f" 2>/dev/null | grep -qE '[[:space:]](sdiv|sdivcc|casa)[[:space:]]'; then
		echo "ERREUR : instruction interdite dans ${f#$TARGET_DIR}"
		mauvais=1
	fi
done
# binaires de l'initramfs minimal (paquet readynas-initramfs)
if grep -q 'padre-initramfs.list' "$BUILD_DIR"/linux-*/.config 2>/dev/null; then
	for f in busybox fenetres charge flottant; do
		if "${X}objdump" -d "$B/readynas-initramfs/$f" | grep -qE '[[:space:]](sdiv|sdivcc|casa)[[:space:]]'; then
			echo "ERREUR : instruction interdite dans readynas-initramfs/$f"
			mauvais=1
		fi
		n=$((n + 1))
	done
fi
[ "$mauvais" = 0 ] || exit 1
echo "   rootfs : $n fichiers ELF, aucune"

# Copie chiffrée pour « tftp <MAC> <IPnas> <IPpc> vmlinux.k3 0x80004000 »
# (iboot déchiffre en -k3 tout fichier reçu par TFTP)
OUTIL="$ICI/readynas_crypto"
if [ -f "$OUTIL/readynas_crypto.c" ]; then
	gcc -O2 -o "$BUILD_DIR/readynas_crypto" "$OUTIL/readynas_crypto.c" "$OUTIL/des.c"
	"$BUILD_DIR/readynas_crypto" -e -k3 < "$B/vmlinux.bin" > "$B/vmlinux.k3"
	"$BUILD_DIR/readynas_crypto" -d -k3 < "$B/vmlinux.k3" | cmp -n "$taille" - "$B/vmlinux.bin"
	echo "-- $B/vmlinux.k3 (chiffré -k3, vérifié par déchiffrement)"

	# ligne de commande intégrée : COMMAND_LINE_SIZE = 256 sur sparc32
	lg=$(strings "$B/vmlinux.bin" | grep -m1 -o 'console=ttyS1,9600.*' | wc -c)
	[ "$lg" -lt 256 ] || { echo "ERREUR : ligne de commande intégrée trop longue ($lg >= 256)"; exit 1; }
	echo "   ligne de commande intégrée : $lg caractères"
	rm -f "$B"/vmlinux-*.bin "$B"/vmlinux-*.k3	# anciennes variantes de mise au point
fi
