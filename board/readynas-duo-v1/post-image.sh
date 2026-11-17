#!/bin/sh
# post-image.sh (Buildroot, BR2_ROOTFS_POST_IMAGE_SCRIPT) for the 6.18 kernel
# of the ReadyNAS Duo v1: raw vmlinux.bin for iboot, static checks,
# -k3 encrypted copy for the iboot tftp command.
# Writes only to $BINARIES_DIR and $BUILD_DIR (no access to the NAS nor to the flash).
set -eu

B="$BINARIES_DIR"
HERE="$(cd "$(dirname "$0")" && pwd)"
X="$HOST_DIR/bin/sparc-buildroot-linux-uclibc-"
[ -x "${X}objcopy" ] || X="$HOST_DIR/bin/sparc-linux-"

"${X}objcopy" -O binary "$B/vmlinux" "$B/vmlinux.bin"

echo "== checks of $B/vmlinux"
echo "-- entry point and load address (expected 0x80004000)"
entry=$("${X}readelf" -h "$B/vmlinux" | sed -n 's/.*Entry point address: *//p')
start=$("${X}nm" "$B/vmlinux" | sed -n 's/^\([0-9a-f]*\) [Tt] _start$/0x\1/p')
end=$("${X}nm" "$B/vmlinux" | sed -n 's/^\([0-9a-f]*\) [A-Za-z] _end$/0x\1/p')
echo "   entry $entry, _start $start, _end $end"
[ "$start" = "0x80004000" ] || { echo "ERROR: _start is not at 0x80004000"; exit 1; }
# Without a separate initrd (built-in initramfs), the kernel may go past
# 0x8100_0000; it must stay below the iboot buffers (0x860f_f000).
if [ $((end)) -gt $((0x860f0000)) ]; then
	echo "ERROR: _end ($end) reaches the iboot buffers (0x860f_f000)"
	exit 1
elif [ $((end)) -gt $((0x81000000)) ]; then
	echo "   NB: _end > 0x81000000: do not load an iboot initrd with this kernel"
fi
size=$(stat -c %s "$B/vmlinux.bin")
echo "   vmlinux.bin: $size bytes (max $((0x81000000 - 0x80004000)))"

echo "-- forbidden instructions (sdiv/sdivcc: wrong on Padre; casa: missing)"
"${X}objdump" -d --no-show-raw-insn "$B/vmlinux" > "$BUILD_DIR/vmlinux.dis"
if grep -E '[[:space:]](sdiv|sdivcc|casa)[[:space:]]' "$BUILD_DIR/vmlinux.dis"; then
	echo "ERROR: forbidden instruction in vmlinux"
	exit 1
fi
echo "   none"

# FPU emulation path (the Padre has no FPU): no floating-point instruction
# executed by the kernel, and no last_task_used_math (never set on Padre:
# NULL, cause of the hang at the 1st arithmetic FPop).
echo "-- FPU emulation path (no FPU instruction, no last_task_used_math)"
for fn in fpd_trap_handler do_fpd_trap do_mathemu do_one_mathemu \
	  padre_ldst_mathemu padre_fbranch_mathemu record_exception \
	  safe_compute_effective_address safe_fetch_reg maybe_flush_windows; do
	body=$(awk -v f="<$fn>:" '$2 == f { p = 1; next } p && /^$/ { exit } p' "$BUILD_DIR/vmlinux.dis")
	if [ -z "$body" ]; then
		case $fn in
		fpd_trap_handler|do_fpd_trap|do_mathemu)
			echo "ERROR: $fn missing from vmlinux"; exit 1 ;;
		*)	continue ;;	# static function inlined into its caller
		esac
	fi
	if printf '%s\n' "$body" | grep -E '%f[0-9]|%fsr|%fq|[[:space:]]fb[a-z,]*[[:space:]]|[[:space:]]f(add|sub|mul|div|sqrt|mov|neg|abs|cmp|ito|sto|dto|qto|smul|dmul)[a-z]*[[:space:]]|<last_task_used_math>'; then
		echo "ERROR: FPU instruction or last_task_used_math in $fn"
		exit 1
	fi
	echo "   $fn: clean"
done
# The whole userspace (programs, libraries, modules)
PT_LOAD_16K='function h(x,  i, v) { v = 0; x = tolower(substr(x, 3));
	for (i = 1; i <= length(x); i++) v = v * 16 + index("0123456789abcdef", substr(x, i, 1)) - 1
	return v }
$1 == "LOAD" { if ((h($2) - h($3)) % 16384 || h($NF) < 16384) bad = 1 } END { exit bad }'
n=0
bad=0
for f in $(find "$TARGET_DIR" -type f); do
	[ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || continue
	n=$((n + 1))
	if "${X}objdump" -d "$f" 2>/dev/null | grep -qE '[[:space:]](sdiv|sdivcc|casa)[[:space:]]'; then
		echo "ERROR: forbidden instruction in ${f#$TARGET_DIR}"
		bad=1
	fi
	# 16 KiB kernel pages: every PT_LOAD congruent modulo 0x4000, aligned >= 0x4000
	if ! "${X}readelf" -lW "$f" 2>/dev/null | awk "$PT_LOAD_16K"; then
		echo "ERROR: PT_LOAD not aligned on 16 KiB in ${f#$TARGET_DIR}"
		bad=1
	fi
done
# binaries of the minimal initramfs (readynas-initramfs package)
if grep -q 'padre-initramfs.list' "$BUILD_DIR"/linux-*/.config 2>/dev/null; then
	for f in busybox windows load float; do
		if "${X}objdump" -d "$B/readynas-initramfs/$f" | grep -qE '[[:space:]](sdiv|sdivcc|casa)[[:space:]]'; then
			echo "ERROR: forbidden instruction in readynas-initramfs/$f"
			bad=1
		fi
		n=$((n + 1))
	done
fi
[ "$bad" = 0 ] || exit 1
echo "   rootfs: $n ELF files, none; PT_LOAD aligned on 16 KiB"

# Encrypted copy for "tftp <MAC> <NAS-IP> <PC-IP> vmlinux.k3 0x80004000"
# (iboot decrypts with -k3 any file received by TFTP)
TOOL="$HERE/readynas_crypto"
if [ -f "$TOOL/readynas_crypto.c" ]; then
	gcc -O2 -o "$BUILD_DIR/readynas_crypto" "$TOOL/readynas_crypto.c" "$TOOL/des.c"
	"$BUILD_DIR/readynas_crypto" -e -k3 < "$B/vmlinux.bin" > "$B/vmlinux.k3"
	"$BUILD_DIR/readynas_crypto" -d -k3 < "$B/vmlinux.k3" | cmp -n "$size" - "$B/vmlinux.bin"
	echo "-- $B/vmlinux.k3 (encrypted -k3, checked by decryption)"

	# built-in command line: COMMAND_LINE_SIZE = 256 on sparc32
	lg=$(strings "$B/vmlinux.bin" | grep -m1 -o 'console=ttyS1,9600.*' | wc -c)
	[ "$lg" -lt 256 ] || { echo "ERROR: built-in command line too long ($lg >= 256)"; exit 1; }
	echo "   built-in command line: $lg characters"
	rm -f "$B"/vmlinux-*.bin "$B"/vmlinux-*.k3	# old debugging variants
fi
