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

## Console keyboard layouts

The image ships a set of console keymaps and a command to choose between them.

### Building the keymaps

`tools/generate_keymaps.py` is run by the build (`make keymaps`, which `make
rootfs` depends on) and writes one binary keymap per layout into
`build/keymaps`. They are installed into the root filesystem under
`/usr/share/keymaps`. Generating them needs `python3` on the build host; it is
the only part of the build that needs an interpreter.

The layouts are `english_us`, `uk`, `de`, `fr`, `es`, `it`, `ch`, `nordic`,
`dvorak` and `colemak`.

The generator does not describe a keyboard from nothing. It carries the
keymap the kernel starts with and changes only the keys a layout actually
moves, so everything else - Ctrl, both Shift keys, Alt, CapsLock, the function
keys and the cursor keys - keeps the value the kernel booted with. A keymap
table is loaded in full by `loadkmap`, so a layout built from nothing would set
every key it had forgotten to NUL, and the result would be a keyboard that can
type but cannot be typed on.

### Choosing a layout

`sepia-keymap` is installed in `/usr/bin`:

```sh
sepia-keymap list                 # the layouts that are installed
sepia-keymap show                 # which one is configured, and where from
sepia-keymap set de               # use it now, and on every login
sepia-keymap set-system de        # use it now, and for everyone on every boot
```

`set` records the choice in `~/.keymap` and `/etc/profile` applies it at login.
`set-system` records it in `/etc/keymap` and `/etc/init.d/rcS` applies it at
boot, before the login prompt appears. A user's own setting wins over the
system one.

Two things follow from how the kernel works, rather than from any choice made
here:

- A keymap belongs to the virtual terminals, not to a user. `set` means "load
  it now and again at every login for this user"; while that user is logged in
  it is simply the keymap, for whoever is at the keyboard.
- **A serial console has no keymap.** The layout is applied by the kernel to
  keys arriving from a real keyboard; over a serial line the terminal at the
  far end has already decided what the bytes mean. On a board with no screen
  attached these commands report that they cannot find a console rather than
  appearing to succeed.

The euro sign is not available on the layouts that place it on AltGr. A keymap
entry is 16 bits with the key type in the high byte, so only characters below
U+0100 fit; the build prints a note for each key it has to leave unmapped for
that reason.

## Console messages

The console is quietened once booting is finished: `/etc/init.d/rcS` ends with
`dmesg -n 3`, so the whole boot is printed as it happens and nothing printed
afterwards lands on top of the login prompt or on what is being typed at it.
`dmesg` still holds everything, and emerg, alert and crit still reach the
console, so a panic is still seen.

Under QEMU this hides two messages that look like faults and are not. `mmc1:
Timeout waiting for hardware interrupt` is the SDIO controller giving up on the
Pi 3's on-board wifi chip, which the emulator does not provide; `leds-gpio:
Failed to get GPIO '/leds/led-act'` is the ACT LED never getting its GPIO,
because that comes from the VideoCore firmware, which QEMU does not run.
Neither happens on real hardware, where both are actually present.

## Github workflows

Two Github workflows shall be created that are described in the following sections.

### Automatic build on commits on any branch

Whenever a commit and push is done on any branch, a full
build of the image shall be done including smoke tests
with Qemu (Pi Zero 2W, Pi 3, Pi 4, CM4).

### Manual release build

A manual release build shall be done that builds the
image. The user who triggers the release build must enter
a version number for the release. The main branch shall be
branched into a release branch (e.g. rel-<version>).
The build always only runs on the created release branch.
When the build succeeded the a release shall be created
(either pre-release or release) with the sources and the
image that can be downloaded and written to an SD card by
the user who downlaoded it.
