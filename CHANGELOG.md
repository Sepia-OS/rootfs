# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are dated: `v2026.9.5` is the sixth release cut in September 2026. The
versions of everything on the card — musl, LLVM, GNU make, e2fsprogs,
wpa_supplicant, Rust, grit — are named in each release's notes and recorded in
the image's own `/etc/os-release`.

## [Unreleased]

### Added

- `sepia-time`, and with it a clock the card can rely on. A Raspberry Pi has no
  battery-backed clock, so the card booted at 1 January 1970 — and since every
  TLS certificate is "not valid before" a date after that, HTTPS could not work
  at all: `grit clone https://…` failed, and so did anything else talking to a
  server. Two halves, run from `rcS` immediately after the network comes up:
  the clock is set forward to `/etc/sepia-build-date` if it is behind it (no
  network, no waiting, and what makes the *first* boot able to talk HTTPS),
  then busybox `ntpd` is started in the background as a daemon.
- `NTP` and `NTP_SERVERS` in `/etc/network.conf`, and `sepia-time status`,
  `sync`, `floor` and `stop`.
- The timezone database, unpacked from Debian's `tzdata` package the same way
  the Broadcom firmware is: 1.9 MiB, 312 canonical zones. `WITH_TZDATA=0`
  leaves it out.
- A fourth first-boot question: which timezone the card is in, asked in two
  levels — region, then city — because 312 zones at twenty to a page is sixteen
  pages of Enter to reach `Europe/Berlin`. Both lists are paged, Enter wraps
  round, and a board with no keyboard console keeps UTC.
- `sepia-time zone` and `sepia-time zones` for changing it afterwards. A zone
  is a symlink at `/etc/localtime` and the name in `/etc/timezone` and nothing
  else: musl reads `/etc/localtime` when `TZ` is unset, so `date` in an init
  script agrees with `date` at a login prompt.

## [2026.9.5] - 2026-09-06

### Added

- grit, from the `Sepia-OS/grit` release, and with it the **`git` command**: the
  asset carries the binary and a relative `git -> grit` symlink, which
  `install_grit` preserves with `cp -R` and `assert_rootfs` reads back.
- `grit-check`, whose claim is the opposite of every other package's — grit is
  statically linked, so what is asserted is that it asks for *no* interpreter
  and needs *no* shared library.

## [2026.9.4] - 2026-09-06

### Added

- The Rust toolchain, from the `Sepia-OS/rust-toolchain` release: `rustc`,
  `cargo` and the standard library on the card.
- `assert_rootfs` also demands `librustc_driver` and `libstd`, because
  `bin/rustc` is a 72 KiB shim that loads them — a tree with the programs alone
  would pass a naive check and fail at the first `rustc --version`.

### Changed

- **The shipped image is now 2 GiB.** 264 MiB of everything else plus 725 MiB
  of Rust does not fit in 512 MiB, and QEMU only accepts a power of two, so
  1024 would leave about 35 MiB free. `WITH_RUST=0` returns it to 512 MiB.

## [2026.9.3] - 2026-09-05

### Changed

- musl is no longer built here. It comes from the `Sepia-OS/musl` release as a
  sysroot, which is unpacked into `build/sysroot`; this repository resolved
  "the latest musl" from git tags on every build, which meant the card's libc
  could change without a commit and cost two minutes of every build.
- libnl and wpa_supplicant are no longer built here either — about eighty lines
  of configure flags, a pkg-config stub and a note about bison went to
  `Sepia-OS/wifi` with the code that needed them. The **firmware** is still
  fetched here: it is a download rather than a build, four times the size of
  the package, and tied to the kernel that loads it.

### Removed

- The musl git-tag resolver, its two mirrors, the offline fallback,
  `musl-verify-sig` and the pinned GPG fingerprint. One host answers now, and
  it is the one the build already cannot run without.

## [2026.9.2] - 2026-09-05

### Added

- The e2fsprogs package, from the `Sepia-OS/e2fsprogs` release: 22 programs and
  9 alternate names, `/etc/mke2fs.conf`, and real `mke2fs`, `e2fsck` and
  `fsck.ext4` in place of six busybox applets. The applet symlinks are removed
  before the copy — `cp` follows a symlink it is copying onto, and without the
  `rm` e2fsck's bytes would land inside `/bin/busybox`.

### Changed

- The cross-built `resize2fs` is gone from the default path; the package
  carries the same binary. `WITH_E2FSPROGS=0` brings the single cross-build
  back, so first boot can grow the card either way.

## [2026.9.1] - 2026-09-04

### Added

- GNU make on the card, from the `Sepia-OS/make` release, so a SepiaOS device
  can build a project rather than compile a file.

## [2026.9.0] - 2026-09-04

### Added

- The on-device LLVM toolchain, from the `Sepia-OS/llvm` release, copied onto
  the card with musl's headers and link-time objects beside it and a
  `/usr/bin/ld` so `clang hello.c` works rather than only `clang -c`.

### Fixed

- A reused tag made a cached download lie. `llvm` keeps one release at a time
  and republishes under the *same* tag, so `downloads/llvm/<tag>/` could hold a
  tarball and a `SHA256SUMS` that were both stale and agreed with each other.
  The download is now keyed on the release **asset's GitHub id**, which changes
  on every upload; CI hit this for real, unpacking a 186 MiB toolchain where the
  release was 196 MiB.
- Assorted pipeline failures, and the first `libatomic.so.1` fallout.

## [2026.8.1] - 2026-08-31

### Added

- Console keymaps from TinyCore Linux, vendored, and switching between
  `tty2`–`tty9`.

### Changed

- The displayed version name.

### Fixed

- Reported vulnerabilities.
- The Raspberry logos in the corner no longer linger over the login prompt.

## [2026.8.0] - 2026-08-29

### Added

- The whole pipeline, steps 1–8 of `README.md`: fetch the boot partition, fetch
  a cross-toolchain, build musl and busybox, install the kernel modules, create
  an ext4 root filesystem and assemble a bootable image, test it under QEMU,
  and ship a launcher script.
- Networking — ethernet and wifi, DHCP or static — with `sepia-network`, and
  the first-boot questions that configure it.
- Keyboard layout handling with `sepia-keymap`, and a first-boot question for
  it.
- First boot: grow the root filesystem into the card, add swap, and reboot.
- CI on every branch and a manual release workflow.

### Fixed

- Several pipeline failures, a reboot issue, a build timeout, and a hang before
  the login prompt appeared.

[Unreleased]: https://github.com/Sepia-OS/rootfs/compare/v2026.9.5...HEAD
[2026.9.5]: https://github.com/Sepia-OS/rootfs/releases/tag/v2026.9.5
[2026.9.4]: https://github.com/Sepia-OS/rootfs/releases/tag/v2026.9.4
[2026.9.3]: https://github.com/Sepia-OS/rootfs/releases/tag/v2026.9.3
[2026.9.2]: https://github.com/Sepia-OS/rootfs/releases/tag/v2026.9.2
[2026.9.1]: https://github.com/Sepia-OS/rootfs/releases/tag/v2026.9.1
[2026.9.0]: https://github.com/Sepia-OS/rootfs/releases/tag/v2026.9.0
[2026.8.1]: https://github.com/Sepia-OS/rootfs/releases/tag/v2026.8.1
[2026.8.0]: https://github.com/Sepia-OS/rootfs/releases/tag/v2026.8.0
