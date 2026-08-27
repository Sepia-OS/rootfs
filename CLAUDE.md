# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

Greenfield. The repository holds `README.md`, `LICENSE` and `.gitignore` — **no build system, no source, and no `.git` directory yet**. `README.md` is a specification of the build to be written, not a description of one that exists, so there are no commands to run yet. Building that pipeline is the work.

`.gitignore` already anticipates the intended layout and matches the sibling `boot` repository: `downloads/` (fetched upstream tarballs, kept across `clean`), `build/` (everything generated), `dist/` (release artifacts), plus `*.img`, `*.img.part` and `mtoolsrc`.

## What This Repository Is For

SepiaOS is an operating system for Raspberry Pi that reuses the kernel and firmware from Raspberry Pi OS; everything above the kernel is custom. Targets: Pi Zero 2 W, Pi 3, Pi 4, Pi 5, CM4, CM5.

This repository is the `rootfs` component. Per `README.md` the pipeline is:

1. Fetch the boot partition from the `Sepia-OS/boot` release (pre-release builds take the latest pre-release; release builds take the latest release).
2. Fetch an aarch64 cross-toolchain — macOS build host gets the macOS toolchain, Linux host the Linux one.
3. Build the latest musl libc release, both static and dynamic.
4. Build the latest busybox release as a **dynamic** executable against that musl.
5. Populate a root filesystem following the Linux FHS with musl and busybox.
6. Assemble a bootable image from the boot partition plus that rootfs, booting to a login prompt and dropping into the user's shell. `root` exists with password `sepiaos`, forced to change on first login.
7. On first boot, grow the rootfs to fill the whole storage device (SD card, USB stick, SSD), then reboot.

Step 7 shapes step 6: the shipped image is sized to its contents, not to any particular card, so the rootfs partition is deliberately small and the first boot rewrites the partition table in place and runs `resize2fs` before rebooting. That needs a once-only marker (Raspberry Pi OS uses a `cmdline.txt` `init=` hand-off plus a flag file) — a resize that repeats on every boot, or that runs against a mounted-read-write filesystem, is the failure mode to design against.

The sibling repositories live beside this one: [../boot](../boot) (a complete, working Makefile build — the closest model for what this repo should look like).

## The Contract With the `boot` Repository

These are the facts the rootfs build has to match; all were read out of `../boot`, not from documentation:

- **Only one boot asset is published**, `sepiaos-boot-universal-v<version>.img.xz`, alongside a `SHA256SUMS` file. There are no per-board assets — `BOARD=universal` builds a single card carrying every board's firmware, kernels and device trees, and the firmware picks the right ones at power-on. So the rootfs image is likewise one card for all six boards.
- Releases are cut by a manual `workflow_dispatch` with a `prerelease` boolean, so "latest pre-release" vs "latest release" is a real distinction on the GitHub releases API (`gh release list`, `gh release view --json isPrerelease`).
- The boot image is a **64 MiB MBR disk image** (`IMAGE_SIZE_MIB`), one FAT32 partition of type `0x0c` starting at 4 MiB — matching Raspberry Pi OS. The rootfs partition is therefore partition 2, appended after it.
- The boot partition's generated `cmdline.txt` says `root=/dev/mmcblk0p2 rootfstype=ext4 fsck.repair=yes rootwait`. **The rootfs must be ext4 on partition 2**, or `CMDLINE_ROOT` has to be overridden when building boot.
- A boot partition alone panics at `VFS: Unable to mount root fs`. That is boot's expected end state and this repository's starting point — the first milestone is turning that panic into an init.
- `../boot/Makefile` exposes `make -s print-<VAR>` (e.g. `print-IMAGE`, `print-FIRMWARE_TAG`) for scripts and CI to read a variable without parsing output.

## Build Environment

The user develops on macOS (`darwin`). Constraints inherited from `../boot`, each of which silently produces a broken result if violated:

- **GNU Make ≥ 4.0 is required — `gmake`, not `/usr/bin/make`.** Make 3.81 (macOS's) compares timestamps only to the second and will use stale outputs after a fast edit. `../boot/Makefile` hard-errors on it; do the same here.
- **macOS has no `sfdisk`, no loop mounts, no `mkfs.ext4`.** `../boot` routes everything through `mtools` so the build stays unprivileged and cross-platform. FAT has an mtools equivalent; **ext4 does not** — creating the rootfs partition on macOS without root is the central unsolved problem of this build, and is worth deciding deliberately (`e2fsprogs` from Homebrew, a Linux container, or a `genext2fs`-style tool) before writing the image rules.
- Boot artifacts are built in `debian:trixie-slim` in CI because mtools decides the FAT layout; shipping an image built elsewhere would ship one that the boot checks never ran against.

## QEMU Caveats

These apply the moment this repository boots an image, and each one reads like a broken image when it isn't:

- **QEMU never runs the VideoCore boot chain** — it ignores `bootcode.bin`, `start.elf` and `config.txt` on the card. The kernel and DTB must be passed as `-kernel`/`-dtb`. No `-kernel` produces *no output at all*.
- **`earlycon=` is mandatory** or the serial console stays silent — the kernel stalls before `ttyAMA0` registers. PL011 base per SoC: `0x3f201000` (BCM2837), `0xfe201000` (BCM2711).
- **QEMU rejects any SD image whose size is not a power of two.** This collides with sizing the shipped image to its contents for the first-boot resize: an image built to fit has to be padded up to the next power of two before it can be booted under QEMU at all. Padding also gives the resize something to grow into, so a QEMU run can actually exercise it.
- **The Pi 4 exposes the card as `mmcblk1` under QEMU but `mmcblk0` on real hardware**, so the QEMU `-append` root device and the `root=` in `cmdline.txt` legitimately differ.
- The Zero 2 W device tree faults on `raspi3ap`; emulate it as `raspi3b`.
- A green QEMU boot proves the kernel, the partition layout and (here) whether init runs. It proves nothing about `config.txt`, device-tree auto-selection or overlays — only real hardware tests those.
