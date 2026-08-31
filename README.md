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

On the first boot the user shall first be asked two questions, and the answers
shall be saved for the system:

- what the network should be - 1) Ethernet (DHCP), 2) Wifi (DHCP), 3) Both,
  4) None. Choosing wifi also asks for the network name, the passphrase and a
  country code.
- which console keymap to use, chosen by number from a list of every keymap
  installed on the image.

The questions are asked on the screen, since answering them needs a keyboard: a
board booting to a serial console keeps the defaults (ethernet on DHCP, and
whichever keymap is configured), and `sepia-network` and `sepia-keymap` change
either of them at any time afterwards. An unanswered question leaves the
defaults in place rather than holding the boot up.

Then, still on the first boot,
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

The launchscript shall take the built bootable image and launch Qemu with
that image as a Pi Zero 2 W, a Pi 3 or a Pi 4 - a Pi 4 unless told otherwise -
and shall give each board the most memory Qemu allows it. Any debug outputs of
Qemu shall go to the console of the host. The guest in Qemu shall open a screen
such that the booted OS can be used (login, start cli tools etc.).

```sh
tools/qemu.sh              # boot the newest image as a Pi 4, with 2 GiB
tools/qemu.sh -b pi3       # as a Pi 3, with 1 GiB
tools/qemu.sh -b pi-zero2w # as a Zero 2 W, which Qemu emulates as a 3B
tools/qemu.sh -n           # with no network device at all
```

The guest is given a network unless `-n` says otherwise. It is a USB device,
because Qemu emulates no Pi's own ethernet on any board, and the guest sees it
as `usb0`: it leases 10.0.2.15 from Qemu's own server, reaches the host at
10.0.2.2 and resolves names through 10.0.2.3. Outbound only - nothing reaches
in without a `-hostfwd`, which the launcher does not set up.

Memory is not a setting. Qemu pins each of its `raspi` machines to the RAM of
the board revision it emulates and refuses any other `-m`, so a Pi 3 or a Zero
2 W gets 1 GiB and a Pi 4 gets 2 GiB - there is no 8 GiB Pi 4 to be had, and
the Zero 2 W gets twice what the real board has.

Being typed at as a Pi 4 needs `dtc` on the host. A real Pi 4 has its USB ports
behind PCIe, which Qemu does not emulate, so `bcm2711-rpi-4-b.dtb` disables the
on-SoC USB controller and the emulated keyboard never appears; the launcher
turns that one property back on in its extracted copy of the device tree. Where
`dtc` is missing it says so - a Pi 4 then boots and can be watched, but not
used, and `-b pi3` needs nothing.

## Console keyboard layouts

The image ships a set of console keymaps and a command to choose between them.

### Building the keymaps

`tools/generate_keymaps.py` is run by the build (`make keymaps`, which `make
rootfs` depends on) and writes one binary keymap per layout into
`build/keymaps`. They are installed into the root filesystem under
`/usr/share/keymaps`. Generating them needs `python3` on the build host; it is
the only part of the build that needs an interpreter.

The layouts are `english_us`, `uk`, `de`, `de_mac_nodeadkeys`, `fr`, `es`,
`it`, `ch`, `nordic`, `dvorak` and `colemak`.

`de_mac_nodeadkeys` is the German layout as an Apple keyboard has it - xkb's
`de(mac_nodeadkeys)`. The letters and the digit row are the same as `de`; what
differs is the third level, because on a Mac it is the Option key and Apple put
the punctuation somewhere else: `@` is Option-L, the brackets are
Option-5/6/8/9, the pipe is Option-7 and the backslash is Shift-Option-7.
"No dead keys" means `^` and `´` type their character instead of waiting for
the letter it belongs to, which on a console is true of every layout here - a
console keymap has no dead keys to wait with.

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

## Networking

Networking shall be configurable, either ethernet or wifi or both.

Both are described in `/etc/network.conf` and applied by
`/usr/sbin/sepia-network`, which `/etc/init.d/rcS` runs at boot. The two
interfaces are independent: each is off, on DHCP, or on a static address, so
"ethernet or wifi or both" is just the combinations that fall out of that. Out
of the box it is ethernet on DHCP and wifi off.

```sh
sepia-network status                  # what is configured, and what is up
sepia-network ethernet dhcp
sepia-network ethernet static 192.168.1.50/24 192.168.1.1 1.1.1.1
sepia-network ethernet off
sepia-network wifi 'my network' 'the passphrase' DE
sepia-network wifi off
sepia-network up                      # or down, or restart; ethernet, wifi or both
```

Each command writes the choice to `/etc/network.conf` and applies it straight
away. The file is mode 0600, because the wifi passphrase is in it, and it can
equally be edited by hand.

Nothing about this holds up the boot. A DHCP server that does not answer costs
a few seconds and is then waited for in the background; an interface that has
not appeared yet is waited for for ten seconds, because on a Pi 3 the ethernet
is a USB device that is still enumerating when `rcS` gets here.

### Ethernet

Nothing has to be built for it. Every Pi's own adapter is in the kernel already
— `genet` on a Pi 4, Pi 5 and CM4, `smsc95xx` on a Pi 3, `lan78xx` on a 3B+ —
and busybox brings `udhcpc`, `ip`, `ping` and `nslookup`. A USB adapter works
too: nothing in this system autoloads modules, so `sepia-network` asks each
device on the USB and SDIO buses which module it wants and loads that, the way
udev would.

### Wifi

Wifi needs three things ethernet does not, all built by `make wireless` and
installed into the image:

- the Broadcom firmware and its per-board NVRAM, from the same package
  Raspberry Pi OS installs. Every chip Raspberry Pi has shipped is covered:
  43430, 43436, 43455 and 43456, which between them are every supported board.
- `libnl`, because `wpa_supplicant` speaks to the kernel over nl80211 and that
  is a netlink protocol.
- `wpa_supplicant`, built against its own internal TLS and libtommath so that
  nothing here needs OpenSSL. That covers WPA and WPA2 with a passphrase.

Image builds carry wifi by default (`WITH_WIFI=1`). `WITH_WIFI=0` is an
option, not a default, and leaves all three out - worth having for more than
the build time it saves, since the firmware is redistributable but not free and
an image that carries none of it is a reasonable thing to want.

The country code is passed to the supplicant as `country=`. Without one the
radio is held to the channels that are legal everywhere.

```sh
make wireless          # firmware, libnl and wpa_supplicant
make wireless-info     # versions, size, and which chips the firmware covers
make WITH_WIFI=0 image # optional: an image with no wifi in it at all
```

### What the tests cover

`make net-check` boots the image with a network attached and reads the serial
log back: a driver gets loaded for a device nothing autoloads for, the
interface is found without its name being assumed, and DHCP puts an address and
a default route on it. Logging in and using it - `nslookup` through the leased
resolver, `ping` out - was checked by driving the framebuffer console.

Wifi cannot be tested that way, and it is worth being plain about it: QEMU
emulates no wifi hardware of any kind, so there is nothing for the firmware to
load onto and nothing to associate with. What has been checked is that
`wpa_supplicant` runs on the target and finds its libraries, that the firmware
is in the image, and that the wireless path in `sepia-network` drives a
`mac80211_hwsim` radio. Whether a real Pi joins a real network is a question
only a real Pi can answer.

## Security

### What is defended, and what is not

The threat model is a device reached over the network, not one an attacker can
pick up. Two things follow, and both are deliberate:

- **Nothing listens.** There is no sshd, telnetd or any other network service;
  the only sockets opened outward are `udhcpc` and `wpa_supplicant`. There is no
  remote login to attack, so the network attack surface is close to nil.
- **Physical access is out of scope, and that is not a small caveat.** The card
  is an ordinary MBR disk: a FAT boot partition and an unencrypted ext4 root.
  Anyone holding it can add `init=/bin/sh` to `cmdline.txt` and boot straight to
  a root shell with no password, or simply read and rewrite the root filesystem
  on another machine - replace `/etc/shadow`, drop a binary, take the Wi-Fi PMK.
  No password or file permission defends against this, because the attacker is
  not going through the OS at all.

  The only real defence is cryptography the firmware enforces before Linux
  starts: an encrypted root (LUKS, unlocked from an initramfs) so the data is
  unreadable off the device, and/or verified boot so a tampered `cmdline.txt` or
  kernel is refused. Both are sizeable features and are not built yet. Until
  they are, treat a SepiaOS card the way you would treat a house key: whoever
  holds it, owns it.

### The root password

The image ships with a **public** default (`root` / `sepiaos`, documented
above). It is meant to survive exactly one login:

- First boot offers to set a real password as part of setup, before any login
  prompt appears - so the public default is normally replaced during
  provisioning, not left waiting on the wire.
- If that step is skipped (or the board is headless with no console to ask on),
  `/etc/profile` refuses to hand out a shell until `passwd` has actually
  changed it. The marker at `/etc/sepiaos-password-unchanged` is what tracks
  this; a successful change removes it.

Passwords are hashed with **sha512-crypt**. busybox defaults to DES otherwise -
which keeps only the first eight characters and carries a 12-bit salt - so the
build sets `CONFIG_FEATURE_DEFAULT_PASSWD_ALGO="sha512"` and asserts it, and a
password set at first boot is hashed the same way. Regenerate the shipped
default with `openssl passwd -6` (Homebrew's or any Linux openssl; macOS
LibreSSL has no `-6`).

### The Wi-Fi secret

A device that reconnects on its own has to keep *something* that joins the
network, and anything that joins the network is as good as the passphrase for
that purpose. What it need not keep is the human passphrase itself, which people
reuse. So `sepia-network` stores the **PMK** - the passphrase already hashed
against the SSID by `wpa_passphrase` - in `/etc/network.conf` (mode `0600`,
root only), never the passphrase. A stolen card still joins that one network;
it no longer hands over a password worth trying elsewhere. An open network, or a
passphrase too short for `wpa_passphrase` to accept, is the exception - then
what was typed is what is stored.
