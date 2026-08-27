# SepiaOS - rootfs

This repository provides the build of root file system of SepiaOS. The following
steps are performed to build the rootfs.

## Build steps

### Retrieve boot partition

The boot partition is available from this repository:
https://github.com/Sepia-OS/boot

If the rootfs is build as pre-release, that latest pre-release version shall be
used. In case of a release build, the latest release version of the boot
partition shall be used.

### Retrieve cross-compiler for the Raspberry Pi plattform aarch64

If the build is running on macOS, the macOS version of the toolset shall be
retrieved; on Linux the Linux version of the toolset shall be retrieved.

### Retrieve and build the musl libc

The latest release of the musl libc shall be downloaded and build as static as
well as dynamic library.

### Retrieve and build busybox

The latest release of busybox shall be retrieved and compiled as a dynamic
executable based on the musl libc built in the last step.

### Retrieve and install the kernel modules

The kernel modules belonging to the kernel of the boot partition shall be
retrieved and installed into the root file system under `/lib/modules`.

The modules are published in the `raspberrypi/firmware` repository, in the
`modules` directory. They shall be taken from the same release tag that the
boot partition was built from, because modules of a different kernel version
will not load. The boot release names that tag in its release notes.

Two module trees are needed, because the boot partition carries two kernels:
`<version>-v8+` for `kernel8.img`, which serves Pi Zero 2 W, Pi 3, Pi 4 and
CM4, and `<version>-v8-16k+` for `kernel_2712.img`, which serves Pi 5 and
CM5.

### Create a bootable image

The rootfs shall be created based on the Linux File Hierarchy Standard and
populated with musl libc, busybox and the kernel modules from the previous
steps. The rootfs shall be created with `ext4` file system.

The bootable image is created using the boot partition, musl libc and
busybox. It boots to a login screen. As soon as a user logs in, a shell
for the user is started.

The user `root` is created with the password `sepiaos` by default. When the
`root` user logs in for the first time, the user must change the password.

On the first boot,
- the rootfs shall be enlarged such that the entire space of the data storage
  (SD Card, USB Stick, SSD) is used, minus the size of the swap partition (see
  next step)
- a swap partition shall be created, depending on the size of the storage
  device:
  - size < 64GB: 1GB swap partition.
  - 64GB < size < 128GB: 2GB swap partition
  - size > 128GB: 4GB swap partition
- active the swap partition
- the system shall be rebooted.

### Test the image

The image shall be tested by booting it in Qemu on a Pi3.

### Create Qemu launch script

The launchscript shall take the built bootable image and launch Qemu (Pi3)
with that image. Any debug outputs of Qemu shall go to the console of the
host. The guest in Qemu shall open a screen such that the booted OS can be
used (login, start cli tools etc.).
