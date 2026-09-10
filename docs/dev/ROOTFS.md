# What the rootfs build owns

An inventory of the device-level subsystems this repository **authors**, as
opposed to the ones it merely fetches and unpacks.

Ten payloads arrive here from sibling repositories or upstream archives - musl,
busybox, LLVM, the Rust toolchain, GNU make, e2fsprogs, grit, helix, the wifi
userspace, and the kernel with its modules. Set all of those aside and what is
left is the part of the operating system that exists only here: twenty-five
subsystems, most of them living in the eighteen hand-written files under
[`overlay/`](../../overlay) and in [`Makefile`](../../Makefile).

The distinction this document draws is between a *payload* and the
*configuration and integration work around it*. wpa_supplicant is a payload and
is out of scope; the generated supplicant config, the curated Broadcom firmware
set and the PMK-at-rest policy are this repo's and are in scope. Where an
artefact wraps an external payload, it says so.

**Scope note.** This is an inventory, not a specification. It was compiled by
reading the tree on 2026-09-09 and it will drift; where it disagrees with the
Makefile or with `overlay/`, they are right.

---

## Contents

| # | Artefact | Group | Primary file |
|---|---|---|---|
| 1 | [Console keymaps](#1-console-keymaps) | Settings | `overlay/usr/bin/sepia-keymap` |
| 2 | [Timezone](#2-timezone) | Settings | `Makefile` · tzdata |
| 3 | [The clock, on a board with no RTC](#3-the-clock-on-a-board-with-no-rtc) | Settings | `overlay/usr/sbin/sepia-time` |
| 4 | [The init system and the shutdown mirror](#4-the-init-system-and-the-shutdown-mirror) | Boot | `overlay/sbin/init` |
| 5 | [Login prompts and virtual terminals](#5-login-prompts-and-virtual-terminals) | Boot | `overlay/usr/sbin/sepia-gettys` |
| 6 | [Volatile filesystems and `/dev`](#6-volatile-filesystems-and-dev) | Boot | `overlay/etc/init.d/rcS` |
| 7 | [Console noise policy](#7-console-noise-policy) † | Boot | three files |
| 8 | [Users, groups and the login shell](#8-users-groups-and-the-login-shell) | Identity | `overlay/etc/passwd` |
| 9 | [Forced root password change](#9-forced-root-password-change) | Identity | `overlay/etc/profile` |
| 10 | [sha512 password hashing, end to end](#10-sha512-password-hashing-end-to-end) ‡ | Identity | busybox `.config` |
| 11 | [Hostname and local name resolution](#11-hostname-and-local-name-resolution) | Identity | `overlay/etc/hostname` |
| 12 | [OS identity and the build bill of materials](#12-os-identity-and-the-build-bill-of-materials) | Identity | `define generate_etc` |
| 13 | [The four questions](#13-the-four-questions) | First boot | `overlay/usr/sbin/sepia-firstboot` |
| 14 | [Growing the root filesystem onto the card](#14-growing-the-root-filesystem-onto-the-card) | First boot | `overlay/usr/sbin/sepia-firstboot` |
| 15 | [Swap](#15-swap) | First boot | `overlay/usr/sbin/sepia-firstboot` |
| 16 | [Where the system keeps state about itself](#16-where-the-system-keeps-state-about-itself) ‡ | First boot | `/var/lib/sepia` |
| 17 | [Interfaces, addressing and DNS](#17-interfaces-addressing-and-dns) | Networking | `overlay/usr/sbin/sepia-network` |
| 18 | [Wi-Fi: association, credentials and firmware](#18-wi-fi-association-credentials-and-firmware) | Networking | `Makefile` |
| 19 | [Driver autoloading, with no udev and no mdev](#19-driver-autoloading-with-no-udev-and-no-mdev) † | Networking | `overlay/usr/sbin/sepia-network` |
| 20 | [Skeleton, permissions and fstab](#20-skeleton-permissions-and-fstab) | Tree and card | `Makefile` |
| 21 | [The card image](#21-the-card-image) | Tree and card | `Makefile` |
| 22 | [How big a card the image assumes](#22-how-big-a-card-the-image-assumes) ‡ | Tree and card | `IMAGE_SIZE_MIB` |
| 23 | [Userland composition: who owns which binary](#23-userland-composition-who-owns-which-binary) | Tree and card | `define install_*` |
| 24 | [Completing the on-device C/C++ toolchain](#24-completing-the-on-device-cc-toolchain) | Toolchain | `define install_toolchain` |
| 25 | [The on-card licence shelf](#25-the-on-card-licence-shelf) ‡ | Toolchain | `assert_rootfs` |

‡ surfaced only by a completeness pass over the tree, and not obviously named
anywhere else.
† real, but arguably part of a neighbouring artefact rather than one of its own.

---

## The boot, in order

Almost every artefact below is reachable from one file.
[`overlay/etc/init.d/rcS`](../../overlay/etc/init.d/rcS) runs once, from
`::sysinit`, with no `set -e` - a single failed mount must not leave the system
with no getty and no way in, so each step reports for itself.

The order is the argument. The clock needs the network. The keymap has to
precede the login prompt, so the first thing typed is already in the configured
layout. The login prompt comes last, so it appears only once the system is up.

| Line | Step | |
|---|---|---|
| 7-8 | `mount proc, sysfs` | `nosuid,nodev,noexec` |
| 14 | `mount -o remount,rw /` | the kernel mounts it read-only; everything below writes something |
| 19-26 | devtmpfs, devpts, `/dev/shm`, `/run`, `/tmp`, `/run/lock` | |
| 28 | `hostname -F /etc/hostname` | before anything can announce a name |
| 32 | `sepia-firstboot` | reboots on pass 1, so nothing below runs then |
| 34 | `swapon -a` | |
| 39 | `sepia-network up` | also coldplugs drivers |
| 50 | `sepia-time up` | build-date floor, then ntpd in the background |
| 54 | `sepia-keymap apply` | |
| 57 | `sepia-gettys` | rewrites inittab, then `kill -HUP 1` |
| 70 | `dmesg -n 3` | quieten the console now that booting is over |

Shutdown is the mirror, in [`rcK`](../../overlay/etc/init.d/rcK): `swapoff -a`,
`sync`, `umount -a -r`, `sync`. The `-r` is the point - it remounts read-only
whatever cannot be unmounted, which always includes `/` itself, and without it
the next boot finds a dirty filesystem and replays the journal.

---

## Settings a person changes

### 1. Console keymaps

167 binary keymaps in the format busybox `loadkmap` reads, with a per-user
layout in `~/.keymap` layered over a system one in `/etc/keymap` - the system
one applied by rcS before the login prompt, the user's re-applied by
[`/etc/profile`](../../overlay/etc/profile) at every login.

Eleven curated layouts are generated by
[`tools/generate_keymaps.py`](../../tools/generate_keymaps.py) starting from a
base64 dump of the kernel's own boot keymap, changing only the keys a layout
actually moves. That is not a detail: a table written into a `.kmap` is loaded
in full, so a layout built from nothing would set every key it forgot to NUL and
leave a keyboard that types but cannot be typed on.

The other 156 come from kbd's own maps, vendored under
[`vendor/keymaps/`](../../vendor/keymaps) as the Tiny Core extension that
publishes them, so a build never needs the network for a keyboard layout. Every
vendored layout is prefixed with its family directory, because four basenames
appear in two families each and six more collide with the curated set - a flat
copy would silently overwrite ten layouts including the hand-corrected German
one. A collision is a hard error rather than an overwrite.

**Where:** `overlay/usr/bin/sepia-keymap` · `tools/generate_keymaps.py` ·
`vendor/keymaps/kmaps.tcz` · `KEYMAP_*` and `define unpack_vendor_keymaps` in
the Makefile.
**Wraps:** busybox `loadkmap`.

### 2. Timezone

A separate question from the time, and answered the musl way: setting a zone is
a symlink from `/etc/localtime` into `/usr/share/zoneinfo` and nothing else - no
profile edit and no `TZ` variable - which is what makes `date` in an
init-started script agree with `date` at a login prompt. `/etc/timezone` holds
the name in plain text beside it, because a symlink can be read but not asked
what it is called. The default is UTC.

**Where:** the timezone section of the Makefile · `checksums/tzdata-2026c-1.sha256`.
**Wraps:** Debian's `tzdata` .deb - the unpacking, trimming, digest recording
and both pickers are this repo's.

### 3. The clock, on a board with no RTC

A Pi has no battery-backed clock, so every boot starts at the epoch. sepia-time
answers that in two independent halves.

A **floor**: `/etc/sepia-build-date` holds seconds since the epoch, stamped at
build time, and is compared in the shell - because `date` is the thing that
cannot be trusted yet - with the clock jumped forward to the build date if it is
behind. This needs no network, and is what makes the first boot work.

Then **ntpd**, started in the background, waited for by nothing.

**Where:** `overlay/usr/sbin/sepia-time` · `NTP` and `NTP_SERVERS` in
[`overlay/etc/network.conf`](../../overlay/etc/network.conf).
**Wraps:** busybox `ntpd` and `date`; the daemon's argv, lifecycle and pidfile
are this repo's.

> The stated reason for the floor is that a card at the epoch cannot complete a
> TLS handshake, since every certificate is *not valid before* a date after
> 1970. That reasoning is sound, but the card ships no CA bundle either - see
> [What isn't there](#what-isnt-there).

---

## Boot and console

### 4. The init system and the shutdown mirror

PID 1 is a hand-written shell wrapper, and it exists because of two individually
obscure facts that together produce a system that boots perfectly and says
absolutely nothing.

The kernel opens `/dev/console` for PID 1 in `console_on_rootfs()`, which runs
before `prepare_namespace()` mounts the real root; without an initramfs there is
nothing to open then, so init is exec'd with descriptors 0, 1 and 2 closed. And
busybox init does not open a console of its own on Linux - it honours `CONSOLE`
and otherwise calls `bb_sanitize_stdio`, which points everything at `/dev/null`.

So [`overlay/sbin/init`](../../overlay/sbin/init) probes `/dev/console` in a
subshell, exports `CONSOLE` and execs busybox init. The probe is not caution for
its own sake: `/dev/console` can be present and still refuse to open, and a
failed redirection on `exec` is fatal to the shell - which in PID 1 is a panic.

[`overlay/etc/inittab`](../../overlay/etc/inittab) wires `::sysinit` to rcS,
`::ctrlaltdel` to reboot, `::shutdown` to rcK and `::restart` back to
`/sbin/init`, and carries no getty lines at all.

**Where:** `overlay/sbin/init` · `overlay/etc/inittab` ·
`overlay/etc/init.d/rcS` · `overlay/etc/init.d/rcK`. The Makefile unlinks
`sbin/init` before copying the overlay, because busybox's install leaves a
symlink there and `cp` would follow it into `bin/busybox`; `assert_rootfs` then
requires that `sbin/init` is *not* a symlink.
**Wraps:** busybox init, mount and hostname applets.

### 5. Login prompts and virtual terminals

No getty lines are shipped. Which tty the console lands on differs per board -
`tty1` with a monitor, `ttyAMA0` or `ttyS0` on the Pi 3/4 UARTs, `ttyAMA10` on
the Pi 5 debug connector - and again under QEMU, and a getty on the wrong one is
silence while a second getty on the *same* device fights the first for input.

So at every boot sepia-gettys reads `/proc/consoles`, works out which console
`/dev/console` resolves to from the `C` flag, and writes one getty line each
below the marker at the end of inittab:

- the flagged console gets its getty on the name `console` rather than its own
  node. Under QEMU the PL011 comes up as `ttyAMA1`, has no sysfs entry, and
  `/dev/ttyAMA1` fails with `ENXIO` - while `/dev/console` works.
- other registered consoles get a getty by name where sysfs confirms them, with
  `mknod` from the reported major:minor as a fallback.
- where a VT exists, `tty2` through `tty9` get one each, leaving `tty10` free
  for a graphical session later.

Each VT is sent `ESC c` to undo the kernel boot logo's shrunken scrolling
region. Everything below the marker is rewritten each boot, so the file
converges rather than growing, and init is re-read with `kill -HUP 1` only when
it actually changed.

**Where:** `overlay/usr/sbin/sepia-gettys`.
**Wraps:** busybox `getty`, `login`, and init's SIGHUP inittab reload.

### 6. Volatile filesystems and `/dev`

The real mount policy lives in rcS, not in fstab - nothing on the card ever runs
`mount -a`. Seven pseudo-filesystems with deliberate flags: proc and sysfs
`nosuid,nodev,noexec`; devpts at `gid=5,mode=620`, against the `tty` group in
[`/etc/group`](../../overlay/etc/group); tmpfs on `/dev/shm` and `/tmp` at 1777
and `/run` at 0755, all `nosuid,nodev`; and `mkdir -p /run/lock`.

devtmpfs is mounted only if the kernel did not do it already, which is what
keeps the image working on a kernel built without `CONFIG_DEVTMPFS_MOUNT`.

**Where:** `overlay/etc/init.d/rcS:7-26`.

### 7. Console noise policy †

A three-part policy for what a person actually sees:

- rcS ends with `dmesg -n 3`, so late kernel messages stop landing on top of the
  login prompt and on whatever is being typed at it. The ring buffer is
  untouched - `dmesg` still shows everything - and emerg, alert and crit still
  reach the console, so a panic is still seen.
- sepia-firstboot drops printk further while its questions are on screen, and
  restores the exact previous value afterwards.
- sepia-gettys sends `ESC c` to each VT.

Listed separately because it is a deliberate, documented policy; folded into its
three neighbours it would be invisible. Equally, it is three lines in three
files, which is the argument against.

---

## Identity and access

### 8. Users, groups and the login shell

Three accounts - root on `/bin/sh`, daemon and nobody on `/usr/sbin/nologin` -
and six groups, including the `tty(5)` that devpts is mounted against, plus
`disk(6)` and `wheel(10)`. `/etc/shells` lists `/bin/sh` and `/bin/ash`.

[`/etc/profile`](../../overlay/etc/profile) is the login-shell personality:
`PATH` over the four bin directories, `HOME`, `TERM=vt100`, `PAGER=more`,
`umask 022`, and a `PS1` that differs for root and non-root.

**Where:** `overlay/etc/passwd` · `overlay/etc/group` · `overlay/etc/shells` ·
`overlay/etc/profile`. `/etc/shadow` is generated at build time.

### 9. Forced root password change

The default root password is published in the README, so it is worth exactly one
login. There is no password ageing to lean on: busybox `login` does not read the
ageing fields of `/etc/shadow` at all, so the marker file
`/etc/sepiaos-password-unchanged` is what carries the requirement, and only a
`passwd` that actually succeeded removes it.

`/etc/profile` refuses to hand over a shell while the marker exists. The retry
loop is bounded at three, and it has to be: `passwd` fails immediately when
there is nothing on stdin, so an unbounded loop would spin at full speed for a
login shell started from a script. Giving up ends the login shell, which drops
back to the getty and its login prompt - still no shell without a new password.

**Where:** `overlay/etc/profile` · the marker, created by `define generate_etc`.

### 10. sha512 password hashing, end to end ‡

The policy that makes the previous artefact worth anything, and it spans build
and runtime. busybox would hash new passwords with DES - first eight characters,
12-bit salt - so the build forces
`CONFIG_FEATURE_DEFAULT_PASSWD_ALGO="sha512"` into busybox's `.config` and
re-greps for it after `oldconfig`, failing the build if it did not stick.
`assert_rootfs` then checks the shipped hash really is `$6$`.

Without that edit, every password set on the card afterwards - including the one
the forced change demands - would be stored as DES.

**Where:** the busybox configuration step in the Makefile ·
`ROOT_PASSWORD_HASH` · `define assert_rootfs`.

### 11. Hostname and local name resolution

The card calls itself `sepiaos`. `/etc/hostname` is applied by rcS with
`hostname -F` before anything that might announce a name, and `/etc/hosts` maps
`127.0.0.1` to both `localhost` and `sepiaos` plus the IPv6 loopback aliases -
which is also what makes the prompt's `\h` agree with a loopback lookup.

Entirely static: nothing in the build generates it per card.

**Where:** `overlay/etc/hostname` · `overlay/etc/hosts`.

### 12. OS identity and the build bill of materials

Every build stamps the card with what it is and what is on it. `/etc/os-release`
carries `NAME`, `ID`, `VERSION`, `VERSION_ID`, `PRETTY_NAME` and `HOME_URL`,
plus a `SEPIAOS_*` pair naming the release and version of every external
component that actually went in - the boot release and firmware tag, both kernel
versions, musl, and conditionally LLVM, GNU make, e2fsprogs, wifi, Rust, grit
and helix.

`/etc/issue` is the banner above every login prompt on every console, which is
what makes `SEPIAOS_VERSION_DISPLAY` a user-facing string rather than an
internal one - it is separate from `SEPIAOS_VERSION` because that one also names
the image file and fills `VERSION_ID`, neither of which may carry a space or a
bracket.

**Where:** `define generate_etc` in the Makefile.

---

## First boot

### 13. The four questions

On the very first boot, [`sepia-firstboot`](../../overlay/usr/sbin/sepia-firstboot)
asks four things and applies them through the repo's own tools: network
(ethernet DHCP / wifi / both / none, with SSID, a silent passphrase and country
code) through `sepia-network -n`; a real root password, hashed with
`mkpasswd -m sha512` and written into `/etc/shadow` atomically, because it
cannot drive `passwd` - that needs a controlling terminal first boot does not
have; the keyboard layout, paged, through `sepia-keymap set-system`; and the
timezone, region then city, through the localtime symlink.

Only a virtual terminal is asked. `/dev/console` may resolve to a UART, and a
UART may have a person at the far end of it or nothing at all - a read that
blocks on a headless board is a board that never finishes booting. Anything that
is not a VT keeps the defaults, which are the ones the image ships with anyway
and which the `sepia-*` tools can change at any time afterwards.

The first question is the one that finds out whether anybody is there: if it
goes unanswered the rest are not asked at all, which bounds a screen nobody is
watching to one wait rather than four.

**Where:** `overlay/usr/sbin/sepia-firstboot`, 546 lines.

### 14. Growing the root filesystem onto the card

The shipped image is sized to its contents, so on first boot it takes over the
whole device. This runs in two passes with a reboot between them, and that is a
constraint rather than a choice: the kernel will not re-read a partition table
while one of that disk's partitions is mounted, and `/` always is. Raspberry Pi
OS splits its own resize the same way for the same reason.

Pass 1 finds the boot device from `root=` on the kernel command line - resolving
`PARTUUID`, `UUID` or `LABEL` with `findfs` - derives the disk from it, rewrites
the partition table and reboots. The table is written byte by byte rather than
through fdisk: the layout wanted is exact and already known, and 16 bytes per
entry is less machinery than driving an interactive tool from a script. Pass 2
sees the larger partition and grows the filesystem onto it.

**Where:** `overlay/usr/sbin/sepia-firstboot` · `/var/lib/sepia/resize-pending`.
**Wraps:** e2fsprogs `resize2fs` and busybox `findfs`, `dd`, `reboot`.

### 15. Swap

Sized from the card: 1 GiB under 64 GB, 2 GiB under 128 GB, 4 GiB above -
thresholds in GB because that is how storage is sold, sizes in GiB because that
is how memory is measured. Aligned to a 4 MiB erase block at the end of the
device and written as a type-`0x82` MBR entry in pass 1; `mkswap`ed after the
reboot, appended to `/etc/fstab`, and brought up by `swapon -a` in rcS.

**Where:** `overlay/usr/sbin/sepia-firstboot` · `/etc/fstab` ·
`overlay/etc/init.d/rcS:34`.
**Wraps:** busybox `mkswap`, `swapon`, `swapoff`.

### 16. Where the system keeps state about itself ‡

A convention every `sepia-*` tool obeys, created by the build and not named
anywhere as a thing. Persistent state lives in `/var/lib/sepia`, pre-created in
the tree skeleton, and consists of exactly three markers: `firstboot-done`,
`resize-pending` and `setup-done`. They are the only cross-boot state the OS
keeps about itself, and they are what lets the two-pass resize survive its own
reboot.

Everything else the tools write at runtime goes to a tmpfs `/run` and does not
survive.

Deleting the three markers, plus `/etc/sepiaos-password-unchanged`, re-runs the
whole first-boot sequence - which is the factory reset nobody has written a
command for yet.

**Where:** `ROOTFS_DIRS` in the Makefile · every `sepia-*` script.

---

## Networking

### 17. Interfaces, addressing and DNS

All network state is one shell-sourced file,
[`/etc/network.conf`](../../overlay/etc/network.conf), at mode 0600 because it
also holds the wifi key. It describes two interfaces, each independently `off`,
`dhcp` or `static` - "ethernet or wifi or both" is what falls out of the two
being separate.

[`sepia-network`](../../overlay/usr/sbin/sepia-network) is both the boot-time
applier (`sepia-network up`, from rcS) and the CLI that rewrites the file and
applies the change in one step: `status`, `up`, `down`, `restart`, `ethernet`,
`wifi`. Interface names are discovered rather than assumed.

DHCP is bounded on purpose: a server that does not answer costs a few seconds at
boot and is then waited for in the background, rather than holding the login
prompt up behind it.

**Where:** `overlay/etc/network.conf` · `overlay/usr/sbin/sepia-network` ·
`overlay/usr/share/udhcpc/default.script` ·
[`overlay/etc/resolv.conf`](../../overlay/etc/resolv.conf).
**Wraps:** busybox `udhcpc` and `ip`. Nothing is compiled for ethernet.

### 18. Wi-Fi: association, credentials and firmware

Three things ethernet does not need, and missing any one of them looks identical
from outside.

The **chip firmware** and its per-board NVRAM are curated out of Raspberry Pi's
`firmware-brcm80211` .deb: unpacked by hand, with the `update-alternatives`
symlink Debian's postinst would have made created here, because
`cyfmac43455-sdio.bin` is not in the package at all and yet is what a Pi 4, CM4,
Pi 5 and CM5 all ask for. Chips no supported board carries are pruned, and a
dangling symlink is a build failure rather than a runtime one.

The **supplicant configuration** is generated rather than shipped, and the
passphrase is stored as a PMK rather than in plaintext.

The **regulatory domain** is a two-letter country code in `network.conf`.
Without one the radio is held to the channels that are legal everywhere, which
on 5 GHz is most of them.

**Where:** the wifi section of the Makefile ·
`checksums/firmware-brcm80211-*.sha256` · `checksums/wpa_supplicant-2.12.sha256`
· `checksums/libnl-3.12.0.sha256` · `WIFI_*` in `overlay/etc/network.conf`.
**Wraps:** the `Sepia-OS/wifi` release and Raspberry Pi's firmware .deb.

### 19. Driver autoloading, with no udev and no mdev †

There is no hotplug manager on this system at all - no udev, no `mdev -s` - and
the repo replaces it with one function. `autoload_drivers()` walks
`/sys/bus/usb/devices/*/modalias` and the SDIO equivalent, skips anything that
already has a driver bound or has already been tried, and modprobes what each
device asks for by name. `wait_for_iface()` then gives the interface a bounded
window to appear.

It lives inside sepia-network because networking is what needs it - which is
also the argument that it is part of artefact 17 rather than one of its own.

**Where:** `overlay/usr/sbin/sepia-network`.

---

## The tree and the card

### 20. Skeleton, permissions and fstab

The FHS tree is created explicitly rather than inherited - 28 directories
including `etc/init.d`, `var/lib/sepia`, `var/log` and `usr/share/keymaps`, with
`/var/run` and `/var/lock` as symlinks into `/run`, which is where the FHS has
put them since 3.0 and where every tool expects to find them.

The permission model is applied as one block at the end of staging rather than
scattered through it: 0755 on the tree root and every script, 0700 on `/root`,
0600 on `/etc/shadow` and `/etc/network.conf`, 1777 on `/tmp` and `/var/tmp`,
0555 on `/proc` and `/sys`.

`/etc/fstab` names the root device and the boot partition. Note that it is
documentation and an fsck order only - the kernel has already mounted `/` by the
time anything reads it, and nothing on the card runs `mount -a`.

**Where:** `ROOTFS_DIRS` and the chmod block in the Makefile ·
`define generate_etc`.

### 21. The card image

The finished `.img` is created at full size as a sparse file. The boot release's
image - which already carries a valid MBR with partition 1 - is `dd`'d in whole
and adopted byte for byte: this repo never opens its FAT, and never edits
`config.txt` or `cmdline.txt`. The ext4 is written at the sector partition 1
ends on, with partition 1's start and length read out of the boot image rather
than assumed, so a change on the boot side cannot silently overlap.

Ownership is normalised to `root:root` through debugfs, which is what keeps the
build unprivileged on macOS and Linux alike - there are no loop mounts anywhere.

`ROOT_DEVICE` and `BOOT_DEVICE` must match the sibling `boot` repo's
`CMDLINE_ROOT`; that is a cross-repo contract, stated in the Makefile beside the
variables.

**Where:** the image section of the Makefile.

### 22. How big a card the image assumes ‡

A policy in its own right, and the one a user meets first. `IMAGE_SIZE_MIB` is
derived from what was actually included, ordered largest-first and stopping at
the first that applies: 2048 MiB with the Rust toolchain, 1024 with Helix, 512
with LLVM, 256 for a base card.

The middle rung exists because the editor is 216 MiB, and the toolchain plus the
editor plus the base tree come to about 528 MiB - which does not fit the 452 MiB
root of a 512 MiB card.

**Where:** `IMAGE_SIZE_MIB` in the Makefile.

### 23. Userland composition: who owns which binary

Six sibling payloads are unpacked into one tree in a fixed order, and the build
refuses silent overwrites: `install_toolchain`, `install_gnu_make`,
`install_rust`, `install_grit` and `install_helix` each `comm -12` their own file
list against the tree and fail the build on any overlap.

`install_e2fsprogs` allows exactly one class of collision - six busybox applet
symlinks (`blkid`, `findfs`, `fsck`, `mke2fs`, `mkfs.ext2`, `uuidgen`) are
unlinked first and replaced - because a busybox `mke2fs` shadowing a real one is
a filesystem you cannot fsck.

**Where:** the `define install_*` macros in the Makefile.

---

## Toolchain and compliance

### 24. Completing the on-device C/C++ toolchain

The LLVM package deliberately ships no libc, so this repo finishes the compiler
on the card. musl's `/usr/include` headers and its link-time objects - `crt1.o`,
`Scrt1.o`, `crti.o`, `crtn.o` and the empty `-lm` / `-lpthread` stub archives -
are copied out of `build/sysroot` into the tree, because headers *are* libc:
without them every `#include` fails and every link fails. `/usr/bin/ld` is
symlinked to `ld.lld`.

**Where:** `define install_toolchain` · `build/sysroot`.
**Wraps:** the `Sepia-OS/llvm` and `Sepia-OS/musl` assets.

### 25. The on-card licence shelf ‡

Every optional package must land a licence under `/usr/share/licenses/<pkg>/` or
the build fails - checked twice, once against the package's stage directory and
again in `assert_rootfs` against the finished tree. The repo does not author
these files, but it is the only place the policy exists.

**Where:** `define assert_rootfs` and each package's stage assertion.

---

## What isn't there

Absences, recorded because several of them are load-bearing and one contradicts
an artefact that *is* here. "By design" marks the ones the repo argues for
explicitly.

### No system TLS trust store, and why it does not matter yet

There is no `/etc/ssl`, no `ca-certificates` and no `.pem` anywhere in the repo.
That reads like it should break the build-date clock floor
([artefact 3](#3-the-clock-on-a-board-with-no-rtc)), whose whole justification is
that a card booting at the epoch cannot complete a handshake because every
certificate is *not valid before* a date after 1970. It does not.

**The binaries that make HTTPS requests carry their own roots.** `grit` embeds
the Mozilla set through `webpki-roots` - the subject names are in the shipped
binary, and there is no reference to `/etc/ssl`, `SSL_CERT_FILE` or
`ca-certificates.crt` in it. `spm` is the same by construction: `ureq` with the
`rustls-webpki-roots` feature. Helix does no TLS at all. So HTTPS from the
device works, and the clock floor delivers exactly what it was added for.

What is absent is a *system* trust store, and today nothing on the card reads
one. It becomes worth adding when either of two things happens:

- something arrives that does read one - a real `curl`, python, or anything
  linked against OpenSSL. `cargo` is the most likely candidate and has not been
  checked;
- a root expires, and the cost of compiled-in roots becomes visible: every Rust
  binary on the card has to be rebuilt and re-released, where a shared store
  would be one package update. That is the real argument for moving those
  binaries to `rustls-native-certs` - not that HTTPS is broken today.

Either way it is a new artefact of the usual shape: fetch a bundle, record it in
`checksums/` the way `tzdata` and `firmware-brcm80211` are, install it, and add
the path to `assert_rootfs`.

### The rest

| | |
|---|---|
| **System logging** | busybox ships `syslogd`, `klogd` and `logread`; nothing starts any of them. `/var/log` is created empty and stays empty, so a failed boot leaves nothing to read afterwards. Every message the boot scripts print goes to the console and nowhere else. |
| **No way to add a startup service** | inittab carries only sysinit, ctrlaltdel, shutdown and restart, and everything below the marker is rewritten by sepia-gettys every boot - so anything appended there is erased at the next one. Editing rcS is the only hook. |
| **Remote access** | No sshd, no dropbear, no host-key generation. `telnetd` and `inetd` exist as applets but are never started and would be unauthenticated anyway. A headless board that gets onto the network is still unreachable. |
| **Locale, charset and console font** | No `LANG` or `LC_*`, no locale files, no font installed, and `kbd_mode -u` is never called - which matters because the keymap set ships explicit UTF-8 and KOI8-R variants whose behaviour depends on the VT's mode. Keymap selection is solved; the encoding half of the same problem is not. |
| **`/boot` is never mounted** | `/etc/fstab` carries the vfat line and the Makefile comment beside it says it exists "so `mount /boot` in rcS has something to read" - but rcS contains no such mount and nothing else in `overlay/` mounts it. `/boot` stays an empty directory. |
| **GPIO, I2C and SPI permissions** | No `gpio`, `i2c`, `spi` or `video` groups, no device permission rules (there is no mdev to carry them anyway), and no interface-enabling step. Every peripheral node ends up root-owned with devtmpfs defaults, on a board that exists for its peripherals. |
| **Machine identity** | No `/etc/machine-id`, and nothing generates one on first boot; the hostname is the same string on every card and first boot never offers to change it. Nothing distinguishes one board from another for DHCP client identification, logging or fleet management. |
| **Hardware watchdog** | Every supported Pi has a bcm2835 watchdog and busybox ships the applet, but nothing opens `/dev/watchdog`. A hung headless board with no remote access stays hung until someone pulls power. |
| **Scheduled jobs** | `crond` and `crontab` ship as applets; no inittab entry, no `/etc/crontabs`, `/var/spool` an empty stub. Nothing can run periodically. |
| **Firewall** | No iptables or nftables and no filter configuration. A card on DHCP is exposed on whatever network it joins. |
| **terminfo** | Every login starts `TERM=vt100` - sepia-gettys writes it into each getty line and `/etc/profile` defaults to it - and there is no terminfo database anywhere in the image. |
| **Kernel tunables** | No `/etc/sysctl.conf` and `sysctl` is never invoked at boot, though sepia-firstboot's printk save/restore shows the mechanism is understood. |
| **`/etc/services`, `/etc/protocols`** | Absent, so `getservbyname()` and `getprotobyname()` fail on the card. (`/etc/nsswitch.conf` is *correctly* absent - musl has no NSS and reads hosts then resolv.conf unconditionally.) |
| **spm on the card** | No binary, no state directory, no package database recording what the sibling assets installed. `/etc/os-release` is a bill of materials, not something a package manager could act on. |
| **Update / OTA** | No A/B layout - boot + root + swap is fixed by sepia-firstboot - and no update hook. Updating means rewriting the card, which also destroys the first-boot state. |
| **Non-root accounts** | Three static accounts, no `/etc/skel`, `/home` empty, and first boot never offers to create a user - though a `wheel` group ships that nothing uses. |
| **RTC hardware** *(by design)* | No `hwclock` and no `/dev/rtc` handling, correct for a bare Pi and documented as such in sepia-time. Worth recording anyway: a Pi 5 has an on-board RTC connector and CM4/CM5 carriers often add one, and nothing here would use it if fitted. |
| **zram / zswap** *(by design)* | Swap is a real partition. On a 512 MB Zero 2 W, compressed swap is what you would usually reach for instead of writing to the card. |
| **Read-only root** *(by design)* | `/` is remounted read-write early in rcS and stays that way. The only mitigation is rcK's sync / `umount -a -r` / sync. |

## References

- [What the rootfs build actually owns](https://claude.ai/code/artifact/bd2e1df8-e094-4e40-a641-adf052a9a0f7)
