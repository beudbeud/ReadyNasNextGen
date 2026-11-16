#!/usr/bin/env python3
"""Interrupts iboot on the serial console, then types commands one by one.

Usage: iboot-cmd.py LOG "command1" "command2" ...
  e.g.: iboot-cmd.py boot.log "tftp $NAS_MAC $NAS_IP $PC_IP vmlinux.k3 0x80004000" "go 0x80004000"

Environment variables:
  NAS_SERIAL serial port (default /dev/ttyUSB0), 9600 baud
  NAS_SSH    optional, e.g. root@<nas-ip>: reboots the NAS over SSH instead
             of waiting for it to be powered on by hand

After each command, waits for the prompt to come back (for "go": captures
until "login:", "rescue shell" or "Kernel panic", 15 min at most).
Nothing is written to flash: never send a NAND write command.
"""
import os, serial, subprocess, sys, time

log = open(sys.argv[1], "wb"); cmds = sys.argv[2:]
p = serial.Serial(os.environ.get("NAS_SERIAL", "/dev/ttyUSB0"), 9600, timeout=0.05); seen = b""


def read(d):
    global seen
    end = time.time() + d
    while time.time() < end:
        b = p.read(512)
        if b: seen += b; log.write(b); log.flush()


def note(t): print(time.strftime("%H:%M:%S"), t, flush=True)


def type_text(t):
    for c in t.encode(): p.write(bytes([c])); read(0.15)


p.reset_input_buffer()
if os.environ.get("NAS_SSH"):
    subprocess.Popen(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", os.environ["NAS_SSH"],
                      "sync; reboot"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    note("reboot requested")
else:
    note("power on the NAS")
end = time.time() + 300
while b"Reason:" not in seen and time.time() < end: read(0.2)
if b"Reason:" not in seen: sys.exit("no Reason:")
for _ in range(12):
    if b"iboot> " in seen or b"zlist" in seen: break
    p.write(b"i"); read(0.2)
read(2)
if b"iboot> " not in seen: sys.exit("prompt not reached (normal boot in progress)")
note("prompt reached; flushing the line")
type_text("\r"); read(1.5)
for c in cmds:
    start = len(seen); type_text(c + "\r")
    note("sent: " + c)
    if c.startswith("go") or c == "auto":
        end = time.time() + 900
        while time.time() < end and not any(m in seen[start:] for m in (b"login:", b"rescue shell", b"Kernel panic")):
            read(1)
        note("end: %d bytes after go" % (len(seen) - start)); break
    end = time.time() + 900
    while time.time() < end and not seen[start:].rstrip().endswith(b"iboot>"): read(0.5)
    note("prompt back" if seen[start:].rstrip().endswith(b"iboot>") else "no prompt after " + c)
