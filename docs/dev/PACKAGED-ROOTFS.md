# Building the rootfs from packages

A plan for assembling the root filesystem by **installing spm packages** rather
than by unpacking release tarballs with bespoke Makefile macros, with a locked
base set that can be updated but not removed.

The companion to [ROOTFS.md](ROOTFS.md), which inventories the 25 device-level
subsystems this repository authors. This document is about turning those - and
the ten payloads that arrive from sibling repositories - into packages.

It spans four repositories: `spm` gains two capabilities, the sibling payload
repos gain package targets, `rootfs` changes how it assembles the tree, and
`sepiaos-package-index` needs nothing on the critical path. Every claim below
was checked against the code on 2026-09-10; where it disagrees with the code,
the code is right.

---

## Verdict

**Achievable, and further along than it looks.** Four sibling repositories
already carry a checked-in `metadata.json` *and* a `make package` target -
musl, busybox, e2fsprogs and wifi - and `spm` has metadata for itself. The
`ROOTS` relaxation those repositories were explicitly waiting on has landed
(`spm/src/layout.rs:89`); busybox's Makefile still carries the note saying its
package cannot succeed until it does.

What is missing is not packaging. It is **the installer**. The rootfs build
cannot call `spm install` at all, and should not try to:

- `--root` is a written refusal, not an omission. `spm/src/store/mod.rs:26-29`:
  *"It is not a user-facing option: a package manager with a `--root` flag is
  one that can be pointed at the wrong system, and nothing in
  `docs/dev/ARCHITECTURE.md` asks for that."*
- A global `--root` flag would collide with `create --root`, which is the
  staged tree to pack (`spm/src/cli.rs:277-280`).
- `install` additionally needs an index, HTTPS, and a signature keyed to that
  index - and `Target::current()` resolves to `aarch64-macos` on the build
  host.

The shape is **host build mode**: a cargo feature that compiles an spm for the
build host, in which a base root is set once and every path spm touches is
relative to it. A compile-time gate rather than a runtime flag is what answers
`store/mod.rs` on its own terms - the device binary physically cannot be pointed
at the wrong system, because the code is not in it.

The host-mode binary is **a build tool, not a package**. It is never shipped and
never on a card; it exists to populate `build/rootfs`. The `spm` that ends up at
`/usr/bin/spm` is the ordinary `aarch64-musl` package, pulled and installed like
any other. The two are unrelated artefacts, so spm never bootstraps itself.

**What cannot be achieved as stated is "everything".** The FHS skeleton, the
permission block, eight generated `/etc` files and `/var/lib/sepia` stay the
Makefile's - permanently, or until spm learns file modes. See
[What stays the Makefile's](#what-stays-the-makefiles).

---

## The chicken-and-egg, precisely

The problem is sharper than "a card has no package database".

`ops::install::unclaimed` (`spm/src/ops/install.rs:696-725`) refuses any path
that exists on disk and that no record claims - `Error::FileUnowned` at
`:718-721`. Every one of the roughly 11,000 base paths on a card is exactly
that. So today's card is not merely *unmanaged*; it is **un-installable-over**.
`spm install helix` on a card built `WITH_HELIX=1` fails on `/usr/bin/hx`, and
there is no `--force` anywhere in the CLI.

Packaging the base dissolves that completely. Every file gets an owner;
`install`, `upgrade`, `verify` and `remove` all become reachable for the base;
and `/var/lib/spm/installed/<name>.json` - metadata, source, reason, file list
and a per-file digest taken during extraction - replaces the 19 `SEPIAOS_*`
strings in `/etc/os-release` with something a program can act on.

**What irreducibly remains** is that something has to write the first records
without spm being installable. Four separate refusals stand between the build
and `spm install`, and all four are deliberate:

| | |
|---|---|
| The store root is `/` | `store/mod.rs:56`, sole caller `main.rs:88`; the module doc rejects a user-facing `--root` by name |
| The target is the host's | `Target::current()`, `model/name.rs:209-219` - `aarch64-macos` here |
| Transport is HTTPS-only | `net/https.rs:150` refuses any non-`https` URL |
| Signatures are keyed to the index | `ops/install.rs:396-435` - there is no index-free install path |

And the database can never itself be a package: `var` is outside `ROOTS`, with
the reasoning at `layout.rs:53-58` - a package able to write there could forge
an install record - and asserted at `:219`.

So **the build becomes the trusted first installer**, the status `debootstrap`
holds in Debian. That is not a loss of assurance: host mode reads the package's
own metadata, checks the archive digest against `SHA256SUMS`, the payload digest
against the metadata, and the Ed25519 signature - the same evidence a device
checks.

It must accept a **local package file** as well as a source, and that is not a
detail. Installing only from the index at build time would cost two things the
build has today: offline builds, and pinning - spm has no lockfile, so
resolution takes the newest the index offers and records nothing, where all ten
of today's payload fetches are pinned at a tag with a recorded digest. It would
also mean a busybox change could not be tested without a release round-trip.

---

## What already exists

| Repository | `metadata.json` | `make package` |
|---|---|---|
| musl | yes | yes |
| busybox | yes | yes |
| e2fsprogs | yes | yes |
| wifi | yes | yes |
| spm | yes | packed by `release.yml` |
| llvm, make, rust-toolchain, grit, helix | no | no |

The four complete producers were written against a spm that refused their
trees. Both blocking rules have since gone: `ROOTS` is now
`bin, etc, lib, sbin, usr`, and the rule refusing `libc.so*` / `ld-musl-*` was
removed in favour of install-time conflict detection (the reasoning is on
`check_tree` in `spm/src/ops/create.rs`). **Verifying that those four `package`
targets now succeed is the cheapest first experiment in this whole plan.**

---

## The two new capabilities in spm

### `spm base` - locked base packages

A name list at `/var/lib/spm/base`, a new `Error::PartOfBase` at exit 7, and a
refusal in `remove::plan` placed *before* the existing dependents check so the
better message wins. `Store::base_file()` sits beside `sources_file()`
(`store/mod.rs:76-80`) and loads fail-open on `NotFound` the way `Sources::load`
does - a missing file means the empty set, so every existing card and every
`Store::at(tempdir)` test behaves exactly as today.

Under `/var/lib/spm` and **not** `/etc/spm`, for the reason `layout.rs:53-58`
already gives: `etc` is a writable root, so a package could ship a file that
edits the base set.

Three naming notes:

- **Not "locked".** spm already uses that word for the store's single-writer
  file lock - `Error::Locked`, `store/lock.rs`, `/var/lib/spm/lock`. A second
  meaning would be actively confusing.
- Base membership is a **guard against accident, not against an adversary with
  root**. `/var/lib/spm/base` is plaintext and anyone who can run `spm remove`
  can also edit it. That is intentional - it is the escape hatch - but it must
  never be described as a security control.
- Note the asymmetry: editing the file lets you remove busybox, and nothing
  then re-adds it, because there is no `/bin/sh` left to run `spm install`.

### Host build mode - the first installer

A cargo feature, off by default, that makes the store root and the target
settable and lets `install` take a local file:

```
spm --root build/rootfs --target aarch64-musl install --base ./busybox-1.38.0.tar.gz
```

**A feature, not a flag.** `store/mod.rs:26-29` refuses a user-facing `--root`
because a package manager that has one can be pointed at the wrong system. A
compile-time gate honours that exactly: the released `aarch64-musl` binary is
built without the feature, so the flag does not exist on a device. It also
avoids the clap collision with `create --root` (`cli.rs:277-280`), since the two
sit at different levels.

`--target` has to be explicit regardless: `Target::current()` reports
`aarch64-macos` on the build host (`model/name.rs:209-219`).

It needs a refactor first. `ops::install::one` (`install.rs:355-546`) takes a
`&Step` whose `selected` wraps an `IndexVersion` carrying url, bytes, sha256 and
public_key; `:371` compares against `selected.version.sha256` and `:405-418`
against `selected.version.public_key` - the index's. `one`, `opened` and
`unclaimed` are all private. So the verify → inspect → unclaimed → begin →
extract → commit sequence has to come out of `one` into an internal core that
both an index install and a local-file install drive.

---

## The package list

Nineteen packages. Twelve are base.

| Package | Base | Depends on | Owns |
|---|---|---|---|
| `musl` | ● | - | `lib/ld-musl-aarch64.so.1`, `usr/lib/libc.so` + crt objects, `usr/include` |
| `busybox` | ● | musl | `bin/busybox` + ~466 applet symlinks |
| `spm` | ● | musl | `usr/bin/spm` |
| `e2fsprogs` | ● | musl | `sbin/resize2fs`, `mke2fs`, `e2fsck`, `debugfs`, …, `etc/mke2fs.conf` |
| `sepia-init` | ● | busybox | `sbin/init`, `etc/inittab`, `etc/init.d/rcS`, `rcK`, `usr/sbin/sepia-gettys` |
| `sepia-base` | ● | busybox | `etc/passwd`, `group`, `shells`, `profile`, `hostname`, `hosts` |
| `sepia-network` | ● | busybox | `usr/sbin/sepia-network`, `usr/share/udhcpc/default.script` |
| `sepia-time` | ● | busybox, sepia-network | `usr/sbin/sepia-time` |
| `sepia-keymaps` | ● | busybox | `usr/bin/sepia-keymap`, `usr/share/keymaps/*.kmap` (167 files) |
| `sepia-firstboot` | ● | busybox, e2fsprogs, sepia-network, sepia-keymaps | `usr/sbin/sepia-firstboot` |
| `tzdata` | ● | - | `usr/share/zoneinfo/**`, `etc/timezone` |
| `linux-modules` | ● | - | `lib/modules/**` |
| `wifi` | | musl | `usr/sbin/wpa_supplicant`, `wpa_cli`, `wpa_passphrase`, libnl |
| `brcm-firmware` | | - | `lib/firmware/brcm/**` |
| `llvm` | | musl | `usr/bin/clang`, `lld`, runtime libraries |
| `make` | | musl | `usr/bin/make` |
| `rust` | | musl, llvm | `rustc`, `cargo` and the toolchain |
| `grit` | | musl | `usr/bin/git` |
| `helix` | | musl, llvm | `usr/bin/hx` and 245 grammars |

Grouping notes worth keeping:

- **`sepia-init` puts the writer and the written file in one package
  deliberately** - `sepia-gettys` and the `inittab` it rewrites move together.
  This is also the package with the unresolved `inittab` question below.
- **`sepia-keymaps` holds both halves**: the tool and its 167 keymaps are one
  subsystem. The generator, the vendored `kmaps.tcz`, the MD5 pin and the
  collision check all stay build-time.
- **`sepia-firstboot` has the most dependency edges, correctly** - it drives
  `sepia-network`, `sepia-keymap`, `sepia-time` and `resize2fs`.
- **`e2fsprogs` stops being optional.** `sepia-firstboot` calls `resize2fs`, so
  as a dependency edge it is required. Today it is `WITH_E2FSPROGS` plus a
  separately cross-built fallback (`Makefile:3832`) - two packages shipping one
  program at two paths.
- **`autoload_drivers` is not its own package.** It lives inside
  `sepia-network`, which is where ROOTFS.md's artefact 19 said it belongs.
- **`spm` itself is base.** A card with a database and no `spm` is worse than
  neither. But `etc/spm/sources.json` is *not* in it - that file carries the
  pinned index key, and a package delivering its own trust root is circular.

---

## What stays the Makefile's

Not everything can be a package, and the reasons are mostly good ones.

| | Why |
|---|---|
| The FHS skeleton | `ROOTFS_DIRS` is 31 directories; 13 top-level names - `boot dev home media mnt opt proc root run srv sys tmp var` - are outside `ROOTS` with per-name reasoning in `layout.rs` |
| The permission block | `Makefile:3852-3855`. Four of those paths are outside `ROOTS` anyway; the two that are not need spm to learn file modes first |
| `/etc/shadow` | Per-build content from `ROOT_PASSWORD_HASH`, mode 0600, rewritten by `sepia-firstboot`. Packaging it puts a password hash inside a signed, publicly published artefact |
| `/etc/network.conf` | 0600 because it holds the wifi PMK. Packaged today it lands 0644 on every card. Moves into `sepia-network` at M6, not before |
| `/etc/resolv.conf` | Rewritten by udhcpc's lease script. After the first lease the digest differs forever |
| `/etc/fstab` | Built from `ROOT_DEVICE`/`BOOT_DEVICE`, a cross-repo contract with `boot`'s `CMDLINE_ROOT`; `sepia-firstboot` appends the swap line |
| `/etc/localtime` | A symlink, and a symlink under `etc/` is explicitly not a config file (`unpack.rs:119-127`) |
| `/etc/os-release`, `/etc/issue`, `/etc/sepia-build-date` | Per-build. `os-release` is a live CI contract - `release.yml:366-384` sources it |
| `/etc/sepiaos-password-unchanged` | A zero-byte marker that a successful `passwd` deletes. `conffile` counts deletion as an edit, so an upgrade would write a permanent `.spmnew` |
| `/etc/spm/sources.json` | Carries the pinned index key. Circular as a package; the build writes it and nothing owns it |
| `/var/lib/sepia` and its markers | `var` is outside `ROOTS` - a package able to write there could forge an install record |
| The card image | The sparse file, the boot MBR, the partition arithmetic, `IMAGE_SIZE_MIB`. None of it is a file on the card |
| The debugfs ownership pass | Not merely surviving - **required**, and it composes correctly by design: `unpack.rs:41-45` states ownership is deliberately not restored |

---

## Milestones

Each leaves the tree building, and each is independently shippable.

**M1 — `spm base`.** The name list, `Error::PartOfBase`, the refusal in
`remove::plan`, the `with_unneeded` skip, the USER-GUIDE and ARCHITECTURE
updates. Ships entirely alone: a card with no base file behaves exactly as
today. **This delivers the headline requirement first**, and nothing else in
the plan blocks it.

**M2 — host build mode.** The cargo feature, the settable root and target, the
local-file install, and the refactor out of `install::one` that both paths then
drive. Nothing consumes it yet; the tree builds and every existing test passes,
because without the feature nothing changes.

**M3 — the four producers that already exist.** Verify musl, busybox,
e2fsprogs and wifi now pack against current spm, publish signed packages, and
settle busybox's staged tree. Add spm's own package. `rootfs` is untouched.

**M4 — the first packaged card.** `rootfs` gains **build step zero**: clone spm
at a pinned tag and `cargo build --features host-mode` into
`build/host-spm/<tag>/`, stamped, with `HOST_SPM=<path>` to skip it the way
`HOST_E2FSPROGS` already works. Then install musl, busybox, e2fsprogs, wifi and
spm into `build/rootfs` in place of four `cp -R` lines and `install_e2fsprogs`.
Overlay, `generate_etc`, the chmod block and `assert_rootfs` all stay. The card
now ships `/var/lib/spm/installed` with five real records. **Biggest visible
win, smallest blast radius** - the chicken-and-egg closes for the payload half.

Note what step zero costs: `cargo` joins the required host tools, and rootfs
builds start depending on the spm *source* rather than an spm *release*, so a
broken commit in spm breaks the rootfs build.

**M5 — the sepia-\* packages.** The six plus tzdata, built from `overlay/`
inside this repo, packed with `spm create` and installed. The overlay copy
shrinks to nothing. `rcS` gains `mkdir -p /var/lib/sepia`. **Decide `inittab`
here.**

**M6 — modes, and `network.conf`.** Create-side mode preservation, then
`etc/network.conf` moves into `sepia-network` at 0600. Until this lands the
"configuration survives an upgrade" benefit is unreachable for the file it
matters most for.

**M7 — the optional payloads and the derived build.** `metadata.json` and a
package target in the remaining five repos; `linux-modules` and
`brcm-firmware`; then `IMAGE_SIZE_MIB` derived from the package set,
`ROOTFS_SIG` keyed on a checked-in package list, `assert_rootfs` shrunk to
cross-package claims. **Deliberately last** - none of it is needed for a card
to boot.

---

## Risks

The ones that are not obvious:

- **An overlay file copied over an installed path corrupts the record silently.**
  The digest is taken during extraction; a later `cp` makes it wrong, and
  `spm verify` reports corruption on a card that built green. No build step
  catches this. All 18 overlay files are inside `ROOTS`. **The ordering rule is
  forced**: every install must precede the overlay copy and `generate_etc` for any
  path a package ships, and the reverse must be guarded.
- **A crash while replacing `usr/lib/libc.so` is not rolled back.**
  `Database::undo` deliberately skips a file a committed record claims, on the
  argument that deleting it would be worse. Packaging musl makes an unbootable
  card a reachable outcome of a routine `spm upgrade`, and nothing distinguishes
  that upgrade from a Helix one.
- **`etc/inittab` diverges from its shipped digest at boot 1**, because
  `sepia-gettys` rewrites everything below the marker on every boot. A genuine
  fix in a new `sepia-init` would land as `.spmnew` and never take effect.
- **Config protection begins at the *second* install.** `install.rs:450-453`
  populates `previously` only from `Change::Replaces`; on a `Change::New` it is
  empty, nothing is diverted, and `unclaimed` raises `FileUnowned`.
- **`spm upgrade` on a freshly flashed card does nothing and exits 0** - it
  reads local indexes only. The honest first-run instruction is
  `spm update && spm upgrade`, and it belongs in the first-boot output.
- **Loss of pinning.** Every payload today is fetched at a pinned tag with a
  recorded digest. spm has no lockfile: resolution takes the newest the index
  offers and nothing records the result.
- **Hard links become full copies.** spm's `Kind` is Directory/File/Symlink
  only. Upstream LLVM ships `clang` and `clang++` as links to one ~100 MiB
  binary, and `assert_rootfs` requires both. Measure before sizing any card.
- **macOS staging is case-insensitive and the card's ext4 is not.** Pre-existing
  exposure - the `comm -12` guards have it too - but this change promotes
  collision detection to *the* safety property.
- **Packaging spm makes its own format migrations self-referential.** A card
  must upgrade spm before any record carrying a new field can be read, and
  `deny_unknown_fields` leaves no graceful degradation.

---

## Open questions

These are decisions, not lookups.

1. **Does the busybox package drop `sbin/init` and the e2fsprogs-shadowed
   applets, or does spm gain a `Replaces` field?** Dropping them means a
   busybox-only card has no `mke2fs`, no `fsck` and no `init`; keeping them
   means `e2fsprogs` and `sepia-init` are uninstallable beside busybox. The
   shadowed set is not a fixed list - `Makefile:4019-4039` computes it with
   `comm -12` over both staged trees, so it moves with both upstreams.

2. **Is musl one package or two?** Its package is a full sysroot: 98
   directories of headers, `libc.a`, the crt objects. As a base package that
   puts the C development sysroot on every card, where `install_toolchain` gates
   exactly those files behind `LLVM_DEP` today. Accept it on a 256 MiB card, or
   split `musl` and `musl-dev`?

3. **Resolved: the host binary is built as build step zero**, from spm's source
   at a pinned tag, with `HOST_SPM=<path>` to skip it. `cargo` therefore joins
   rootfs's required host tools, and rootfs builds come to depend on the spm
   source rather than an spm release. The remaining question is smaller: does CI
   cache `build/host-spm/<tag>/` between runs, or rebuild spm on every job?

4. **What owns `/etc/inittab`?** `sepia-init` owns it and every upgrade leaves a
   dead `.spmnew`; nothing owns it and `sepia-init` generates it at first boot;
   or `sepia-gettys` learns to merge a `.spmnew` it finds. Only you can decide
   whether a machine-generated file should be treated as configuration at all.

5. **Does `/etc/os-release` keep its 19 `SEPIAOS_*` rows** once
   `/var/lib/spm/installed` is queryable? Keeping both means two bills of
   materials that can disagree. Dropping them breaks `release.yml:366-384`
   **silently**, since an unset shell variable expands to an empty string - and
   the replacement would stop CI calling only documented `make` targets.

6. **Does the build pin package versions** - a checked-in list naming name and
   version, installed from files fetched at exactly those versions - or take
   whatever the sibling most recently built? The first keeps the reproducibility
   all ten of today's pinned fetches provide; the second is less machinery and
   drifts.

7. **How is `linux-modules` version-locked to the kernel on the boot
   partition?** spm's `Dependency` is a version floor on a package name and
   cannot express a cross-partition exact-version constraint. Keep the two
   `modules.dep` assertions in `assert_rootfs`, or leave the module tree a plain
   `cp -R` and not a package at all?

8. **Should `spm upgrade` treat base packages as a separate act?** "Can be
   updated" is satisfied by the plain command today, but the half-written-libc
   risk and the single whole-plan space check both argue for grouping on
   base-ness. A UX decision, not a correctness one.
