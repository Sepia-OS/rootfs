# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

Early. The repository has one commit (`Created the repository`); the `Makefile` and `checksums/` are not committed yet. `README.md` is a specification of the build; of its seven steps **steps 1 to 5 — the boot partition, the cross-compiler, musl libc, busybox, and the kernel modules — are implemented**. The rest of the `Makefile` is still to be written.

Layout, matching the sibling `boot` repository and already encoded in `.gitignore`: `downloads/` (fetched upstream artifacts, kept across `clean`), `build/` (everything generated), `dist/` (release artifacts).

## Commands

**Use `gmake`, not `make`.** The Makefile hard-errors on Make 3.81 (`/usr/bin/make` on macOS).

```sh
gmake help                              # every target, with the variables that steer them
gmake boot-partition                    # fetch + verify + unpack the boot image
gmake boot-info                         # tag, size, and where partition 1 ends
gmake boot-update                       # re-resolve "latest" and refetch
gmake CHANNEL=release boot-partition    # take the latest full release instead
gmake BOOT_TAG=v0.1.0 boot-partition    # pin one specific boot release
gmake toolchain                         # fetch the aarch64 cross-compiler for this host
gmake toolchain-info                    # which compiler, from where, targeting what
gmake musl                              # cross-build musl into build/sysroot (~2 min cold)
gmake musl-info                         # version, sysroot, static/shared sizes
gmake musl-check                        # link a test program against the sysroot, both ways
gmake MUSL_VERSION=1.2.5 musl           # pin a musl release
gmake busybox                           # build busybox and install it into build/sysroot
gmake busybox-info                      # version, size, applet count, loader
gmake modules                           # install the boot kernel's modules into build/sysroot
gmake modules-info                      # firmware tag, commit, both trees with sizes
gmake modules-check                     # re-read the installed trees and their depmod data
gmake FIRMWARE_TAG=1.20260521 modules   # pin the firmware tag instead of taking boot's
gmake clean                             # drop build/, keep downloads/
gmake distclean                         # also drop downloads/ (including ~600 MiB of toolchain)
```

Every aggregate goal (`boot-partition`, `toolchain`, `musl`, `busybox`, `modules`) ends with a `READY` line naming the version and where it landed. That line prints whether or not anything was rebuilt — a phony goal whose prerequisite is already built otherwise prints *nothing*, which reads exactly like a broken target.

Required tools: `gmake` ≥ 4.0, `curl`, `jq`, `xz`, `tar` (`brew install make jq xz`; macOS 13+ already ships `jq` at `/usr/bin/jq`).

### How step 1 works

- `CHANNEL` (`prerelease` by default, or `release`) is the rootfs build's *own* channel, and it selects the matching boot release. Implemented literally per the README: a release build never picks up a pre-release, and a pre-release build stays on the pre-release line even once a full release exists.
- The asset is **not** addressed by a guessed filename. The release JSON is asked for its `.img.xz` asset, so an upstream rename surfaces as a clear error rather than a 404 on an invented URL. `SHA256SUMS` is mandatory — an image that cannot be verified is refused.
- `"latest"` is resolved **once** and cached in `build/boot/release.env`; a build does not drift onto a newer boot partition halfway through. `boot-update` is the only thing that moves it. `build/boot/.config` carries a signature of `BOOT_REPO|CHANNEL|BOOT_TAG` so that changing one of those on the command line — which touches no file — still invalidates the resolution.
- Downloads are keyed by tag under `downloads/boot/<tag>/` and survive `clean`, because release assets are immutable.
- **`--fail` is deliberately absent from the API calls** and present on the asset downloads. On the API it would collapse "no such release" and "the network is down" into one non-zero exit; the HTTP status is read instead so the three cases (404, rate limit, transport failure) each report themselves. On the asset downloads `--fail` is what stops a 404 page being saved as if it were the image.
- `GITHUB_TOKEN` is honoured when set — the unauthenticated API allows 60 requests an hour per IP.
- After unpacking, MBR byte 450 is asserted to be `0x0c` (FAT32 LBA). Cheap, and it catches having fetched something that is not a Pi card before a rootfs gets appended to it.

### How step 2 works

**No vendor ships an aarch64-linux-targeting toolchain for both hosts.** This was checked, not assumed, and it is why "the macOS version on macOS, the Linux version on Linux" means two different sources:

- Arm's own GNU toolchain has macOS builds only for its *bare-metal* targets (`aarch64-none-elf`). Every `*-none-linux-gnu` build is Linux- or Windows-hosted, so it cannot serve a macOS host at all.
- `messense/homebrew-macos-cross-toolchains` publishes darwin-hosted assets only — there is no Linux-hosted asset in its releases.

So: **macOS → messense 15.2.0** (`aarch64-unknown-linux-gnu`, gcc 15.2), **Linux → Arm 14.3.rel1** (`aarch64-none-linux-gnu`, gcc 14.3). Both hosts and both host architectures were verified to resolve. The consequence is that **the compiler differs by build host, so macOS and Linux builds are not byte-identical** — release builds should be cut on Linux the way `../boot` already does it, with macOS as the development host.

- The **GNU-targeting** variant is chosen deliberately over the musl-targeting one messense also ships: step 3 builds musl from source, and a toolchain with musl baked in would make that step a no-op.
- Everything is pinned, so unlike step 1 nothing is resolved over the network and all paths are known at parse time — ordinary Make file targets, no cached resolution.
- Both vendors publish a plain `sha256sum`-format sidecar (`.sha256` for messense, `.sha256asc` for Arm — despite the name it is a bare digest, not a signature), so the download is checked against upstream's own digest rather than a checksum committed here.
- The toolchain is unpacked into `downloads/toolchain/<vendor>-<version>-<host>/`, **not** `build/`: it is an immutable upstream artifact and ~600 MiB is too much to re-extract on every `clean`.
- `$(CROSS)gcc -dumpmachine` is asserted after unpacking. A toolchain for the wrong *host* extracts happily and then fails to exec; one for the wrong *target* compiles happily and produces host binaries. One cheap call catches both — it correctly rejects `CROSS_COMPILE=/usr/bin/`, for instance.
- Setting **`CROSS_COMPILE`** (e.g. Debian's `aarch64-linux-gnu-`) skips the download entirely and validates what you pointed at.

### How step 3 works

- **`build/sysroot` is the deliverable**, produced by `--prefix=/usr --syslibdir=/lib` plus `make install DESTDIR=…`, *not* by an absolute `--prefix`. That keeps the tree correct as a rootfs: `lib/ld-musl-aarch64.so.1` points at `/usr/lib/libc.so`, which is where it really will be on the target. Steps 4 and 5 consume it directly.
- **`--disable-wrapper`, so no `musl-gcc` is built.** The sysroot doubles as the source of the shipped rootfs and SepiaOS ships no compiler; without the flag musl installs `usr/bin/musl-gcc` and `usr/lib/musl-gcc.specs`. The wrapper would be the wrong tool here anyway — its specs bake in whatever absolute paths `configure` saw, so a staged install points them at the build host's directories, and `-isystem /usr/include` inside a specs file is not sysroot-relative. Step 4 builds with `--sysroot=$(abspath build/sysroot) -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1` instead.
- **The sysroot is musl *plus* Linux UAPI headers.** A musl install alone is not a usable sysroot: busybox will not compile without `linux/kd.h` and friends. They are copied in from `$(CROSS)gcc -print-sysroot` — the same toolchain that supplies libgcc — so this costs no download and cannot drift from the compiler.
- **The version is resolved from git tags** (`git ls-remote --tags --refs`), not by scraping the release index. `sort -V` is what keeps 1.2.10 above 1.2.6; a plain `sort` gets that backwards. Resolution is cached in `build/musl/version.env` exactly like the boot release, with `musl-update` to move it.
- **Trust model is weaker here than in steps 1 and 2, and this is worth knowing.** musl publishes no checksum sidecar — only a detached GPG signature — so the digest is recorded in `checksums/musl-<version>.sha256` on first fetch and checked against that record every time after. That first fetch is trust-on-first-use; the manifest must be committed for it to mean anything afterwards. `musl-verify-sig` is the real check (pinned fingerprint `836489290BB6B70F99FFDA0556BCDB593020450F`) and is opt-in because it needs `gpg` plus a keyserver round trip.
- **Both linkages are exercised, not inferred** from `libc.a` and `libc.so` merely existing: a test program is linked static and dynamic, then `readelf` confirms AArch64 and that the dynamic one records the musl loader. `readelf` comes from the cross-toolchain, so this adds no dependency — `file` is absent from a slim Debian image.
- `configure` and `make` output goes to `build/musl/musl-<version>/{configure,build}.log`; only the tail surfaces, and only on failure.

### How step 4 works

- **Verification is stronger here than for musl**: busybox publishes a plain `.sha256` next to every tarball, so the download is checked against upstream's own digest with no trust-on-first-use record to keep.
- **defconfig compiles clean against musl** — checked on 1.38.0, no applets had to be turned off. Flags go in through `CONFIG_EXTRA_CFLAGS` / `CONFIG_EXTRA_LDFLAGS`, which is where busybox's `Makefile.flags` picks up anything extra.
- **"Dynamic, against the musl from step 3" is read back off the binary**, not inferred from the flags that were passed: `readelf` must show AArch64, an interpreter of `/lib/ld-musl-aarch64.so.1`, and a `NEEDED` entry for `libc.so`. A static build would have none of those. `CONFIG_STATIC` is separately asserted to be unset before the build starts.
- **`make busybox` always runs the compiler**, by design: `$(BB_BIN)` carries a `FORCE` prerequisite. Configuring is a separate stamp from compiling, because `defconfig` rewrites `.config` from scratch and so invalidates every object file — folding the two together made every run either a full rebuild or, once nothing upstream had changed, no build at all. busybox's own kbuild decides what to recompile (about three seconds when nothing changed) and is a better judge of that than a stamp here, which cannot see an edit inside the source tree. The result is copied out only when it differs, so an unchanged build does not bump timestamps and set everything downstream rebuilding.
- **busybox is installed into `build/sysroot`** (`make install CONFIG_PREFIX=…`): `/bin/busybox` plus 408 applet symlinks, including `/sbin/init` and `/bin/sh`. `make busybox.links` is run too — the same applet list with FHS paths, for step 5.
- Because musl and busybox now share that tree, **step 3 clears only the directories musl owns** (`usr/include`, `usr/lib`, `lib/ld-musl-*`) instead of the whole sysroot; an `rm -rf` there would delete the busybox install whenever musl alone was rebuilt.
- **`oldconfig` reads from `/dev/null`, never from `yes ""`.** Under `pipefail` a `yes` killed by SIGPIPE fails the whole recipe. Nothing is asked anyway, since editing two string options introduces no new symbols.
- **busybox.net is genuinely flaky** — it went down for minutes and reset mid-transfer connections repeatedly during development. Hence `--retry-all-errors` on every download (plain `--retry` does not cover a reset once bytes are moving), and `BUSYBOX_BASE` is overridable so a mirror such as `https://sources.buildroot.net/busybox` can serve the tarball. That mirror carries no `.sha256`, so the digest is always taken from the canonical site (`BUSYBOX_SUMS_BASE`) and a mirrored tarball still has to match it. Resolving "latest" needs the canonical index either way, so a mirror only helps together with `BUSYBOX_VERSION`.

### How step 5 works

- **The firmware tag is read out of the boot release notes, not configured.** The release body carries ``| Raspberry Pi firmware | `1.20260521` |``, and step 1's single API call now also mines that into `BOOT_FIRMWARE_TAG` in `build/boot/release.env`. Modules from a different kernel version will not load, so the tag that produced the boot kernel is the only correct one; `FIRMWARE_TAG=` overrides it and then step 5 needs no boot release at all.
- A `release.env` written before that field existed makes `modules` stop with an explicit "run `boot-update`" message rather than a confusing empty tag — `${VAR+set}` distinguishes *absent* (stale file) from *empty* (a release whose notes name no tag), and the two get different advice.
- **A blobless sparse clone is what fetches them.** Each tree is 1900 files, so HTTP would be several thousand requests, and the release tarball would drag in all five module trees plus the firmware blobs. `git clone --depth 1 --filter=blob:none --sparse --branch <tag>` costs 1.8 MiB and ~3 s; the sparse checkout of the two wanted paths then pulls the ~54 MiB that is actually used. Same technique `../boot` uses for `boot/overlays`.
- **The kernel version is discovered, not configured**: `git ls-tree HEAD modules/` is read from the clone and the entries ending `-v8+` and `-v8-16k+` are picked. It changes with every firmware release, and `modules/` is the authority on it. `1.20260521` gives `6.18.32-v8+` (1887 modules) and `6.18.32-v8-16k+` (1886), 27 MiB each.
- The other three trees are deliberately left behind: `+` and `-v7+` are 32-bit kernels this project does not ship, and `-v8-rt+` is the realtime kernel the boot partition does not carry.
- **The recorded artifact is the tag's commit SHA**, in `checksums/firmware-<tag>.commit`, trust-on-first-use like the musl digest. A git tag can be moved upstream; everything below the commit is covered by git's own integrity, so one line of manifest stands in for 3800 files. Verified by simulation: a mismatched record aborts the fetch and leaves nothing behind in `downloads/`.
- **`depmod` has already been run upstream** — `modules.dep`, `modules.alias` and the `.bin` companions ship in the tree — so nothing here has to run a `depmod` that can target a foreign module tree from macOS. The modules themselves are `.ko.xz`.
- **The assertion reads `modules.dep` and looks for the first module it names.** That is what catches the real failure mode: a sparse-checkout pattern that matches the directory but none of its contents leaves all the metadata in place and the `.ko.xz` files absent, which every "does the directory exist" check would pass.
- `build/sysroot/lib/modules` belongs to this step alone and is cleared wholesale on rebuild, so a moved firmware tag cannot leave the previous kernel's tree behind. It is deliberately **independent of musl and busybox** although all three write into the same sysroot — `make modules` is usable on its own, without waiting for a libc build.
- Downloads are keyed by tag under `downloads/modules/<tag>/` and survive `clean`; a `.complete` marker distinguishes a finished copy from an interrupted one, which would otherwise look like a good cache entry. `clean` + `modules` is ~3 s.
- **For step 6:** busybox's `FEATURE_SEAMLESS_XZ` defaults to `y` and its help text names modprobe explicitly (`modprobe` reads modules through `xmalloc_open_zipped_read_close`), so a defconfig busybox can load these `.ko.xz` files. Worth re-reading off the generated `.config` when module loading is actually wired up.

### Make dependency layout

`Makefile` is a prerequisite of the things that are **built** (`boot.img`, the musl install, the busybox binary, the module install) but deliberately **not** of the things that are **resolved** (`*/version.env`, `boot/release.env`) or **fetched** (`modules/.fetched`). Editing a recipe should rebuild; it must never re-run a "latest" lookup and quietly move the project onto a newer upstream release, or re-clone 54 MiB of modules. The toolchain is left out of even the build half — its version is part of its path, and re-extracting 600 MiB on every edit would be absurd.

## What This Repository Is For

SepiaOS is an operating system for Raspberry Pi that reuses the kernel and firmware from Raspberry Pi OS; everything above the kernel is custom. Targets: Pi Zero 2 W, Pi 3, Pi 4, Pi 5, CM4, CM5.

This repository is the `rootfs` component. Per `README.md` the pipeline is:

1. Fetch the boot partition from the `Sepia-OS/boot` release (pre-release builds take the latest pre-release; release builds take the latest release).
2. Fetch an aarch64 cross-toolchain — macOS build host gets the macOS toolchain, Linux host the Linux one.
3. Build the latest musl libc release, both static and dynamic.
4. Build the latest busybox release as a **dynamic** executable against that musl.
5. Fetch the Raspberry Pi kernel modules and install them under `/lib/modules`.
6. Create an ext4 rootfs on the Linux FHS holding musl, busybox and the modules, and assemble a bootable image with the boot partition. It boots to a login prompt and drops into the user's shell; `root` exists with password `sepiaos`, forced to change on first login.
7. On first boot, grow the rootfs to fill the storage device minus a swap partition (1/2/4 GiB by device size), activate swap, then reboot.
8. Test the image by booting it under QEMU as a Pi 3, and ship a launch script that does the same interactively.

Step 7 shapes step 6: the shipped image is sized to its contents, not to any particular card, so the rootfs partition is deliberately small and the first boot rewrites the partition table in place and runs `resize2fs` before rebooting. That needs a once-only marker (Raspberry Pi OS uses a `cmdline.txt` `init=` hand-off plus a flag file) — a resize that repeats on every boot, or that runs against a mounted-read-write filesystem, is the failure mode to design against.

Steps 1 to 5 are implemented, so the next milestone is **step 6** — the ext4 rootfs and the bootable image. Two facts about step 5 that shape it: the modules live in `raspberrypi/firmware` under `modules/`, at the same tag `../boot` pins as `FIRMWARE_TAG`; and **two trees are needed, not one**, because the universal boot partition ships two kernels — `kernel8.img` (Zero 2 W, Pi 3, Pi 4, CM4) takes `<version>-v8+`, `kernel_2712.img` (Pi 5, CM5, 16K pages) takes `<version>-v8-16k+`. Shipping only `-v8+` gives a card that boots four boards with modules and two without. That is ~54 MiB of the image before anything else is in it.

The sibling repositories live beside this one: [../boot](../boot) (a complete, working Makefile build — the closest model for what this repo should look like).

## The Contract With the `boot` Repository

These are the facts the rootfs build has to match; all were read out of `../boot`, not from documentation:

- **Only one boot asset is published**, `sepiaos-boot-universal-v<version>.img.xz`, alongside a `SHA256SUMS` file. There are no per-board assets — `BOARD=universal` builds a single card carrying every board's firmware, kernels and device trees, and the firmware picks the right ones at power-on. So the rootfs image is likewise one card for all six boards.
- **The release body is part of the interface, not just prose.** It names the firmware tag as a table row, ``| Raspberry Pi firmware | `1.20260521` |``, and step 5 parses that to know which kernel modules match the shipped kernel. If `../boot` ever restyles its release notes, `modules` stops with a message asking for `FIRMWARE_TAG=` — it does not silently fetch the wrong kernel's modules.
- Releases are cut by a manual `workflow_dispatch` with a `prerelease` boolean, so "latest pre-release" vs "latest release" is a real distinction on the GitHub releases API (`gh release list`, `gh release view --json isPrerelease`).
- The boot image is a **64 MiB MBR disk image** (`IMAGE_SIZE_MIB`), one FAT32 partition of type `0x0c` starting at 4 MiB — matching Raspberry Pi OS. The rootfs partition is therefore partition 2, appended after it. Measured on `v0.1.0` via `gmake boot-info`: partition 1 starts at sector 8192 and runs 122880 sectors, so **the rootfs begins at sector 131072** (64 MiB in).
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
