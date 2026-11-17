# Kbuild, run by build/guest.sh in the QEMU guest:
#   make -C <prepared linux-2.6.17.8 tree> ARCH=padre CROSS_COMPILE= M=$(PWD) modules
obj-m := padre_relay.o
padre_relay-objs := relay.o trampoline.o
