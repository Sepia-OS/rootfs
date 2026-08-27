# SepiaOS - rootfs

This repository provides the build of root file system of SepiaOS. The following
steps are performed to build the rootfs.

## Build steps

### Retrieve boot partition

The boot partition is available from this repository: https://github.com/Sepia-OS/boot

If the rootfs is build as pre-release, that latest pre-release version shall be
used. In case of a release build, the latest release version of the boot
partition shall be used.

### Retrieve cross-compiler for the Raspberry Pi plattform aarch64

If the build is running on macOS, the macOS version of the toolset shall be
retrieved; on Linux the Linux version of the toolset shall be retrieved.

### Retrieve and build the musl libc

The latest release of the musl libc shall be downloaded and build as static as
well dynamic library.

### Retrieve and build busybox

The lates release of busybox shall be retrieved and compiled as a dynamic
executable based on the musl libc built in the last step.

### Creating the rootfs

The rootfs shall be created based on the Linux File Hierarchy Standard and
populated with muls libc and busybox built in the last two step.

### Creating a bootable image

The bootable image is created using the boot partition, musl libc and
busybox. It boots to a login screen. As soon as a user logs in, a shell
for the user is started.

The user `root` is created with the password `sepiaos` by default. When the `root` user logs in for the first time, the user must change the
password.

On the first boot, the rootfs shall be enlarged such that the entire space
of the data storage (SD Card, USB Stick, SSD) is used. AFter the resize,
the system shall be rebooted.
