# QEMU 7.2 (Debian 12): with QEMU 10 the esp driver of the guest kernel (2.6.18)
# takes the SCSI disks offline after a bus reset.
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends qemu-system-sparc expect && rm -rf /var/lib/apt/lists/*
