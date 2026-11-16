This program implements the crypto used for ReadyNAS firmware files & encrypted updates/addons.

There is just two different combinations ever used in the ReadyNAS

  -k 1 (default)

	Normal encryption as done by hwencrypt & hwcp.
	Used for:
		firmware header
		firmware vmlinux.bin
		firmware root.tgz
		updates & addons
  -k 3

	Other encryption & scrambling. Not available in any software shipped on the ReadyNAS
	Used for:
		firmware initrd.img
		tftp files

