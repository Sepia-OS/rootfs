# SepiaOS - root filesystem builder
#
# Builds the SepiaOS root filesystem and, eventually, a bootable card image.
# Implemented so far: steps 1 to 6 of README.md - the boot partition, the
# cross-compiler, musl libc, busybox, the kernel modules, and the image.
#
#   make boot-partition         fetch, verify and unpack the boot image
#   make toolchain              fetch the aarch64 cross-compiler
#   make musl                   cross-build musl into build/sysroot
#   make busybox                cross-build busybox against that musl
#   make modules                install the boot kernel's modules into it
#   make rootfs                 stage the FHS tree that becomes partition 2
#   make image                  assemble the bootable card image
#   make help                   every target
#
# No root and no loop mounts, so the same recipes work on macOS and Linux.

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# Make 3.81 (still /usr/bin/make on macOS) compares timestamps only to the
# second and silently reuses stale outputs after a fast edit.
ifeq ($(filter 4.% 5.%,$(MAKE_VERSION)),)
$(error GNU Make >= 4.0 required, found $(MAKE_VERSION). On macOS: brew install make, then run gmake)
endif

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Which channel this rootfs build belongs to. It selects the matching boot
# release: a pre-release build takes the latest pre-release of the boot
# partition, a release build the latest full release. Deliberately literal -
# a release build never picks up a pre-release, and a pre-release build stays
# on the pre-release line even if a full release is published later.
CHANNEL   ?= prerelease

BOOT_REPO ?= Sepia-OS/boot

# Pin a specific boot release, e.g. BOOT_TAG=v0.1.0. Empty means "resolve the
# latest one on CHANNEL", which is resolved once and then cached in
# build/boot/release.env - a build does not silently move to a newer boot
# partition halfway through. `make boot-update` is how you move it.
BOOT_TAG  ?=

DL_DIR    := downloads
BUILD_DIR := build

DL_BOOT   := $(DL_DIR)/boot
BOOT_DIR  := $(BUILD_DIR)/boot

# Resolved release metadata: tag, asset name, download URLs. One API call.
BOOT_ENV  := $(BOOT_DIR)/release.env
# The unpacked boot image. Everything downstream consumes this.
BOOT_IMG  := $(BOOT_DIR)/boot.img
BOOT_CFG  := $(BOOT_DIR)/.config

# Settings that change which release is fetched. Overriding one of these on the
# command line touches no file, so without this signature Make would hand back
# the previously resolved release and report "Nothing to be done".
BOOT_SIG   = $(BOOT_REPO)|$(CHANNEL)|$(BOOT_TAG)|$(GITHUB_API)

GITHUB_API ?= https://api.github.com

SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256")

# --retry-all-errors is not decoration: busybox.net resets connections
# mid-transfer, and plain --retry does not cover a reset once bytes are moving.
CURL := curl --fail --silent --show-error --location \
             --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors

# Validate only for goals that actually need it, so `help` and `clean` work
# with any CHANNEL.
BOOT_GOALS := boot-partition fetch-boot boot-info boot-tag boot-update
ifneq ($(filter $(BOOT_GOALS),$(MAKECMDGOALS)),)
  ifeq ($(filter $(CHANNEL),release prerelease),)
    $(error CHANNEL must be 'release' or 'prerelease', got '$(CHANNEL)')
  endif
endif

# ---------------------------------------------------------------------------
# Host detection and the cross-toolchain it implies
#
# No vendor ships an aarch64-linux-targeting toolchain for both host systems,
# so "the macOS version on macOS, the Linux version on Linux" means two
# different sources - checked, not assumed:
#
#   Arm's own GNU toolchain has macOS builds only for its bare-metal targets
#   (aarch64-none-elf). Every *-none-linux-gnu build is Linux- or Windows-
#   hosted, so it cannot serve a macOS host at all.
#
#   messense/homebrew-macos-cross-toolchains publishes darwin-hosted builds
#   only - there is no Linux-hosted asset in its releases.
#
# The consequence is that the compiler differs by build host, so binaries
# built on macOS and on Linux are not byte-identical. Release builds should
# therefore be cut on Linux, the way the boot repository already does it;
# macOS is the development host.
#
# The GNU-targeting toolchain is chosen deliberately over the musl-targeting
# one messense also ships: step 3 builds musl from source, and a toolchain
# with musl already baked in would make that step a no-op.
# ---------------------------------------------------------------------------

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

ifeq ($(HOST_OS),Darwin)
  TC_VENDOR      := messense
  TC_VERSION_DEF := 15.2.0
  TC_TRIPLE      := aarch64-unknown-linux-gnu
  ifeq ($(HOST_ARCH),arm64)
    TC_HOST := aarch64-darwin
  else ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64-darwin
  endif
  TC_ARCHIVE   = $(TC_TRIPLE)-$(TC_HOST).tar.gz
  TC_URL       = https://github.com/messense/homebrew-macos-cross-toolchains/releases/download/v$(TOOLCHAIN_VERSION)/$(TC_ARCHIVE)
  TC_SUMS_EXT  := .sha256
else ifeq ($(HOST_OS),Linux)
  TC_VENDOR      := arm
  TC_VERSION_DEF := 14.3.rel1
  TC_TRIPLE      := aarch64-none-linux-gnu
  ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64
  else ifeq ($(HOST_ARCH),aarch64)
    TC_HOST := aarch64
  endif
  TC_ARCHIVE   = arm-gnu-toolchain-$(TOOLCHAIN_VERSION)-$(TC_HOST)-$(TC_TRIPLE).tar.xz
  TC_URL       = https://developer.arm.com/-/media/Files/downloads/gnu/$(TOOLCHAIN_VERSION)/binrel/$(TC_ARCHIVE)
  TC_SUMS_EXT  := .sha256asc
endif

TOOLCHAIN_VERSION ?= $(TC_VERSION_DEF)

DL_TC     := $(DL_DIR)/toolchain
# Unpacked next to the tarball rather than under build/: it is an immutable
# upstream artifact, and ~1.5 GiB is too much to re-extract on every `clean`.
TC_DIR     = $(DL_TC)/$(TC_VENDOR)-$(TOOLCHAIN_VERSION)-$(TC_HOST)
TC_STAMP   = $(TC_DIR)/.extracted

# Set CROSS_COMPILE to use a toolchain you already have (Debian's
# gcc-aarch64-linux-gnu, say) and nothing is downloaded.
CROSS_COMPILE ?=
CROSS          = $(or $(CROSS_COMPILE),$(abspath $(TC_DIR))/bin/$(TC_TRIPLE)-)
TOOLCHAIN_DEP  = $(if $(CROSS_COMPILE),,$(TC_STAMP))

TC_GOALS := toolchain toolchain-info
ifneq ($(filter $(TC_GOALS),$(MAKECMDGOALS)),)
  ifeq ($(CROSS_COMPILE),)
    ifeq ($(TC_HOST),)
      $(error No prebuilt aarch64 cross-toolchain is known for $(HOST_OS)/$(HOST_ARCH). Set CROSS_COMPILE to one you have)
    endif
  endif
endif

# ---------------------------------------------------------------------------
# Step 1 - retrieve the boot partition
#
# The boot repository publishes exactly one image asset per release,
# sepiaos-boot-universal-<tag>.img.xz, plus a SHA256SUMS covering it. That one
# card carries the firmware, kernels and device trees for all six boards; the
# Pi firmware picks the right ones at power-on. So there is nothing per-board
# to choose here.
#
# The asset is not addressed by a guessed filename: the release JSON is asked
# for its .img.xz asset, so a rename upstream surfaces as a clear error rather
# than as a 404 on a URL this Makefile invented.
# ---------------------------------------------------------------------------

.PHONY: boot-partition fetch-boot
boot-partition fetch-boot: $(BOOT_IMG) ## Fetch, verify and unpack the boot partition image
	@source $(BOOT_ENV); printf '  READY    boot %s -> %s (%s MiB)\n' \
	   "$$BOOT_TAG" $(BOOT_IMG) "$$(( $$(wc -c < $(BOOT_IMG)) / 1048576 ))"

# Rewritten only when the signature actually changes, so it works as a normal
# prerequisite instead of forcing a re-resolve every run.
.PHONY: FORCE
FORCE:

$(BOOT_CFG): FORCE
	@mkdir -p $(@D)
	@printf '%s\n' '$(BOOT_SIG)' | cmp -s - $@ || printf '%s\n' '$(BOOT_SIG)' > $@

# Resolution happens in the recipe, never at parse time: `make help` must not
# reach the network. Once written this file is only regenerated when the
# signature changes or `boot-update` removes it - deliberately not when the
# Makefile is edited, or an unrelated edit could silently move "latest" onto
# a newer release mid-project.
#
# GITHUB_TOKEN is honoured when set - the unauthenticated API allows 60
# requests an hour per IP, which CI can exhaust.
#
# --fail is deliberately absent from the API calls: it collapses "no such
# release" and "the network is down" into one non-zero exit, and reporting the
# wrong one of those sends you looking in the wrong place. The HTTP status is
# read instead, so a transport failure still aborts with curl's own message.
#
# The release body is also mined for the Raspberry Pi firmware tag the boot
# partition was built from - it states it verbatim as a table row,
# `| Raspberry Pi firmware | 1.20260521 |`. Step 5 has to fetch the kernel
# modules from exactly that tag, and this is the release whose kernels they
# have to match, so it is read here rather than guessed or pinned separately.
# A release that does not name one leaves it empty; step 5 says so and asks
# for FIRMWARE_TAG rather than failing step 1, which does not need it.
$(BOOT_ENV): $(BOOT_CFG)
	@mkdir -p $(@D)
	@command -v jq >/dev/null 2>&1 || { \
	  echo "jq is required to read the GitHub release metadata." >&2; \
	  echo "macOS 13+ ships it at /usr/bin/jq; otherwise: brew install jq / apt-get install jq" >&2; \
	  exit 1; }
	@echo "  RESOLVE  $(BOOT_REPO) ($(if $(BOOT_TAG),pinned $(BOOT_TAG),latest $(CHANNEL)))"
	@api="$(GITHUB_API)/repos/$(BOOT_REPO)"; \
	 hdr=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28'); \
	 if [ -n "$${GITHUB_TOKEN:-}" ]; then hdr+=(-H "Authorization: Bearer $$GITHUB_TOKEN"); fi; \
	 body=$$(mktemp); trap 'rm -f "$$body"' EXIT; \
	 get() { curl --silent --show-error --location \
	              --retry 3 --retry-delay 2 --retry-connrefused \
	              "$${hdr[@]}" -o "$$body" -w '%{http_code}' "$$1"; }; \
	 refuse() { \
	   case "$$1" in \
	     403|429) echo "GitHub API rate limit hit (HTTP $$1). Set GITHUB_TOKEN to raise it." >&2;; \
	     *) echo "GitHub API returned HTTP $$1 for $$2" >&2;; \
	   esac; exit 1; }; \
	 if [ -n '$(BOOT_TAG)' ]; then \
	   code=$$(get "$$api/releases/tags/$(BOOT_TAG)"); \
	   if [ "$$code" = 404 ]; then \
	     echo "$(BOOT_REPO) has no release tagged '$(BOOT_TAG)'." >&2; exit 1; fi; \
	   [ "$$code" = 200 ] || refuse "$$code" "release $(BOOT_TAG)"; \
	   rel=$$(cat "$$body"); \
	 elif [ '$(CHANNEL)' = release ]; then \
	   code=$$(get "$$api/releases/latest"); \
	   if [ "$$code" = 404 ]; then \
	     echo "$(BOOT_REPO) has no full release yet. Build against a pre-release" >&2; \
	     echo "with CHANNEL=prerelease, or pin one with BOOT_TAG=<tag>." >&2; exit 1; fi; \
	   [ "$$code" = 200 ] || refuse "$$code" "the latest release"; \
	   rel=$$(cat "$$body"); \
	 else \
	   code=$$(get "$$api/releases?per_page=100"); \
	   [ "$$code" = 200 ] || refuse "$$code" "the release list"; \
	   rel=$$(jq -c '[.[]|select(.draft==false and .prerelease==true)]|sort_by(.published_at)|last' "$$body"); \
	   if [ -z "$$rel" ] || [ "$$rel" = null ]; then \
	     echo "$(BOOT_REPO) has no published pre-release." >&2; exit 1; fi; \
	 fi; \
	 tag=$$(jq -r '.tag_name // empty' <<<"$$rel"); \
	 img=$$(jq -r '[.assets[] | select(.name | endswith(".img.xz"))] | first | .name // empty' <<<"$$rel"); \
	 imgurl=$$(jq -r '[.assets[] | select(.name | endswith(".img.xz"))] | first | .browser_download_url // empty' <<<"$$rel"); \
	 sumurl=$$(jq -r '[.assets[] | select(.name == "SHA256SUMS")] | first | .browser_download_url // empty' <<<"$$rel"); \
	 if [ -z "$$img" ]; then \
	   echo "Release $$tag carries no .img.xz asset - was it renamed?" >&2; exit 1; fi; \
	 if [ -z "$$sumurl" ]; then \
	   echo "Release $$tag carries no SHA256SUMS - refusing to use an unverifiable image." >&2; exit 1; fi; \
	 for v in "$$tag" "$$img"; do \
	   [[ "$$v" =~ ^[A-Za-z0-9._+-]+$$ ]] || { echo "Refusing '$$v': not a plain tag/filename." >&2; exit 1; }; \
	 done; \
	 for v in "$$imgurl" "$$sumurl"; do \
	   [[ "$$v" == https://* ]] || { echo "Refusing non-https URL '$$v'." >&2; exit 1; }; \
	 done; \
	 fw=$$(jq -r '.body // ""' <<<"$$rel" \
	       | sed -n 's/.*Raspberry Pi firmware[^|]*| *`\([^`]*\)`.*/\1/p' | head -1); \
	 [[ "$$fw" =~ ^[A-Za-z0-9._-]+$$ ]] || fw=''; \
	 { echo "BOOT_TAG='$$tag'"; \
	   echo "BOOT_IMAGE='$$img'"; \
	   echo "BOOT_IMAGE_URL='$$imgurl'"; \
	   echo "BOOT_SUMS_URL='$$sumurl'"; \
	   echo "BOOT_FIRMWARE_TAG='$$fw'"; } > $@.part
	@mv -f $@.part $@
	@sed -n "s/^BOOT_TAG='\(.*\)'/  BOOT     \1/p" $@

# Downloads are keyed by tag and survive `clean`: release assets are immutable,
# so a tag that is already on disk is never refetched. The .part/mv pair keeps
# an interrupted transfer from looking like a good file.
#
# Makefile is a prerequisite of the things that are *built* but not of the
# things that are *resolved*: editing a recipe should rebuild, but it should
# never re-run a "latest" lookup and quietly move the version. The toolchain
# is left out of even this - its version is part of its path, and a 600 MiB
# re-extract on every edit would be absurd.
$(BOOT_IMG): $(BOOT_ENV) Makefile
	@command -v xz >/dev/null 2>&1 || { \
	  echo "xz is required to unpack the boot image (brew install xz / apt-get install xz-utils)" >&2; \
	  exit 1; }
	@mkdir -p $(@D)
	@source $(BOOT_ENV); \
	 d=$(DL_BOOT)/$$BOOT_TAG; mkdir -p "$$d"; \
	 if [ ! -f "$$d/$$BOOT_IMAGE" ]; then \
	   echo "  FETCH    $$BOOT_IMAGE"; \
	   $(CURL) -o "$$d/$$BOOT_IMAGE.part" "$$BOOT_IMAGE_URL"; \
	   mv -f "$$d/$$BOOT_IMAGE.part" "$$d/$$BOOT_IMAGE"; \
	 fi; \
	 if [ ! -f "$$d/SHA256SUMS" ]; then \
	   echo "  FETCH    SHA256SUMS"; \
	   $(CURL) -o "$$d/SHA256SUMS.part" "$$BOOT_SUMS_URL"; \
	   mv -f "$$d/SHA256SUMS.part" "$$d/SHA256SUMS"; \
	 fi; \
	 echo "  VERIFY   $$BOOT_IMAGE"; \
	 ( cd "$$d" && grep -F "$$BOOT_IMAGE" SHA256SUMS | $(SHA256) --check --quiet - ) || { \
	   echo "  FAIL     $$BOOT_IMAGE does not match SHA256SUMS; delete $$d and retry" >&2; exit 1; }; \
	 echo "  UNPACK   $$BOOT_IMAGE"; \
	 xz --decompress --stdout "$$d/$$BOOT_IMAGE" > $@.part
	@mv -f $@.part $@
	@$(call assert_boot_layout,$@)

# Cheap sanity check that what came out of the archive really is a Pi card:
# MBR byte 450 is partition 1's type, and the boot partition is FAT32 LBA
# (0x0c). Wrong here means the rootfs would later be appended to something
# that is not a boot partition at all.
define assert_boot_layout
	t=$$(dd if=$(1) bs=1 skip=450 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'); \
	[ "$$t" = "0c" ] || { \
	  echo "  FAIL     $(1) partition 1 is type 0x$$t, expected 0x0c (FAT32 LBA)" >&2; exit 1; }
endef

.PHONY: boot-update
boot-update: ## Re-resolve the latest boot release on CHANNEL and refetch
	@rm -f $(BOOT_ENV)
	@$(MAKE) --no-print-directory boot-partition

.PHONY: boot-tag
boot-tag: $(BOOT_ENV) ## Print the boot release tag in use
	@source $(BOOT_ENV); echo "$$BOOT_TAG"

# The start sector and length of partition 1 are what the image-assembly step
# needs in order to append the rootfs as partition 2, so they are reported
# rather than left to be rediscovered. Both are 32-bit little-endian fields in
# the MBR entry at offset 446: LBA start at 454, sector count at 458.
.PHONY: boot-info
boot-info: $(BOOT_IMG) ## Show the fetched boot release and its partition layout
	@source $(BOOT_ENV); \
	 echo "  repo     $(BOOT_REPO)"; \
	 echo "  channel  $(CHANNEL)$(if $(BOOT_TAG), (pinned))"; \
	 echo "  tag      $$BOOT_TAG"; \
	 echo "  asset    $$BOOT_IMAGE"; \
	 echo "  firmware $${BOOT_FIRMWARE_TAG:-<not named in the release notes>}"
	@echo "  image    $(BOOT_IMG) ($$(( $$(wc -c < $(BOOT_IMG)) / 1048576 )) MiB)"
	@$(SHA256) $(BOOT_IMG) | sed 's/^/  sha256   /'
	@le32() { od -An -tu4 -j $$1 -N4 $(BOOT_IMG) | tr -d ' '; }; \
	 start=$$(le32 454); count=$$(le32 458); \
	 echo "  part 1   FAT32 LBA, start sector $$start ($$(( start * 512 / 1048576 )) MiB), $$count sectors ($$(( count * 512 / 1048576 )) MiB)"; \
	 echo "  part 2   free from sector $$(( start + count )) - where the rootfs goes"

# ---------------------------------------------------------------------------
# Step 2 - retrieve the aarch64 cross-compiler
#
# Everything here is pinned, so unlike the boot release nothing has to be
# resolved over the network and the paths are known while the Makefile is
# still being read. Both vendors publish a plain sha256sum-format sidecar next
# to the tarball, so the download is checked against upstream's own digest
# rather than against a checksum committed here.
# ---------------------------------------------------------------------------

.PHONY: toolchain
toolchain: $(TOOLCHAIN_DEP) ## Fetch the aarch64 cross-compiler for this host
	@$(call assert_cross_compiler)
	@echo "  READY    $(if $(CROSS_COMPILE),CROSS_COMPILE -> $(CROSS)gcc,$(TC_VENDOR) $(TOOLCHAIN_VERSION) -> $(TC_DIR))"

# Nothing under $(TC_DIR) is a prerequisite of the stamp: release archives are
# immutable, so once a version is unpacked it is never unpacked again. Change
# TOOLCHAIN_VERSION and the path changes with it.
$(TC_STAMP):
	@command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
	@mkdir -p $(DL_TC)
	@if [ ! -f $(DL_TC)/$(TC_ARCHIVE) ]; then \
	   echo "  FETCH    $(TC_ARCHIVE) (a few hundred MiB)"; \
	   $(CURL) -o $(DL_TC)/$(TC_ARCHIVE).part "$(TC_URL)"; \
	   mv -f $(DL_TC)/$(TC_ARCHIVE).part $(DL_TC)/$(TC_ARCHIVE); \
	 fi
	@if [ ! -f $(DL_TC)/$(TC_ARCHIVE)$(TC_SUMS_EXT) ]; then \
	   $(CURL) -o $(DL_TC)/$(TC_ARCHIVE)$(TC_SUMS_EXT).part "$(TC_URL)$(TC_SUMS_EXT)"; \
	   mv -f $(DL_TC)/$(TC_ARCHIVE)$(TC_SUMS_EXT).part $(DL_TC)/$(TC_ARCHIVE)$(TC_SUMS_EXT); \
	 fi
	@echo "  VERIFY   $(TC_ARCHIVE)"
	@( cd $(DL_TC) && $(SHA256) --check --quiet $(TC_ARCHIVE)$(TC_SUMS_EXT) ) || { \
	   echo "  FAIL     $(TC_ARCHIVE) does not match upstream's digest; delete $(DL_TC) and retry" >&2; \
	   exit 1; }
	@echo "  UNPACK   $(TC_ARCHIVE) -> $(TC_DIR)"
	@rm -rf $(TC_DIR)
	@mkdir -p $(TC_DIR)
	@tar -xf $(DL_TC)/$(TC_ARCHIVE) -C $(TC_DIR) --strip-components=1
	@touch $@
	@$(call assert_cross_compiler)

# A cross-compiler for the wrong host arch extracts perfectly happily and then
# fails to exec, and one for the wrong target compiles perfectly happily and
# produces host binaries. -dumpmachine catches both in one cheap call.
define assert_cross_compiler
	command -v $(CROSS)gcc >/dev/null 2>&1 || { \
	  echo "  FAIL     no $(CROSS)gcc" >&2; exit 1; }; \
	m=$$($(CROSS)gcc -dumpmachine) || { \
	  echo "  FAIL     $(CROSS)gcc will not run on $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1; }; \
	case "$$m" in \
	  aarch64-*linux*) ;; \
	  *) echo "  FAIL     $(CROSS)gcc targets $$m, not aarch64 linux" >&2; exit 1;; \
	esac
endef

.PHONY: toolchain-info
toolchain-info: $(TOOLCHAIN_DEP) ## Show the cross-compiler in use
	@echo "  host     $(HOST_OS) $(HOST_ARCH)"
	@echo "  source   $(if $(CROSS_COMPILE),CROSS_COMPILE override,$(TC_VENDOR) $(TOOLCHAIN_VERSION))"
	@echo "  prefix   $(CROSS)"
	@echo "  target   $$($(CROSS)gcc -dumpmachine)"
	@$(CROSS)gcc --version | sed -n '1s/^/  gcc      /p'
	@$(CROSS)ld --version | sed -n '1s/^/  ld       /p'

# ---------------------------------------------------------------------------
# Step 3 - retrieve and build musl libc
#
# musl publishes no checksum sidecar, only a detached GPG signature, so the
# digest is recorded under checksums/ the first time a version is fetched and
# checked against that record every time after - the same trust-on-first-use
# manifest ../boot keeps for the Raspberry Pi firmware. `musl-verify-sig` is
# the stronger check and stays opt-in, because it needs gpg and the
# maintainer's key from a keyserver.
#
# Installed with DESTDIR into build/sysroot rather than with an absolute
# --prefix. That keeps the tree correct as a rootfs - the ld-musl symlink
# points at /usr/lib/libc.so, which is where it really will be on the target -
# and step 4 builds against it with --sysroot instead.
#
# Only the directories musl owns are cleared before installing, not the whole
# sysroot: step 4 installs busybox into the same tree, and an rm -rf here would
# quietly delete it whenever musl alone was rebuilt.
#
# --disable-wrapper because the sysroot doubles as the source of the shipped
# rootfs and SepiaOS is not shipping a compiler. Without it musl installs
# usr/bin/musl-gcc and usr/lib/musl-gcc.specs; the wrapper would be the wrong
# tool here anyway, since its specs bake in whatever absolute paths configure
# saw and a staged install points them at the build host's directories.
# ---------------------------------------------------------------------------

# Empty means "latest release", resolved from the git tags rather than by
# scraping the release index, and then cached like the boot release is.
MUSL_VERSION ?=
MUSL_SIG      = $(MUSL_VERSION)|$(MUSL_GIT)|$(MUSL_BASE)

MUSL_GIT  := https://git.musl-libc.org/git/musl
MUSL_BASE := https://musl.libc.org/releases

DL_MUSL       := $(DL_DIR)/musl
MUSL_DIR      := $(BUILD_DIR)/musl
MUSL_ENV      := $(MUSL_DIR)/version.env
MUSL_CFG      := $(MUSL_DIR)/.config
MUSL_UNPACKED := $(MUSL_DIR)/.unpacked
MUSL_STAMP    := $(MUSL_DIR)/.installed

# Where musl lands, and what steps 4 and 5 consume.
SYSROOT   := $(BUILD_DIR)/sysroot
CHECKSUMS := checksums

JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

.PHONY: musl
musl: $(MUSL_STAMP) ## Fetch and cross-build musl libc, static and shared
	@source $(MUSL_ENV); printf '  READY    musl %s -> %s (static + shared)\n' \
	   "$$MUSL_VER" $(SYSROOT)

$(MUSL_CFG): FORCE
	@mkdir -p $(@D)
	@printf '%s\n' '$(MUSL_SIG)' | cmp -s - $@ || printf '%s\n' '$(MUSL_SIG)' > $@

# --refs drops the ^{} peeled entries; sort -V is what keeps 1.2.10 above
# 1.2.6, which a plain sort would get backwards.
$(MUSL_ENV): $(MUSL_CFG)
	@mkdir -p $(@D)
	@echo "  RESOLVE  musl ($(if $(MUSL_VERSION),pinned $(MUSL_VERSION),latest release))"
	@if [ -n '$(MUSL_VERSION)' ]; then v='$(MUSL_VERSION)'; else \
	   v=$$(git ls-remote --tags --refs $(MUSL_GIT) \
	        | sed 's|.*refs/tags/v||' \
	        | grep -E '^[0-9]+(\.[0-9]+)+$$' \
	        | sort -V | tail -1); \
	   [ -n "$$v" ] || { echo "Could not read the tag list from $(MUSL_GIT)." >&2; exit 1; }; \
	 fi; \
	 [[ "$$v" =~ ^[0-9][0-9A-Za-z._-]*$$ ]] || { echo "Refusing musl version '$$v'." >&2; exit 1; }; \
	 printf "MUSL_VER='%s'\n" "$$v" > $@.part
	@mv -f $@.part $@
	@sed -n "s/^MUSL_VER='\(.*\)'/  MUSL     \1/p" $@

$(MUSL_UNPACKED): $(MUSL_ENV)
	@mkdir -p $(DL_MUSL) $(CHECKSUMS) $(MUSL_DIR)
	@source $(MUSL_ENV); \
	 t=musl-$$MUSL_VER.tar.gz; \
	 if [ ! -f $(DL_MUSL)/$$t ]; then \
	   echo "  FETCH    $$t"; \
	   $(CURL) -o $(DL_MUSL)/$$t.part "$(MUSL_BASE)/$$t" || { \
	     echo "  FAIL     could not fetch $(MUSL_BASE)/$$t - not published, or the" >&2; \
	     echo "           transfer failed; curl said why above" >&2; exit 1; }; \
	   mv -f $(DL_MUSL)/$$t.part $(DL_MUSL)/$$t; \
	 fi; \
	 if [ ! -f $(DL_MUSL)/$$t.asc ]; then \
	   $(CURL) -o $(DL_MUSL)/$$t.asc.part "$(MUSL_BASE)/$$t.asc"; \
	   mv -f $(DL_MUSL)/$$t.asc.part $(DL_MUSL)/$$t.asc; \
	 fi; \
	 m=$(abspath $(CHECKSUMS))/musl-$$MUSL_VER.sha256; \
	 if [ -f "$$m" ]; then \
	   echo "  VERIFY   $$t"; \
	   ( cd $(DL_MUSL) && $(SHA256) --check --quiet "$$m" ) || { \
	     echo "  FAIL     $$t does not match $$m; delete $(DL_MUSL)/$$t and retry" >&2; exit 1; }; \
	 else \
	   ( cd $(DL_MUSL) && $(SHA256) "$$t" ) > "$$m"; \
	   echo "  RECORD   $(CHECKSUMS)/musl-$$MUSL_VER.sha256 - first fetch of this version, commit it"; \
	 fi; \
	 echo "  UNPACK   $$t"; \
	 rm -rf $(MUSL_DIR)/musl-$$MUSL_VER; \
	 tar -xf $(DL_MUSL)/$$t -C $(MUSL_DIR)
	@touch $@

# configure and make are noisy and only interesting when they fail, so the
# output goes to a log and the tail of it is what surfaces on an error.
$(MUSL_STAMP): $(MUSL_UNPACKED) $(TOOLCHAIN_DEP) Makefile
	@source $(MUSL_ENV); s=$(MUSL_DIR)/musl-$$MUSL_VER; \
	 echo "  CONFIG   musl $$MUSL_VER (static + shared)"; \
	 ( cd $$s && ./configure --prefix=/usr --syslibdir=/lib \
	       --enable-static --enable-shared --disable-wrapper \
	       CROSS_COMPILE=$(CROSS) ) > $$s/configure.log 2>&1 || { \
	   tail -20 $$s/configure.log >&2; \
	   echo "  FAIL     configure (full log: $$s/configure.log)" >&2; exit 1; }; \
	 echo "  BUILD    musl $$MUSL_VER (-j$(JOBS))"; \
	 $(MAKE) --no-print-directory -C $$s -j$(JOBS) > $$s/build.log 2>&1 || { \
	   tail -30 $$s/build.log >&2; \
	   echo "  FAIL     build (full log: $$s/build.log)" >&2; exit 1; }; \
	 echo "  INSTALL  -> $(SYSROOT)"; \
	 rm -rf $(SYSROOT)/usr/include $(SYSROOT)/usr/lib $(SYSROOT)/lib/ld-musl-*; \
	 $(MAKE) --no-print-directory -C $$s install DESTDIR=$(abspath $(SYSROOT)) \
	   >> $$s/build.log 2>&1 || { \
	   tail -30 $$s/build.log >&2; \
	   echo "  FAIL     install (full log: $$s/build.log)" >&2; exit 1; }
	@$(call install_uapi_headers)
	@$(call assert_musl)
	@touch $@

# Both linkages are what the README asks for, so both are actually exercised
# rather than inferred from the presence of libc.a and libc.so. readelf comes
# from the cross-toolchain itself, so this needs nothing that is not already
# a dependency - `file` is absent from a slim Debian image.
define assert_musl
	set -e; \
	d=$(MUSL_DIR)/.check; rm -rf $$d; mkdir -p $$d; \
	printf '#include <stdio.h>\nint main(void){puts("sepia");return 0;}\n' > $$d/t.c; \
	$(CROSS)gcc --sysroot=$(abspath $(SYSROOT)) -static -O2 -o $$d/t.static $$d/t.c \
	  || { echo "  FAIL     nothing links statically against $(SYSROOT)" >&2; exit 1; }; \
	$(CROSS)gcc --sysroot=$(abspath $(SYSROOT)) -O2 \
	    -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1 -o $$d/t.dyn $$d/t.c \
	  || { echo "  FAIL     nothing links dynamically against $(SYSROOT)" >&2; exit 1; }; \
	$(CROSS)readelf -h $$d/t.static | grep -q AArch64 \
	  || { echo "  FAIL     the static test binary is not aarch64" >&2; exit 1; }; \
	$(CROSS)readelf -l $$d/t.dyn | grep -q ld-musl-aarch64.so.1 \
	  || { echo "  FAIL     the dynamic test binary does not use the musl loader" >&2; exit 1; }
endef

# musl installs libc headers and nothing else, which is not a usable sysroot:
# anything that talks to the kernel needs the Linux UAPI headers too, and
# busybox in step 4 wants linux/kd.h before it will even compile. They are
# taken from the cross-toolchain's own sysroot - the same toolchain that
# supplies libgcc - rather than downloaded separately, so this costs nothing
# and cannot drift from the compiler.
define install_uapi_headers
	set -e; \
	k=$$($(CROSS)gcc -print-sysroot)/usr/include; \
	[ -d "$$k" ] || { echo "  FAIL     $(CROSS)gcc has no sysroot to take UAPI headers from" >&2; exit 1; }; \
	for d in linux asm asm-generic mtd rdma sound video drm misc scsi xen; do \
	  if [ -d "$$k/$$d" ]; then cp -R "$$k/$$d" $(abspath $(SYSROOT))/usr/include/; fi; \
	done; \
	[ -f $(abspath $(SYSROOT))/usr/include/linux/kd.h ] \
	  || { echo "  FAIL     no Linux UAPI headers landed in $(SYSROOT)" >&2; exit 1; }
endef

.PHONY: musl-update
musl-update: ## Re-resolve the latest musl release and rebuild
	@rm -f $(MUSL_ENV)
	@$(MAKE) --no-print-directory musl

.PHONY: musl-check
musl-check: $(MUSL_STAMP) ## Link a test program against the sysroot, both ways
	@$(call assert_musl)
	@echo "  OK       static and dynamic both link against $(SYSROOT)"

.PHONY: musl-info
musl-info: $(MUSL_STAMP) ## Show the musl build and what it installed
	@source $(MUSL_ENV); echo "  version  musl $$MUSL_VER"
	@echo "  sysroot  $(SYSROOT)"
	@ls -l $(SYSROOT)/lib/ld-musl-aarch64.so.1 | sed 's/^/  loader   /'
	@printf '  static   %s (%s KiB)\n' $(SYSROOT)/usr/lib/libc.a "$$(( $$(wc -c < $(SYSROOT)/usr/lib/libc.a) / 1024 ))"
	@printf '  shared   %s (%s KiB)\n' $(SYSROOT)/usr/lib/libc.so "$$(( $$(wc -c < $(SYSROOT)/usr/lib/libc.so) / 1024 ))"
	@$(CROSS)readelf -h $(SYSROOT)/usr/lib/libc.so | sed -n 's/^ *Machine: *\(.*\)/  machine  \1/p'

# Opt-in: needs gpg and fetches Rich Felker's key from a keyserver. The
# fingerprint is pinned here so that importing it cannot substitute another.
MUSL_KEY := 836489290BB6B70F99FFDA0556BCDB593020450F

.PHONY: musl-verify-sig
musl-verify-sig: $(MUSL_UNPACKED) ## Check the musl tarball's GPG signature (needs gpg)
	@command -v gpg >/dev/null 2>&1 || { echo "gpg is not installed" >&2; exit 1; }
	@source $(MUSL_ENV); t=musl-$$MUSL_VER.tar.gz; \
	 gpg --list-keys $(MUSL_KEY) >/dev/null 2>&1 \
	   || gpg --recv-keys $(MUSL_KEY) \
	   || { echo "Could not fetch key $(MUSL_KEY) from a keyserver." >&2; exit 1; }; \
	 gpg --verify $(DL_MUSL)/$$t.asc $(DL_MUSL)/$$t

# ---------------------------------------------------------------------------
# Step 4 - retrieve and build busybox
#
# busybox publishes a plain .sha256 next to every tarball, so unlike musl this
# download is checked against upstream's own digest and there is no
# trust-on-first-use record to keep.
#
# Dynamic against the musl from step 3, which is what the README asks for and
# what the assertions actually prove rather than assume: an ELF interpreter of
# /lib/ld-musl-aarch64.so.1 and a NEEDED entry for libc.so. A static build
# would have neither.
#
# defconfig compiles clean against musl - checked, not hoped for; no applets
# had to be turned off. The flags go in through CONFIG_EXTRA_CFLAGS and
# CONFIG_EXTRA_LDFLAGS, which is where busybox's Makefile.flags picks up
# anything extra.
# ---------------------------------------------------------------------------

BUSYBOX_VERSION ?=

# Overridable because busybox.net goes down for minutes at a time and resets
# connections when it is up: https://sources.buildroot.net/busybox serves the
# same tarballs by name. That mirror carries no .sha256 of its own, so the
# digest is always taken from the canonical site and a mirrored tarball still
# has to match it. Resolving "latest" needs the canonical index either way, so
# a mirror is only useful together with BUSYBOX_VERSION.
BUSYBOX_BASE      ?= https://busybox.net/downloads
BUSYBOX_SUMS_BASE ?= https://busybox.net/downloads

BB_SIG        = $(BUSYBOX_VERSION)|$(BUSYBOX_BASE)|$(BUSYBOX_SUMS_BASE)

DL_BB      := $(DL_DIR)/busybox
BB_DIR     := $(BUILD_DIR)/busybox
BB_ENV     := $(BB_DIR)/version.env
# Not called .config: busybox keeps its own .config one level down, in the
# unpacked source tree, and two files of that name would read as one thing.
BB_REQUEST := $(BB_DIR)/.version-request
BB_UNPACKED := $(BB_DIR)/.unpacked
BB_CONFIGURED := $(BB_DIR)/.configured
BB_BIN     := $(BB_DIR)/busybox
BB_LINKS   := $(BB_DIR)/busybox.links

BB_SYSROOT  = $(abspath $(SYSROOT))
BB_CFLAGS   = --sysroot=$(BB_SYSROOT)
BB_LDFLAGS  = --sysroot=$(BB_SYSROOT) -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1
BB_MAKE     = $(MAKE) --no-print-directory -C $$s ARCH=arm64 CROSS_COMPILE=$(CROSS)

.PHONY: busybox
busybox: $(BB_BIN) ## Fetch, cross-build and install busybox into the sysroot
	@source $(BB_ENV); printf '  READY    busybox %s -> %s (%s KiB, %s applets in %s)\n' \
	   "$$BB_VER" $(BB_BIN) "$$(( $$(wc -c < $(BB_BIN)) / 1024 ))" \
	   "$$(wc -l < $(BB_LINKS) | tr -d ' ')" $(SYSROOT)

$(BB_REQUEST): FORCE
	@mkdir -p $(@D)
	@printf '%s\n' '$(BB_SIG)' | cmp -s - $@ || printf '%s\n' '$(BB_SIG)' > $@

# The release index is the list of what can actually be downloaded, which is
# the question being asked; git.busybox.net would answer a slightly different
# one and lives on the same host anyway. sort -uV keeps 1.38.0 above 1.9.2,
# which a plain sort gets spectacularly wrong.
$(BB_ENV): $(BB_REQUEST)
	@mkdir -p $(@D)
	@echo "  RESOLVE  busybox ($(if $(BUSYBOX_VERSION),pinned $(BUSYBOX_VERSION),latest release))"
	@if [ -n '$(BUSYBOX_VERSION)' ]; then v='$(BUSYBOX_VERSION)'; else \
	   v=$$($(CURL) "$(BUSYBOX_BASE)/" \
	        | grep -oE 'busybox-[0-9][0-9.]*\.tar\.bz2' \
	        | sed 's/^busybox-//; s/\.tar\.bz2$$//' \
	        | grep -E '^[0-9]+(\.[0-9]+)+$$' \
	        | sort -uV | tail -1); \
	   [ -n "$$v" ] || { echo "Could not read the release list at $(BUSYBOX_BASE)/." >&2; exit 1; }; \
	 fi; \
	 [[ "$$v" =~ ^[0-9][0-9A-Za-z._-]*$$ ]] || { echo "Refusing busybox version '$$v'." >&2; exit 1; }; \
	 printf "BB_VER='%s'\n" "$$v" > $@.part
	@mv -f $@.part $@
	@sed -n "s/^BB_VER='\(.*\)'/  BUSYBOX  \1/p" $@

$(BB_UNPACKED): $(BB_ENV)
	@mkdir -p $(DL_BB) $(BB_DIR)
	@source $(BB_ENV); t=busybox-$$BB_VER.tar.bz2; \
	 if [ ! -f $(DL_BB)/$$t ]; then \
	   echo "  FETCH    $$t"; \
	   $(CURL) -o $(DL_BB)/$$t.part "$(BUSYBOX_BASE)/$$t" || { \
	     echo "  FAIL     could not fetch $(BUSYBOX_BASE)/$$t - not published, or the" >&2; \
	     echo "           transfer failed; curl said why above" >&2; exit 1; }; \
	   mv -f $(DL_BB)/$$t.part $(DL_BB)/$$t; \
	 fi; \
	 if [ ! -f $(DL_BB)/$$t.sha256 ]; then \
	   $(CURL) -o $(DL_BB)/$$t.sha256.part "$(BUSYBOX_SUMS_BASE)/$$t.sha256" || { \
	     echo "  FAIL     no upstream digest for $$t - refusing an unverifiable tarball" >&2; exit 1; }; \
	   mv -f $(DL_BB)/$$t.sha256.part $(DL_BB)/$$t.sha256; \
	 fi; \
	 echo "  VERIFY   $$t"; \
	 ( cd $(DL_BB) && $(SHA256) --check --quiet $$t.sha256 ) || { \
	   echo "  FAIL     $$t does not match upstream's digest; delete $(DL_BB)/$$t and retry" >&2; exit 1; }; \
	 echo "  UNPACK   $$t"; \
	 rm -rf $(BB_DIR)/busybox-$$BB_VER; \
	 tar -C $(BB_DIR) -xf $(DL_BB)/$$t
	@touch $@

# Configuring is separate from compiling on purpose. defconfig rewrites
# .config from scratch, which invalidates every object file, so folding it
# into the build rule turned every `make busybox` into a full rebuild - and,
# once nothing upstream of it had changed, into no build at all.
#
# oldconfig reads from /dev/null rather than from `yes ""`: under pipefail a
# `yes` killed by SIGPIPE fails the whole recipe. Nothing is asked anyway -
# editing two string options introduces no new symbols.
$(BB_CONFIGURED): $(BB_UNPACKED) $(MUSL_STAMP) $(TOOLCHAIN_DEP) Makefile
	@source $(BB_ENV); s=$(BB_DIR)/busybox-$$BB_VER; \
	 echo "  CONFIG   busybox $$BB_VER (dynamic, against $(SYSROOT))"; \
	 $(BB_MAKE) defconfig > $$s/config.log 2>&1 || { \
	   tail -20 $$s/config.log >&2; echo "  FAIL     defconfig" >&2; exit 1; }; \
	 sed -i.bak \
	     -e 's|^CONFIG_EXTRA_CFLAGS=.*|CONFIG_EXTRA_CFLAGS="$(BB_CFLAGS)"|' \
	     -e 's|^CONFIG_EXTRA_LDFLAGS=.*|CONFIG_EXTRA_LDFLAGS="$(BB_LDFLAGS)"|' \
	     $$s/.config; \
	 grep -q '^# CONFIG_STATIC is not set' $$s/.config || { \
	   echo "  FAIL     CONFIG_STATIC is set; the README asks for a dynamic executable" >&2; exit 1; }; \
	 $(BB_MAKE) oldconfig >> $$s/config.log 2>&1 < /dev/null || { \
	   tail -20 $$s/config.log >&2; echo "  FAIL     oldconfig" >&2; exit 1; }
	@touch $@

# FORCE, so `make busybox` always runs the compiler. busybox's own kbuild is
# the thing that decides what to recompile - about three seconds when nothing
# has changed - and it is a better judge of that than a stamp file here, which
# cannot see an edit inside the source tree.
#
# The result is only copied out when it actually differs, so an unchanged
# build does not bump this file's timestamp and set everything downstream
# rebuilding.
$(BB_BIN): $(BB_CONFIGURED) FORCE
	@source $(BB_ENV); s=$(BB_DIR)/busybox-$$BB_VER; \
	 echo "  BUILD    busybox $$BB_VER (-j$(JOBS))"; \
	 $(BB_MAKE) -j$(JOBS) > $$s/build.log 2>&1 || { \
	   tail -30 $$s/build.log >&2; \
	   echo "  FAIL     build (full log: $$s/build.log)" >&2; exit 1; }; \
	 $(BB_MAKE) busybox.links >> $$s/build.log 2>&1 || { \
	   tail -20 $$s/build.log >&2; echo "  FAIL     busybox.links" >&2; exit 1; }; \
	 cmp -s $$s/busybox $(BB_BIN) || cp $$s/busybox $(BB_BIN); \
	 cmp -s $$s/busybox.links $(BB_LINKS) || cp $$s/busybox.links $(BB_LINKS); \
	 echo "  INSTALL  -> $(SYSROOT)"; \
	 $(BB_MAKE) install CONFIG_PREFIX=$(abspath $(SYSROOT)) >> $$s/build.log 2>&1 || { \
	   tail -20 $$s/build.log >&2; echo "  FAIL     install (full log: $$s/build.log)" >&2; exit 1; }
	@$(call assert_busybox)

# "Dynamic, against the musl built in the last step" is the whole requirement,
# so it is read back off the binary rather than inferred from the flags that
# were passed. A static build has no interpreter and no NEEDED at all.
define assert_busybox
	set -e; \
	$(CROSS)readelf -h $(BB_BIN) | grep -q AArch64 \
	  || { echo "  FAIL     busybox is not an aarch64 binary" >&2; exit 1; }; \
	$(CROSS)readelf -l $(BB_BIN) | grep -q 'interpreter: /lib/ld-musl-aarch64.so.1' \
	  || { echo "  FAIL     busybox is not dynamic against the musl loader" >&2; exit 1; }; \
	$(CROSS)readelf -d $(BB_BIN) | grep -q 'NEEDED.*libc\.so' \
	  || { echo "  FAIL     busybox does not link libc.so" >&2; exit 1; }; \
	cmp -s $(BB_BIN) $(abspath $(SYSROOT))/bin/busybox \
	  || { echo "  FAIL     $(SYSROOT)/bin/busybox is missing or is not this build" >&2; exit 1; }; \
	[ -L $(abspath $(SYSROOT))/bin/sh ] \
	  || { echo "  FAIL     the applet symlinks did not land in $(SYSROOT)" >&2; exit 1; }
endef

.PHONY: busybox-update
busybox-update: ## Re-resolve the latest busybox release and rebuild
	@rm -f $(BB_ENV)
	@$(MAKE) --no-print-directory busybox

.PHONY: busybox-check
busybox-check: $(BB_BIN) ## Re-read the busybox binary and confirm it is dynamic musl
	@$(call assert_busybox)
	@echo "  OK       $(BB_BIN) is aarch64, dynamic, on the musl loader"

.PHONY: busybox-info
busybox-info: $(BB_BIN) ## Show the busybox build
	@source $(BB_ENV); echo "  version  busybox $$BB_VER"
	@printf '  binary   %s (%s KiB)\n' $(BB_BIN) "$$(( $$(wc -c < $(BB_BIN)) / 1024 ))"
	@printf '  applets  %s (%s)\n' "$$(wc -l < $(BB_LINKS) | tr -d ' ')" $(BB_LINKS)
	@$(CROSS)readelf -l $(BB_BIN) | sed -n 's/.*Requesting program interpreter: \(.*\)]/  loader   \1/p'
	@$(CROSS)readelf -d $(BB_BIN) | sed -n 's/.*(NEEDED).*\[\(.*\)]/  needs    \1/p'

# ---------------------------------------------------------------------------
# Step 5 - retrieve and install the kernel modules
#
# The modules live in raspberrypi/firmware under modules/, and they have to
# come from the same tag the boot partition was built from: a module built for
# a different kernel version will not load, and /lib/modules is keyed by that
# version. The tag is not guessed - the boot release names it, and step 1
# already reads it out of the release body into BOOT_FIRMWARE_TAG.
#
# Two trees are installed, not one, because the boot partition carries two
# kernels: kernel8.img (Zero 2 W, Pi 3, Pi 4, CM4) takes <version>-v8+, and
# kernel_2712.img (Pi 5, CM5, 16K pages) takes <version>-v8-16k+. Shipping
# only -v8+ gives a card that boots four boards with modules and two without.
# The plain and -v7+ trees in the same directory are for the 32-bit kernels
# this project does not ship, and -v8-rt+ is the realtime kernel, which the
# boot partition does not carry either.
#
# A blobless sparse clone is what fetches them: the two trees are 1900 files
# each, so HTTP would be several thousand requests, and the release tarball
# would drag in all five kernels plus the firmware blobs. Cloning the tag with
# --filter=blob:none --sparse costs 1.8 MiB and three seconds, after which the
# checkout of just those two paths pulls the ~54 MiB that is actually wanted.
#
# The kernel version is discovered from the clone rather than configured here:
# it changes with every firmware release, and the directory names in modules/
# are the authority on it.
#
# depmod has already been run upstream - modules.dep and its .bin companions
# ship in the tree - so nothing here needs a depmod that can target another
# kernel's module tree from macOS. The modules themselves are .ko.xz.
# ---------------------------------------------------------------------------

# Empty means "the tag the boot release was built from". Set it to override,
# e.g. FIRMWARE_TAG=1.20260521.
FIRMWARE_TAG ?=

FW_GIT_URL ?= https://github.com/raspberrypi/firmware.git

DL_MOD      := $(DL_DIR)/modules
MOD_DIR     := $(BUILD_DIR)/modules
MOD_CFG     := $(MOD_DIR)/.config
MOD_ENV     := $(MOD_DIR)/version.env
# Written by the fetch, because the kernel versions are a property of the tag
# and are only known once its modules/ listing has been read.
MOD_KERNELS := $(MOD_DIR)/kernels.env
MOD_FETCHED := $(MOD_DIR)/.fetched
MOD_STAMP   := $(MOD_DIR)/.installed

MOD_SIG      = $(FIRMWARE_TAG)|$(FW_GIT_URL)

# Resolving the tag needs the boot release only when it is not pinned.
MOD_BOOT_DEP = $(if $(FIRMWARE_TAG),,$(BOOT_ENV))

# Deliberately independent of musl and busybox although all three install into
# the same sysroot: /lib/modules is this step's alone, so `make modules` is
# usable on its own without waiting for a libc build.
.PHONY: modules
modules: $(MOD_STAMP) ## Fetch the kernel modules matching the boot kernel and install them
	@source $(MOD_KERNELS); printf '  READY    modules %s -> %s/lib/modules (%s, %s)\n' \
	   "$$FW_TAG" $(SYSROOT) "$$KVER_V8" "$$KVER_V8_16K"

$(MOD_CFG): FORCE
	@mkdir -p $(@D)
	@printf '%s\n' '$(MOD_SIG)' | cmp -s - $@ || printf '%s\n' '$(MOD_SIG)' > $@

$(MOD_ENV): $(MOD_CFG) $(MOD_BOOT_DEP)
	@mkdir -p $(@D)
	@echo "  RESOLVE  kernel modules ($(if $(FIRMWARE_TAG),pinned $(FIRMWARE_TAG),from the boot release notes))"
	@if [ -n '$(FIRMWARE_TAG)' ]; then t='$(FIRMWARE_TAG)'; else \
	   source $(BOOT_ENV); \
	   if [ -z "$${BOOT_FIRMWARE_TAG+set}" ]; then \
	     echo "  FAIL     $(BOOT_ENV) predates the firmware tag being recorded." >&2; \
	     echo "           'make boot-update' rewrites it; it stays on $$BOOT_TAG unless a" >&2; \
	     echo "           newer release exists on CHANNEL. Or pin it: FIRMWARE_TAG=<tag>" >&2; \
	     exit 1; \
	   fi; \
	   t="$$BOOT_FIRMWARE_TAG"; \
	   if [ -z "$$t" ]; then \
	     echo "  FAIL     boot release $$BOOT_TAG does not name a Raspberry Pi firmware tag" >&2; \
	     echo "           in its release notes. The modules have to come from the same tag" >&2; \
	     echo "           as the boot kernel, so pass it: make FIRMWARE_TAG=<tag> modules" >&2; \
	     exit 1; \
	   fi; \
	 fi; \
	 [[ "$$t" =~ ^[0-9A-Za-z._-]+$$ ]] || { echo "Refusing firmware tag '$$t'." >&2; exit 1; }; \
	 printf "FW_TAG='%s'\n" "$$t" > $@.part
	@mv -f $@.part $@
	@sed -n "s/^FW_TAG='\(.*\)'/  FIRMWARE \1/p" $@

# Keyed by tag under downloads/ and kept across `clean`, like the boot image:
# a git tag is a fixed point, so a tag already on disk is never refetched. The
# .complete marker is what distinguishes a finished copy from one interrupted
# half way, which would otherwise look like a perfectly good cache entry.
#
# A tag can be moved upstream, and git's own integrity guarantees hang off the
# commit it resolves to, so that commit is the one thing worth recording. It is
# trust-on-first-use like the musl digest - the record has to be committed to
# mean anything - but one line of manifest then covers all 3800 files.
#
# `|| true` on the two greps is not sloppiness: this recipe runs under `set -e`
# with pipefail, so a grep that matches nothing would abort here, and the
# whole point of testing the result is to report what the tag does carry.
$(MOD_FETCHED): $(MOD_ENV)
	@command -v git >/dev/null 2>&1 || { echo "git is required to fetch the kernel modules" >&2; exit 1; }
	@mkdir -p $(MOD_DIR) $(DL_MOD) $(CHECKSUMS)
	@source $(MOD_ENV); d=$(DL_MOD)/$$FW_TAG; g=$(DL_MOD)/.fwgit; \
	 m=$(CHECKSUMS)/firmware-$$FW_TAG.commit; \
	 if [ ! -f "$$d/.complete" ]; then \
	   echo "  FETCH    modules/ ($$FW_TAG)"; \
	   rm -rf "$$d" "$$d.part" "$$g"; \
	   git -c advice.detachedHead=false clone --quiet --depth 1 \
	       --filter=blob:none --sparse --branch "$$FW_TAG" $(FW_GIT_URL) "$$g" || { \
	     echo "  FAIL     no tag '$$FW_TAG' in $(FW_GIT_URL), or the clone failed" >&2; \
	     rm -rf "$$g"; exit 1; }; \
	   c=$$(git -C "$$g" rev-parse HEAD); \
	   if [ -f "$$m" ]; then \
	     echo "  VERIFY   $$FW_TAG -> $${c:0:12}"; \
	     [ "$$c" = "$$(cat $$m)" ] || { \
	       echo "  FAIL     tag $$FW_TAG now points at $$c," >&2; \
	       echo "           not $$(cat $$m) as recorded in $$m" >&2; \
	       rm -rf "$$g"; exit 1; }; \
	   else \
	     printf '%s\n' "$$c" > "$$m"; \
	     echo "  RECORD   $$m - first fetch of this tag, commit it"; \
	   fi; \
	   names=$$(git -C "$$g" ls-tree --name-only HEAD modules/ | sed 's|^modules/||'); \
	   v8=$$(grep -E -- '\-v8\+$$'      <<<"$$names" | head -1 || true); \
	   v16=$$(grep -E -- '\-v8-16k\+$$' <<<"$$names" | head -1 || true); \
	   if [ -z "$$v8" ] || [ -z "$$v16" ]; then \
	     echo "  FAIL     $$FW_TAG has no -v8+ and -v8-16k+ module trees; it carries:" >&2; \
	     sed 's/^/           /' <<<"$$names" >&2; rm -rf "$$g"; exit 1; fi; \
	   echo "  CHECKOUT $$v8, $$v16"; \
	   git -C "$$g" sparse-checkout set --no-cone "modules/$$v8" "modules/$$v16" >/dev/null; \
	   mkdir -p "$$d.part"; \
	   cp -R "$$g/modules/$$v8" "$$g/modules/$$v16" "$$d.part/"; \
	   rm -rf "$$g"; \
	   touch "$$d.part/.complete"; \
	   mv -f "$$d.part" "$$d"; \
	 fi; \
	 v8=$$(cd $$d && ls -d *-v8+ 2>/dev/null | head -1 || true); \
	 v16=$$(cd $$d && ls -d *-v8-16k+ 2>/dev/null | head -1 || true); \
	 if [ -z "$$v8" ] || [ -z "$$v16" ]; then \
	   echo "  FAIL     $$d holds no module trees; delete it and retry" >&2; exit 1; fi; \
	 { echo "FW_TAG='$$FW_TAG'"; \
	   echo "KVER_V8='$$v8'"; \
	   echo "KVER_V8_16K='$$v16'"; \
	   echo "MOD_SRC='$$d'"; } > $(MOD_KERNELS)
	@touch $@

# lib/modules belongs to this step alone, so it is cleared wholesale rather
# than per-version: a rebuild after the firmware tag moved would otherwise
# leave the previous kernel's tree behind, and the image would ship modules for
# a kernel that is not on the card. musl and busybox own other directories in
# the same sysroot and are untouched.
$(MOD_STAMP): $(MOD_FETCHED) Makefile
	@source $(MOD_KERNELS); \
	 echo "  INSTALL  -> $(SYSROOT)/lib/modules"; \
	 rm -rf $(SYSROOT)/lib/modules; \
	 mkdir -p $(SYSROOT)/lib/modules; \
	 cp -R "$$MOD_SRC/$$KVER_V8" "$$MOD_SRC/$$KVER_V8_16K" $(SYSROOT)/lib/modules/
	@$(call assert_modules)
	@touch $@

# What makes a module tree usable is not that files arrived but that modprobe
# can resolve a dependency out of it, so modules.dep is read and the first
# module it names is looked for on disk. That is what catches the real failure
# mode here: a sparse-checkout pattern that matches the directory but none of
# its contents leaves the metadata in place and the .ko.xz files absent.
define assert_modules
	set -e; \
	source $(MOD_KERNELS); \
	for k in "$$KVER_V8" "$$KVER_V8_16K"; do \
	  d=$(abspath $(SYSROOT))/lib/modules/$$k; \
	  [ -s "$$d/modules.dep" ] || { \
	    echo "  FAIL     $$d has no modules.dep" >&2; exit 1; }; \
	  [ -s "$$d/modules.alias" ] && [ -s "$$d/modules.builtin" ] || { \
	    echo "  FAIL     $$d is missing the depmod metadata" >&2; exit 1; }; \
	  first=$$(sed -n '1s/:.*//p' "$$d/modules.dep"); \
	  [ -f "$$d/$$first" ] || { \
	    echo "  FAIL     $$d/modules.dep names $$first, which is not there" >&2; exit 1; }; \
	  n=$$(find "$$d/kernel" -name '*.ko*' | wc -l); \
	  [ "$$n" -gt 100 ] || { \
	    echo "  FAIL     $$d holds only $$n modules" >&2; exit 1; }; \
	done
endef

.PHONY: modules-check
modules-check: $(MOD_STAMP) ## Re-read the installed module trees and their dependency data
	@$(call assert_modules)
	@source $(MOD_KERNELS); \
	 echo "  OK       $$KVER_V8 and $$KVER_V8_16K resolve out of $(SYSROOT)/lib/modules"

.PHONY: modules-info
modules-info: $(MOD_STAMP) ## Show the kernel module trees that were installed
	@source $(MOD_KERNELS); \
	 tree() { d=$(SYSROOT)/lib/modules/$$1; \
	   printf '  tree     %-20s %4s modules, %3s MiB - %s\n' "$$1" \
	     "$$(find $$d/kernel -name '*.ko*' | wc -l | tr -d ' ')" \
	     "$$(du -sm $$d | cut -f1)" "$$2"; }; \
	 echo "  firmware $$FW_TAG$(if $(FIRMWARE_TAG), (pinned))"; \
	 echo "  commit   $$(cat $(CHECKSUMS)/firmware-$$FW_TAG.commit 2>/dev/null || echo unrecorded)"; \
	 echo "  source   $$MOD_SRC"; \
	 tree "$$KVER_V8"     "kernel8.img: Zero 2 W, Pi 3, Pi 4, CM4"; \
	 tree "$$KVER_V8_16K" "kernel_2712.img: Pi 5, CM5"

# ---------------------------------------------------------------------------
# Step 6, part 1 - e2fsprogs, built for this machine and for the target
#
# macOS has no mkfs.ext4, no loop mounts and no root, and Linux distributions
# ship whichever e2fsprogs their release froze on - and the version decides the
# on-disk layout. Both problems go away by building it here: one pinned source
# tree, configured twice.
#
#   host   - mke2fs, debugfs and e2fsck. mke2fs -d builds an ext4 image from a
#            directory, which is what makes the whole image build unprivileged.
#   target - resize2fs, the one tool first boot needs that busybox has no
#            applet for. Dynamic against the musl from step 3, exactly like
#            busybox, and proved that way rather than assumed.
#
# HOST_E2FSPROGS=<dir> points at tools you already have (say
# /opt/homebrew/opt/e2fsprogs/sbin) and skips the host build; the image layout
# then depends on whatever version that is.
#
# The cross build has one trap worth stating: configure looks for
# aarch64-linux-ar, does not find it, and falls back to the host's ar without
# comment. On macOS that writes archives carrying a __.SYMDEF index, which GNU
# ld cannot read - so every library appears to build and every symbol in it
# then comes back undefined at link time. AR, RANLIB and STRIP are passed
# explicitly for that reason, and only for that reason.
# ---------------------------------------------------------------------------

E2FS_VERSION ?=
E2FS_BASE    ?= https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs
E2FS_SIG      = $(E2FS_VERSION)|$(E2FS_BASE)

DL_E2FS       := $(DL_DIR)/e2fsprogs
E2FS_DIR      := $(BUILD_DIR)/e2fsprogs
E2FS_CFG      := $(E2FS_DIR)/.config
E2FS_ENV      := $(E2FS_DIR)/version.env
E2FS_UNPACKED := $(E2FS_DIR)/.unpacked
E2FS_HOST_STAMP := $(E2FS_DIR)/.host-built
E2FS_TGT_STAMP  := $(E2FS_DIR)/.target-built

HOST_E2FSPROGS ?=
E2FS_HOST_DEP   = $(if $(HOST_E2FSPROGS),,$(E2FS_HOST_STAMP))
MKE2FS          = $(if $(HOST_E2FSPROGS),$(HOST_E2FSPROGS)/mke2fs,$(abspath $(E2FS_DIR)/host/misc/mke2fs))
DEBUGFS         = $(if $(HOST_E2FSPROGS),$(HOST_E2FSPROGS)/debugfs,$(abspath $(E2FS_DIR)/host/debugfs/debugfs))
E2FSCK          = $(if $(HOST_E2FSPROGS),$(HOST_E2FSPROGS)/e2fsck,$(abspath $(E2FS_DIR)/host/e2fsck/e2fsck))
RESIZE2FS       = $(E2FS_DIR)/target/resize/resize2fs

# Neither build needs nls, uuidd, the initrd helper, e4defrag or e2image, and
# every one of them is another way for a cross build to go wrong.
E2FS_CONFIGURE = --disable-nls --disable-fsck --disable-uuidd \
                 --disable-e2initrd-helper --disable-defrag --disable-imager

.PHONY: e2fsprogs
e2fsprogs: $(E2FS_HOST_DEP) $(E2FS_TGT_STAMP) ## Build mke2fs/debugfs for this host and resize2fs for the target
	@source $(E2FS_ENV); printf '  READY    e2fsprogs %s -> %s + %s\n' \
	   "$$E2FS_VER" "$(if $(HOST_E2FSPROGS),$(HOST_E2FSPROGS) (host tools),$(E2FS_DIR)/host)" $(RESIZE2FS)

$(E2FS_CFG): FORCE
	@mkdir -p $(@D)
	@printf '%s\n' '$(E2FS_SIG)' | cmp -s - $@ || printf '%s\n' '$(E2FS_SIG)' > $@

# The index lists one directory per release, so "latest" is the highest vN.N.N
# in it. sort -V again, for the same reason as everywhere else here.
$(E2FS_ENV): $(E2FS_CFG)
	@mkdir -p $(@D)
	@echo "  RESOLVE  e2fsprogs ($(if $(E2FS_VERSION),pinned $(E2FS_VERSION),latest release))"
	@if [ -n '$(E2FS_VERSION)' ]; then v='$(E2FS_VERSION)'; else \
	   v=$$($(CURL) "$(E2FS_BASE)/" \
	        | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?/' \
	        | sed 's|^v||; s|/$$||' \
	        | sort -uV | tail -1); \
	   [ -n "$$v" ] || { echo "Could not read the release index at $(E2FS_BASE)/." >&2; exit 1; }; \
	 fi; \
	 [[ "$$v" =~ ^[0-9][0-9A-Za-z._-]*$$ ]] || { echo "Refusing e2fsprogs version '$$v'." >&2; exit 1; }; \
	 printf "E2FS_VER='%s'\n" "$$v" > $@.part
	@mv -f $@.part $@
	@sed -n "s/^E2FS_VER='\(.*\)'/  E2FSPROGS \1/p" $@

# kernel.org publishes sha256sums.asc next to every release. It is a clearsigned
# document rather than a bare digest file, but the digest lines inside it are in
# sha256sum's own format, so grepping out the one line for this tarball gives
# something --check reads directly - upstream's digest, no record kept here.
$(E2FS_UNPACKED): $(E2FS_ENV)
	@mkdir -p $(DL_E2FS) $(E2FS_DIR)
	@source $(E2FS_ENV); t=e2fsprogs-$$E2FS_VER.tar.gz; d=$(DL_E2FS)/$$E2FS_VER; \
	 mkdir -p "$$d"; \
	 if [ ! -f "$$d/$$t" ]; then \
	   echo "  FETCH    $$t"; \
	   $(CURL) -o "$$d/$$t.part" "$(E2FS_BASE)/v$$E2FS_VER/$$t" || { \
	     echo "  FAIL     could not fetch $$t from $(E2FS_BASE)/v$$E2FS_VER" >&2; exit 1; }; \
	   mv -f "$$d/$$t.part" "$$d/$$t"; \
	 fi; \
	 if [ ! -f "$$d/sha256sums.asc" ]; then \
	   $(CURL) -o "$$d/sha256sums.asc.part" "$(E2FS_BASE)/v$$E2FS_VER/sha256sums.asc" || { \
	     echo "  FAIL     no upstream digests for $$t - refusing an unverifiable tarball" >&2; exit 1; }; \
	   mv -f "$$d/sha256sums.asc.part" "$$d/sha256sums.asc"; \
	 fi; \
	 echo "  VERIFY   $$t"; \
	 ( cd "$$d" && grep -F "  $$t" sha256sums.asc | $(SHA256) --check --quiet - ) || { \
	   echo "  FAIL     $$t does not match upstream's digest; delete $$d and retry" >&2; exit 1; }; \
	 echo "  UNPACK   $$t"; \
	 rm -rf $(E2FS_DIR)/e2fsprogs-$$E2FS_VER; \
	 tar -xf "$$d/$$t" -C $(E2FS_DIR)
	@touch $@

# Both builds are out-of-tree, so the two configurations cannot contaminate
# each other and neither writes into the unpacked source.
$(E2FS_HOST_STAMP): $(E2FS_UNPACKED) Makefile
	@source $(E2FS_ENV); s=$(abspath $(E2FS_DIR))/e2fsprogs-$$E2FS_VER; b=$(E2FS_DIR)/host; \
	 mkdir -p $$b; \
	 echo "  CONFIG   e2fsprogs $$E2FS_VER (host tools)"; \
	 ( cd $$b && $$s/configure $(E2FS_CONFIGURE) ) > $$b/configure.log 2>&1 || { \
	   tail -20 $$b/configure.log >&2; \
	   echo "  FAIL     configure (full log: $$b/configure.log)" >&2; exit 1; }; \
	 echo "  BUILD    e2fsprogs $$E2FS_VER (host, -j$(JOBS))"; \
	 $(MAKE) --no-print-directory -C $$b -j$(JOBS) > $$b/build.log 2>&1 || { \
	   tail -30 $$b/build.log >&2; \
	   echo "  FAIL     build (full log: $$b/build.log)" >&2; exit 1; }
	@for t in $(MKE2FS) $(DEBUGFS) $(E2FSCK); do \
	   [ -x "$$t" ] || { echo "  FAIL     $$t was not built" >&2; exit 1; }; \
	 done
	@touch $@

# Only the libraries and resize2fs, not `make all`: everything else in the tree
# is either a host tool or a test program, and several of the test programs do
# not cross-link at all.
$(E2FS_TGT_STAMP): $(E2FS_UNPACKED) $(MUSL_STAMP) $(TOOLCHAIN_DEP) Makefile
	@source $(E2FS_ENV); s=$(abspath $(E2FS_DIR))/e2fsprogs-$$E2FS_VER; b=$(E2FS_DIR)/target; \
	 mkdir -p $$b; \
	 echo "  CONFIG   e2fsprogs $$E2FS_VER (aarch64, dynamic against $(SYSROOT))"; \
	 ( cd $$b && $$s/configure --host=aarch64-linux $(E2FS_CONFIGURE) \
	     CC=$(CROSS)gcc AR=$(CROSS)ar RANLIB=$(CROSS)ranlib STRIP=$(CROSS)strip \
	     CFLAGS="-O2 --sysroot=$(abspath $(SYSROOT))" \
	     LDFLAGS="--sysroot=$(abspath $(SYSROOT)) -Wl,--dynamic-linker=/lib/ld-musl-aarch64.so.1" \
	   ) > $$b/configure.log 2>&1 || { \
	   tail -20 $$b/configure.log >&2; \
	   echo "  FAIL     configure (full log: $$b/configure.log)" >&2; exit 1; }; \
	 echo "  BUILD    resize2fs (-j$(JOBS))"; \
	 $(MAKE) --no-print-directory -C $$b -j$(JOBS) libs > $$b/build.log 2>&1 || { \
	   tail -30 $$b/build.log >&2; \
	   echo "  FAIL     libs (full log: $$b/build.log)" >&2; exit 1; }; \
	 $(MAKE) --no-print-directory -C $$b/resize resize2fs >> $$b/build.log 2>&1 || { \
	   tail -30 $$b/build.log >&2; \
	   echo "  FAIL     resize2fs (full log: $$b/build.log)" >&2; exit 1; }
	@$(call assert_target_binary,$(RESIZE2FS))
	@touch $@

# The same three questions asked of busybox, asked again of anything else that
# has to run on the card: right architecture, right loader, links our libc.
define assert_target_binary
	set -e; \
	$(CROSS)readelf -h $(1) | grep -q AArch64 \
	  || { echo "  FAIL     $(1) is not an aarch64 binary" >&2; exit 1; }; \
	$(CROSS)readelf -l $(1) | grep -q 'interpreter: /lib/ld-musl-aarch64.so.1' \
	  || { echo "  FAIL     $(1) does not use the musl loader" >&2; exit 1; }; \
	$(CROSS)readelf -d $(1) | grep -q 'NEEDED.*libc\.so' \
	  || { echo "  FAIL     $(1) does not link libc.so" >&2; exit 1; }
endef

.PHONY: e2fsprogs-info
e2fsprogs-info: $(E2FS_HOST_DEP) $(E2FS_TGT_STAMP) ## Show the e2fsprogs build
	@source $(E2FS_ENV); echo "  version  e2fsprogs $$E2FS_VER"
	@echo "  mke2fs   $(MKE2FS)$(if $(HOST_E2FSPROGS), (HOST_E2FSPROGS))"
	@$(MKE2FS) -V 2>&1 | sed -n '1s/^/  reports  /p'
	@printf '  resize2fs %s (%s KiB, aarch64)\n' $(RESIZE2FS) "$$(( $$(wc -c < $(RESIZE2FS)) / 1024 ))"
# ---------------------------------------------------------------------------
# Step 6, part 2 - the root filesystem tree
#
# build/rootfs is the Linux FHS tree that becomes partition 2: busybox and its
# 408 applet links, the musl loader and libc.so, both kernel module trees, the
# cross-built resize2fs, and the configuration in overlay/.
#
# overlay/ is a directory of real files rather than heredocs in this Makefile
# on purpose - /etc/init.d/rcS and the two scripts under usr/sbin are shell
# programs of some size, and they are far easier to read, diff and check with
# `sh -n` as files. Only what genuinely varies per build is generated here:
# the password hash, the version strings, and fstab.
#
# The tree is staged with ordinary user ownership and turned into root-owned
# files when the image is made, so nothing in this step needs privileges.
#
# busybox's own install puts a symlink at sbin/init, and the overlay replaces it
# with a script. That symlink has to be removed first: cp onto a symlink follows
# it, so copying the overlay over the top would silently overwrite
# /bin/busybox with a five-line shell script and produce an image with no
# userspace at all.
# ---------------------------------------------------------------------------

SEPIAOS_VERSION ?= 0.1.0

# Where the boot partition's cmdline.txt says the rootfs is, and where fstab
# should look for the boot partition. These must match ../boot's CMDLINE_ROOT.
ROOT_DEVICE ?= /dev/mmcblk0p2
BOOT_DEVICE ?= /dev/mmcblk0p1

# sha512-crypt of "sepiaos". The password is public - it is in the README - so
# it is worth exactly one login, and /etc/profile refuses to give a shell until
# it has been changed. Regenerate with:
#   openssl passwd -6 -salt <salt> <password>
# (LibreSSL, which is what /usr/bin/openssl is on macOS, has no -6; Homebrew's
# openssl and every Linux one do.) Doubling every $ is what keeps make from
# reading the hash as three variable references, and an override on the command
# line has to double them too.
ROOT_PASSWORD_HASH ?= $$6$$SepiaOSsalt$$FWNx87IZVDqzgxDUvZkO6uuqumlfSuqXmP9gXCX/6CEOaAVGz/aqfqPgRrHrHkLDsxlOrl8Y94g01xzuVtIrr/

OVERLAY      := overlay
OVERLAY_SRC  := $(shell find $(OVERLAY) -type f 2>/dev/null)

ROOTFS_DIR   := $(BUILD_DIR)/rootfs
IMG_DIR      := $(BUILD_DIR)/image
ROOTFS_STAMP := $(IMG_DIR)/.rootfs

# /var/run and /var/lock are symlinks into /run, which is where the FHS has
# put them since 3.0 and where every tool expects to find them.
ROOTFS_DIRS := bin boot dev etc etc/init.d home lib media mnt opt proc root run \
               sbin srv sys tmp usr usr/bin usr/lib usr/local usr/sbin usr/share \
               var var/cache var/lib var/lib/sepia var/log var/spool var/tmp

.PHONY: rootfs
rootfs: $(ROOTFS_STAMP) ## Stage the root filesystem tree under build/rootfs
	@printf '  READY    rootfs %s -> %s (%s MiB, %s files)\n' "$(SEPIAOS_VERSION)" $(ROOTFS_DIR) \
	   "$$(du -sm $(ROOTFS_DIR) | cut -f1)" "$$(find $(ROOTFS_DIR) | wc -l | tr -d ' ')"

$(ROOTFS_STAMP): $(BB_BIN) $(MUSL_STAMP) $(MOD_STAMP) $(E2FS_TGT_STAMP) $(OVERLAY_SRC) Makefile
	@mkdir -p $(IMG_DIR)
	@echo "  STAGE    $(ROOTFS_DIR)"
	@rm -rf $(ROOTFS_DIR)
	@mkdir -p $(addprefix $(ROOTFS_DIR)/,$(ROOTFS_DIRS))
	@ln -s ../run      $(ROOTFS_DIR)/var/run
	@ln -s ../run/lock $(ROOTFS_DIR)/var/lock
	@cp -R $(SYSROOT)/bin/.      $(ROOTFS_DIR)/bin/
	@cp -R $(SYSROOT)/sbin/.     $(ROOTFS_DIR)/sbin/
	@cp -R $(SYSROOT)/usr/bin/.  $(ROOTFS_DIR)/usr/bin/
	@cp -R $(SYSROOT)/usr/sbin/. $(ROOTFS_DIR)/usr/sbin/
	@cp -R $(SYSROOT)/lib/modules $(ROOTFS_DIR)/lib/
	@cp -R $(SYSROOT)/lib/ld-musl-aarch64.so.1 $(ROOTFS_DIR)/lib/
	@cp $(SYSROOT)/usr/lib/libc.so $(ROOTFS_DIR)/usr/lib/
	@cp $(RESIZE2FS) $(ROOTFS_DIR)/usr/sbin/resize2fs
	@rm -f $(ROOTFS_DIR)/sbin/init
	@cp -R $(OVERLAY)/. $(ROOTFS_DIR)/
	@$(call generate_etc)
	@chmod 0755 $(ROOTFS_DIR) $(ROOTFS_DIR)/etc/init.d/rcS $(ROOTFS_DIR)/etc/init.d/rcK \
	            $(ROOTFS_DIR)/usr/sbin/sepia-gettys $(ROOTFS_DIR)/usr/sbin/sepia-firstboot \
	            $(ROOTFS_DIR)/usr/sbin/resize2fs
	@chmod 0700 $(ROOTFS_DIR)/root
	@chmod 0600 $(ROOTFS_DIR)/etc/shadow
	@chmod 1777 $(ROOTFS_DIR)/tmp $(ROOTFS_DIR)/var/tmp
	@chmod 0555 $(ROOTFS_DIR)/proc $(ROOTFS_DIR)/sys
	@$(call assert_rootfs)
	@touch $@

# fstab names the boot partition so `mount /boot` in rcS has something to read,
# and the swap line is appended by sepia-firstboot once the partition exists.
# The root entry is documentation and a fsck order: the kernel has already
# mounted / from root= on the command line by the time anything reads this.
define generate_etc
	set -e; r=$(ROOTFS_DIR); \
	source $(MOD_KERNELS); source $(BOOT_ENV); \
	{ echo 'root:$(ROOT_PASSWORD_HASH):20000:0:99999:7:::'; \
	  echo 'daemon:*:20000:0:99999:7:::'; \
	  echo 'nobody:*:20000:0:99999:7:::'; } > $$r/etc/shadow; \
	f='%-16s %-14s %-6s %-18s %-6s %s\n'; \
	{ printf "$$f" '# <device>' '<mount point>' '<type>' '<options>' '<dump>' '<pass>'; \
	  printf "$$f" '$(ROOT_DEVICE)' /     ext4 defaults,noatime 0 1; \
	  printf "$$f" '$(BOOT_DEVICE)' /boot vfat defaults,noatime 0 2; } > $$r/etc/fstab; \
	{ echo 'NAME="SepiaOS"'; \
	  echo 'ID=sepiaos'; \
	  echo 'VERSION="$(SEPIAOS_VERSION)"'; \
	  echo 'VERSION_ID="$(SEPIAOS_VERSION)"'; \
	  echo 'PRETTY_NAME="SepiaOS $(SEPIAOS_VERSION)"'; \
	  echo 'HOME_URL="https://github.com/Sepia-OS"'; \
	  echo "SEPIAOS_BOOT_RELEASE=\"$$BOOT_TAG\""; \
	  echo "SEPIAOS_FIRMWARE=\"$$FW_TAG\""; \
	  echo "SEPIAOS_KERNELS=\"$$KVER_V8 $$KVER_V8_16K\""; } > $$r/etc/os-release; \
	{ echo 'SepiaOS $(SEPIAOS_VERSION) \n \l'; echo; } > $$r/etc/issue; \
	: > $$r/etc/sepiaos-password-unchanged
endef

# What has to be true for this tree to boot at all, asked of the tree itself
# rather than of the steps that filled it: init has to exist, the loader every
# binary asks for has to be present *inside* the image, and the tools the two
# boot-time scripts call have to be there. A missing loader is the failure that
# looks like a kernel panic with no explanation.
define assert_rootfs
	set -e; r=$(ROOTFS_DIR); \
	[ ! -L "$$r/sbin/init" ] && [ -s "$$r/bin/busybox" ] \
	  || { echo "  FAIL     sbin/init should be the wrapper script, not a busybox symlink" >&2; exit 1; }; \
	for f in sbin/init bin/sh bin/busybox bin/login usr/bin/passwd sbin/getty \
	         usr/sbin/resize2fs etc/inittab etc/init.d/rcS etc/passwd etc/shadow \
	         usr/sbin/sepia-firstboot usr/sbin/sepia-gettys; do \
	  [ -e "$$r/$$f" ] || { echo "  FAIL     $$r/$$f is missing" >&2; exit 1; }; \
	done; \
	[ -L "$$r/lib/ld-musl-aarch64.so.1" ] \
	  || { echo "  FAIL     no musl loader in the tree" >&2; exit 1; }; \
	l=$$(readlink "$$r/lib/ld-musl-aarch64.so.1"); \
	[ -f "$$r$$l" ] \
	  || { echo "  FAIL     the loader points at $$l, which is not in the tree" >&2; exit 1; }; \
	grep -q '^# --- generated by sepia-gettys' "$$r/etc/inittab" \
	  || { echo "  FAIL     etc/inittab has no marker for the generated getty lines" >&2; exit 1; }; \
	grep -q '^root:\$$6\$$' "$$r/etc/shadow" \
	  || { echo "  FAIL     root has no sha512 password hash in etc/shadow" >&2; exit 1; }; \
	source $(MOD_KERNELS); \
	for k in "$$KVER_V8" "$$KVER_V8_16K"; do \
	  [ -s "$$r/lib/modules/$$k/modules.dep" ] \
	    || { echo "  FAIL     lib/modules/$$k did not make it into the tree" >&2; exit 1; }; \
	done
endef

.PHONY: rootfs-check
rootfs-check: $(ROOTFS_STAMP) ## Re-read the staged tree and check it could boot
	@$(call assert_rootfs)
	@echo "  OK       $(ROOTFS_DIR) has an init, a shell, a loader and both module trees"

.PHONY: rootfs-info
rootfs-info: $(ROOTFS_STAMP) ## Show what was staged into the root filesystem
	@echo "  version  SepiaOS $(SEPIAOS_VERSION)"
	@echo "  tree     $(ROOTFS_DIR)"
	@printf '  size     %s MiB in %s files\n' \
	   "$$(du -sm $(ROOTFS_DIR) | cut -f1)" "$$(find $(ROOTFS_DIR) | wc -l | tr -d ' ')"
	@printf '  modules  %s MiB\n' "$$(du -sm $(ROOTFS_DIR)/lib/modules | cut -f1)"
	@sed -n 's/^PRETTY_NAME=/  os       /p;s/^SEPIAOS_KERNELS=/  kernels  /p' $(ROOTFS_DIR)/etc/os-release
# ---------------------------------------------------------------------------
# Step 6, part 3 - the bootable image
#
# One MBR disk image: partition 1 is the boot partition exactly as the boot
# release published it, partition 2 is an ext4 filesystem holding build/rootfs.
# The boot image already carries a valid MBR with partition 1 in it, so it is
# copied in whole and only the second table entry is written here.
#
# Nothing is mounted and nothing needs root. mke2fs -d builds the filesystem
# straight from the staged directory, and debugfs then sets every inode to
# root:root - mke2fs copies the ownership it finds on disk, which would
# otherwise ship a card whose /etc and /bin belong to whichever uid happened to
# run the build. Doing it this way also makes the result independent of who
# built it, which a `sudo chown -R` staging tree would not be.
#
# The image is deliberately small: it is sized to its contents, and first boot
# grows partition 2 into whatever card it was written to. IMAGE_SIZE_MIB has to
# be a power of two all the same, because QEMU refuses any other SD image size,
# and an image that cannot be booted in QEMU cannot be tested before it is
# written to a card.
# ---------------------------------------------------------------------------

IMAGE_SIZE_MIB ?= 256
ROOTFS_LABEL   ?= sepiaos-root


ROOTFS_IMG := $(IMG_DIR)/rootfs.ext4
IMAGE      := $(IMG_DIR)/sepiaos-$(SEPIAOS_VERSION).img

IMAGE_GOALS := image image-info image-check rootfs-image
ifneq ($(filter $(IMAGE_GOALS),$(MAKECMDGOALS)),)
  ifneq ($(shell echo $$(( $(IMAGE_SIZE_MIB) & ($(IMAGE_SIZE_MIB) - 1) ))),0)
    $(error IMAGE_SIZE_MIB must be a power of two - QEMU rejects any other SD image size, got $(IMAGE_SIZE_MIB))
  endif
endif

.PHONY: image
image: $(IMAGE) ## Build the bootable SepiaOS card image
	@printf '  READY    image -> %s (%s MiB)\n' $(IMAGE) "$$(( $$(wc -c < $(IMAGE)) / 1048576 ))"

# Partition 1's start and length are read out of the boot image rather than
# assumed: they are the boot release's decision, and if it ever moves them a
# hardcoded 64 MiB here would write the rootfs straight over the FAT.
define image_geometry
	le32() { od -An -tu4 -j $$1 -N4 $(BOOT_IMG) | tr -d ' '; }; \
	boot_start=$$(le32 454); boot_sectors=$$(le32 458); \
	root_start=$$((boot_start + boot_sectors)); \
	total_sectors=$$(( $(IMAGE_SIZE_MIB) * 2048 )); \
	root_sectors=$$((total_sectors - root_start)); \
	if [ "$$root_sectors" -le 0 ]; then \
	  echo "  FAIL     IMAGE_SIZE_MIB=$(IMAGE_SIZE_MIB) leaves no room after the $$((root_start / 2048)) MiB boot partition" >&2; \
	  exit 1; \
	fi
endef

.PHONY: rootfs-image
rootfs-image: $(ROOTFS_IMG) ## Build just the ext4 filesystem image

# -b 4096 rather than letting mke2fs choose: the block size decides how the
# free space in a 200 MiB filesystem is spent, and it must not change under us
# when the image size does.
#
# The chown pass is one debugfs run over a generated command file - about 7500
# commands for a tree this size, and quicker than it sounds because debugfs
# opens the filesystem once. sif is set_inode_field; e2fsck afterwards is what
# says the result is a filesystem and not just bytes.
$(ROOTFS_IMG): $(ROOTFS_STAMP) $(BOOT_IMG) $(E2FS_HOST_DEP) Makefile
	@mkdir -p $(@D)
	@$(call image_geometry); \
	 echo "  MKFS     ext4 $$((root_sectors / 2048)) MiB <- $(ROOTFS_DIR)"; \
	 rm -f $@.part; \
	 $(MKE2FS) -q -F -t ext4 -b 4096 -m 1 -L $(ROOTFS_LABEL) \
	   -d $(ROOTFS_DIR) -E root_owner=0:0 $@.part $$((root_sectors / 8)) || { \
	   echo "  FAIL     mke2fs" >&2; exit 1; }
	@echo "  CHOWN    every inode to root:root"
	@find $(ROOTFS_DIR) -mindepth 1 | sed 's|^$(ROOTFS_DIR)||' \
	  | awk '{printf "sif \"%s\" uid 0\nsif \"%s\" gid 0\n", $$0, $$0}' > $(IMG_DIR)/chown.debugfs
	@$(DEBUGFS) -w -f $(IMG_DIR)/chown.debugfs $@.part > $(IMG_DIR)/chown.log 2>&1 || { \
	   tail -20 $(IMG_DIR)/chown.log >&2; echo "  FAIL     debugfs" >&2; exit 1; }
	@$(call assert_rootfs_image,$@.part)
	@mv -f $@.part $@

# Two things can go wrong that a successful mke2fs does not rule out: the
# filesystem can be inconsistent, and the ownership pass can have silently
# missed. e2fsck answers the first; reading two inodes back answers the second.
define assert_rootfs_image
	set -e; \
	$(E2FSCK) -fn $(1) > $(IMG_DIR)/fsck.log 2>&1 || { \
	  cat $(IMG_DIR)/fsck.log >&2; echo "  FAIL     the filesystem is not clean" >&2; exit 1; }; \
	for f in /bin/busybox /etc/shadow /sbin/init; do \
	  o=$$($(DEBUGFS) -R "stat $$f" $(1) 2>/dev/null | sed -n 's/.*User: *\([0-9]*\) *Group: *\([0-9]*\).*/\1:\2/p'); \
	  [ "$$o" = "0:0" ] || { echo "  FAIL     $$f in the image is owned by $$o, not 0:0" >&2; exit 1; }; \
	done
endef

# The whole file is created at full size first, then the two partitions are
# written into it with conv=notrunc. Creating it by seeking leaves a sparse
# file, so an image that reports 256 MiB occupies only what is written until it
# is copied to a card.
$(IMAGE): $(ROOTFS_IMG) $(BOOT_IMG) Makefile
	@mkdir -p $(@D)
	@$(call image_geometry); \
	 echo "  IMAGE    $(IMAGE_SIZE_MIB) MiB: boot $$((boot_sectors / 2048)) MiB + root $$((root_sectors / 2048)) MiB"; \
	 rm -f $@.part; \
	 dd if=/dev/zero of=$@.part bs=1 count=0 seek=$$((total_sectors * 512)) 2>/dev/null; \
	 dd if=$(BOOT_IMG)   of=$@.part conv=notrunc                      2>/dev/null; \
	 dd if=$(ROOTFS_IMG) of=$@.part conv=notrunc bs=512 seek=$$root_start 2>/dev/null; \
	 $(call mbr_entry,131,$$root_start,$$root_sectors) \
	   | dd of=$@.part bs=1 seek=462 count=16 conv=notrunc 2>/dev/null
	@$(call assert_image,$@.part)
	@mv -f $@.part $@

# One MBR partition entry on stdout: status, CHS first, type, CHS last, LBA
# start, sector count. The CHS fields get the 0xFE/0xFF/0xFF "cannot be
# expressed" value that every tool writes past 8 GB - Linux and the Pi firmware
# read the LBA fields and ignore these.
define mbr_entry
	byte() { printf '\\0%03o' "$$1"; }; \
	le32() { byte $$(( $$1 & 255 )); byte $$(( ($$1 >> 8) & 255 )); \
	         byte $$(( ($$1 >> 16) & 255 )); byte $$(( ($$1 >> 24) & 255 )); }; \
	printf '%b' "$$( byte 0; byte 254; byte 255; byte 255; \
	                 byte $(1); byte 254; byte 255; byte 255; \
	                 le32 $(2); le32 $(3) )"
endef

# The partition table is the one part of this that no earlier step checked, and
# a wrong type byte or a partition that runs off the end of the image is a card
# that does not boot with nothing to see. Both entries are read back out of the
# finished image.
define assert_image
	set -e; \
	le32() { od -An -tu4 -j $$1 -N4 $(1) | tr -d ' '; }; \
	byte() { od -An -tx1 -j $$1 -N1 $(1) | tr -d ' '; }; \
	[ "$$(byte 450)" = "0c" ] \
	  || { echo "  FAIL     partition 1 is type 0x$$(byte 450), expected 0x0c (FAT32 LBA)" >&2; exit 1; }; \
	[ "$$(byte 466)" = "83" ] \
	  || { echo "  FAIL     partition 2 is type 0x$$(byte 466), expected 0x83 (Linux)" >&2; exit 1; }; \
	[ "$$(byte 510)$$(byte 511)" = "55aa" ] \
	  || { echo "  FAIL     no MBR signature" >&2; exit 1; }; \
	end=$$(( $$(le32 470) + $$(le32 474) )); \
	have=$$(( $$(wc -c < $(1)) / 512 )); \
	[ "$$end" -le "$$have" ] \
	  || { echo "  FAIL     partition 2 ends at sector $$end, past the $$have sector image" >&2; exit 1; }; \
	[ "$$(le32 470)" = "$$(( $$(le32 454) + $$(le32 458) ))" ] \
	  || { echo "  FAIL     partition 2 does not start where partition 1 ends" >&2; exit 1; }
endef

.PHONY: image-check
image-check: $(IMAGE) ## Re-read the finished image: filesystem, ownership, partition table
	@$(call assert_rootfs_image,$(ROOTFS_IMG))
	@$(call assert_image,$(IMAGE))
	@echo "  OK       $(IMAGE) is a clean ext4 owned by root, behind a valid MBR"

.PHONY: image-info
image-info: $(IMAGE) ## Show the finished image's layout
	@printf '  image    %s (%s MiB)\n' $(IMAGE) "$$(( $$(wc -c < $(IMAGE)) / 1048576 ))"
	@$(SHA256) $(IMAGE) | sed 's/^/  sha256   /'
	@le32() { od -An -tu4 -j $$1 -N4 $(IMAGE) | tr -d ' '; }; \
	 byte() { od -An -tx1 -j $$1 -N1 $(IMAGE) | tr -d ' '; }; \
	 printf '  part 1   type 0x%s  start %8s  %5s MiB  boot\n' \
	   "$$(byte 450)" "$$(le32 454)" "$$(( $$(le32 458) / 2048 ))"; \
	 printf '  part 2   type 0x%s  start %8s  %5s MiB  %s\n' \
	   "$$(byte 466)" "$$(le32 470)" "$$(( $$(le32 474) / 2048 ))" "$(ROOTFS_LABEL)"
	@$(E2FSCK) -fn $(ROOTFS_IMG) 2>&1 | tail -1 | sed 's/^/  ext4     /'
	@echo "  grows to the whole card on first boot; swap is added then too"
# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build output (keeps downloads)
	rm -rf $(BUILD_DIR)

.PHONY: distclean
distclean: clean ## Also remove downloaded artifacts
	rm -rf $(DL_DIR)

# Read one variable's value, for scripts and CI: make -s print-CHANNEL
print-%:
	@echo '$($*)'

.PHONY: help
help: ## Show this help
	@echo "SepiaOS root filesystem builder"
	@echo
	@echo "Targets:"
	@grep -hE '^[a-zA-Z_-]+([ ]+[a-zA-Z_-]+)*:.*?## ' $(MAKEFILE_LIST) \
	  | sed 's/:.*## /|/' \
	  | awk -F'|' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:"
	@printf "  %-18s %s\n" \
	  "CHANNEL"           "release or prerelease (default $(CHANNEL)); picks the boot release" \
	  "BOOT_TAG"          "pin a boot release instead of taking the latest one" \
	  "BOOT_REPO"         "where the boot partition comes from (default $(BOOT_REPO))" \
	  "TOOLCHAIN_VERSION" "cross-compiler release (default $(TOOLCHAIN_VERSION), $(TC_VENDOR) on $(HOST_OS))" \
	  "CROSS_COMPILE"     "use a toolchain you already have; nothing is downloaded" \
	  "MUSL_VERSION"      "pin a musl release instead of taking the latest one" \
	  "BUSYBOX_VERSION"   "pin a busybox release instead of taking the latest one" \
	  "FIRMWARE_TAG"      "pin the kernel modules' firmware tag (default: the boot release's)" \
	  "E2FS_VERSION"      "pin an e2fsprogs release instead of taking the latest one" \
	  "HOST_E2FSPROGS"    "directory of mke2fs/debugfs to use instead of building them" \
	  "SEPIAOS_VERSION"   "version stamped into the image (default $(SEPIAOS_VERSION))" \
	  "IMAGE_SIZE_MIB"    "shipped image size, power of two (default $(IMAGE_SIZE_MIB))" \
	  "ROOT_PASSWORD_HASH" "sha512-crypt for root; every $$ has to be doubled" \
	  "JOBS"              "parallelism for the source builds (default $(JOBS))"
	@echo
	@echo "Examples:"
	@echo "  make boot-partition                    latest pre-release boot partition"
	@echo "  make CHANNEL=release boot-partition    latest full release instead"
	@echo "  make BOOT_TAG=v0.1.0 boot-partition    a specific one"
	@echo "  make toolchain                         the aarch64 cross-compiler for this host"
	@echo "  make CROSS_COMPILE=aarch64-linux-gnu- toolchain-info    use a system one"
	@echo "  make musl                              latest musl, static and shared"
	@echo "  make MUSL_VERSION=1.2.5 musl           a specific one"
	@echo "  make busybox                           latest busybox, dynamic against musl"
	@echo "  make modules                           the boot kernel's modules, both trees"
	@echo "  make FIRMWARE_TAG=1.20260521 modules   modules from a specific firmware tag"
	@echo "  make rootfs                            stage the root filesystem tree"
	@echo "  make image                             the bootable card image"
	@echo "  make IMAGE_SIZE_MIB=512 image          a roomier one"
