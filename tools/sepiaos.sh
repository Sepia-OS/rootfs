#!/bin/sh
# Boot the SepiaOS image that sits next to this script under QEMU.
#
#   ./sepiaos.sh              grow the image beside it to 128 GiB and boot it
#   ./sepiaos.sh -s 32        grow it to 32 GiB instead
#   ./sepiaos.sh -b pi3       boot it as a Pi 3 rather than a Pi 4
#   ./sepiaos.sh -t           throwaway run: keep the image exactly as it is
#   ./sepiaos.sh -h           the rest of the options
#
# This is the companion to a release rather than to the build tree. Unpack
# sepiaos-vX.Y.Z.img.xz, drop this script beside it, and run it: it finds the
# .img in its own directory, grows that image in place and boots it. Everything
# the guest writes stays in the image, so a password change or an installed
# file is still there next time.
#
# tools/qemu.sh in the source tree does the opposite - it boots a disposable
# copy under build/qemu and leaves the built image untouched. Use that one
# while developing; use this one to actually live in a card image.
#
# It is meant to be symlinked. `ln -s /path/to/sepiaos.sh ~/bin/sepiaos` works:
# the script walks the symlink chain to find where it physically lives and
# looks for the image there, not in whatever directory it was called from.
#
# QEMU opens a window, and that window is where the login prompt is. It is not
# a preference: the serial line under QEMU is output-only. The PL011 comes up
# as a console with no tty device behind it - /proc/consoles says `-W-`, write
# and no read - so anything typed at -serial never reaches the guest. The
# framebuffer console and a USB keyboard are the only way in, which is why
# console=tty1 comes last on the command line (making it /dev/console, and so
# where the getty lands) and why -device usb-kbd is here.
#
# The kernel and device tree are read out of the image's own boot partition.
# QEMU emulates the ARM side of a Pi and not the VideoCore boot ROM, so it
# never reads bootcode.bin, start.elf or config.txt off the card and has to be
# handed the kernel directly; taking it from anywhere else would boot something
# the image does not contain.

set -eu

die() { echo "sepiaos.sh: $*" >&2; exit 1; }

# --- where this script physically lives -------------------------------------
#
# `readlink -f` would do this in one line, but it is a GNU extension that macOS
# only grew in 12.3, so the chain is walked by hand. A relative link resolves
# against the directory of the link itself and not against the caller's, which
# is what makes ~/bin/sepiaos -> ../src/sepiaos.sh find the right place. The hop
# count is a guard against a symlink loop, which would otherwise spin forever.
self=$0
hops=0
while [ -L "$self" ]; do
	hops=$((hops + 1))
	[ "$hops" -le 40 ] || die "$0 is a symlink loop"
	link=$(readlink -- "$self")
	case "$link" in
		/*) self=$link ;;
		*)  self=$(dirname -- "$self")/$link ;;
	esac
done
here=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd -P) \
	|| die "cannot reach the directory $self is in"

# Saved before anything changes directory, for two reasons. A relative -i is
# relative to where the user typed it, so it has to be resolved against this
# and not against $here. And the shell is put back here when QEMU is done -
# which cannot change the directory of the shell that *ran* this script, since
# no child process can do that, but does mean everything after the launch runs
# where it started.
called_from=$(pwd -P)
trap 'cd -- "$called_from" 2>/dev/null || true' EXIT

# --- options ----------------------------------------------------------------

IMAGE=
SIZE=128G
EXTRACT=0
THROWAWAY=0
DISPLAY_ARG=
FULLSCREEN=0
NETWORK=1
# The framebuffer the guest is told to use. Smaller means fewer, larger
# characters once the window is scaled up; larger means a bigger window at the
# same text size. 1024x768 with the 8x16 font is a 128x48 console.
RESOLUTION=1024x768

BOARD=pi4
# One kernel for all three: BCM2837 and BCM2711 both boot kernel8.img, and the
# kernel_2712.img the image also carries is for boards QEMU cannot emulate.
KERNEL=kernel8.img
# ttyAMA1, not ttyAMA0: on every one of these machines the PL011 registers as
# ttyAMA1 and console=ttyAMA0 binds to nothing at all.
CONSOLE=ttyAMA1

usage() {
	cat <<EOF
usage: sepiaos.sh [options]

Grows the SepiaOS image in this script's own directory to $SIZE and boots it
under QEMU as a Raspberry Pi. The login prompt appears in the window QEMU
opens; the kernel log appears here. Ctrl-A X quits.

  -s SIZE    card size: a plain number is GiB, or suffix it M or G.
             Must be a power of two (default: $SIZE)
  -b BOARD   pi-zero2w, pi3 or pi4 (default: $BOARD)
  -i IMAGE   boot this image instead of the one found next to the script
  -n         no network device (by default the guest gets one)
  -t         throwaway run: nothing the guest writes reaches the image
  -x         re-read the kernel and device tree out of the image
  -r WxH     framebuffer the guest uses (default: $RESOLUTION)
  -F         start full screen - with scaling on, this is the largest the
             console text can get
  -D DISPLAY pass a specific -display to QEMU (cocoa, gtk, sdl, vnc=:1, none)
             instead of the default, which is the host's own with scaling on
  -h         this help

The image is grown in place and never shrunk. Growing only appends a hole, so
a 128 GiB card costs what has been written to it rather than 128 GiB - as long
as the filesystem underneath supports sparse files, which APFS and ext4 do and
exFAT and HFS+ do not. An image that is already larger than -s is left alone
rather than truncated, because truncating one would destroy the filesystem
that first boot grew into it.

The size has to be a power of two because QEMU refuses every other SD card
size, and the message it gives for it ("Invalid SD card size") does not say so.

First boot happens in the window: it asks what the network and the keyboard
should be, grows the root filesystem into the whole card and reboots, and the
guest comes straight back. After that the same image is reused, so anything
changed in the guest is still there next time.

-t suspends only that persistence: the guest boots against a scratch overlay
and everything it writes is dropped when QEMU exits. The image file itself is
still grown to -s beforehand, because growing appends a hole rather than data
and the card would otherwise be the size the release shipped.

The guest is given a network unless -n says otherwise, on QEMU's user-mode
networking: the guest leases 10.0.2.15, the host is 10.0.2.2 and answers DNS on
10.0.2.3. That is enough to reach out - ping, nslookup, wget - and nothing can
reach in without a -hostfwd, which this does not set up. The device is a USB
one because QEMU emulates no Pi's own ethernet on any board.

A Pi 4 needs dtc installed ('brew install dtc'). Its device tree disables the
on-SoC USB controller, because a real Pi 4 has its ports behind PCIe, which
QEMU does not emulate - so the emulated keyboard never appears unless that one
property is turned back on in the extracted copy of the tree. Without dtc the
Pi 4 still boots and can be watched; it just cannot be typed at.

Each board is given the most memory QEMU will give it: 1 GiB as a Pi 3 or a
Zero 2 W, 2 GiB as a Pi 4. That is not an option because QEMU does not make it
one - each machine is pinned to the memory of the board revision it emulates
and refuses every other size.

The window can be resized and the console scales with it. That is the only way
to make the text bigger: the Raspberry Pi kernel has just two console fonts
compiled in, VGA8x16 and VGA8x8, so fbcon=font: cannot go above 8x16 pixels.
A smaller -r therefore reads better once the window is enlarged, and -F -r
640x480 is about as large as the characters get.

Typing 'reboot' in the guest restarts it: QEMU exits and this script starts it
again, which is the only way a reboot works here. 'halt', 'poweroff' and
Ctrl-A X end the session instead.
EOF
}

while getopts 's:b:i:r:D:Fntxh' opt; do
	case "$opt" in
		s) SIZE=$OPTARG ;;
		b) BOARD=$OPTARG ;;
		i) IMAGE=$OPTARG ;;
		n) NETWORK=0 ;;
		t) THROWAWAY=1 ;;
		x) EXTRACT=1 ;;
		r) RESOLUTION=$OPTARG ;;
		D) DISPLAY_ARG=$OPTARG ;;
		F) FULLSCREEN=1 ;;
		h) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done

# Resolved here, while the working directory is still the caller's, so that
# `sepiaos -i ./other.img` means the file the user can see.
if [ -n "$IMAGE" ]; then
	case "$IMAGE" in
		/*) ;;
		*)  IMAGE=$called_from/$IMAGE ;;
	esac
fi

# --- the size ---------------------------------------------------------------
#
# A bare number is GiB, because the default is stated in GiB and a card is
# talked about in GiB. M is there for the small sizes that are still useful -
# 512M boots and leaves almost nothing to grow into, which is a fine way to see
# what a full card does.
case "$SIZE" in
	*[Gg]) size_n=${SIZE%?}; size_unit=G ;;
	*[Mm]) size_n=${SIZE%?}; size_unit=M ;;
	*)     size_n=$SIZE;     size_unit=G ;;
esac
case "$size_n" in
	''|*[!0-9]*) die "-s takes a size like 128, 128G or 512M, got '$SIZE'" ;;
esac
if [ "$size_unit" = G ]; then
	SIZE_MIB=$(( size_n * 1024 ))
else
	SIZE_MIB=$size_n
fi

# QEMU refuses any SD image whose size is not a power of two, and the message
# it gives ("Invalid SD card size") does not say that. 128 GiB is 2^37 bytes,
# so the default passes; 100 GiB would not.
[ "$SIZE_MIB" -ge 256 ] && [ $(( SIZE_MIB & (SIZE_MIB - 1) )) -eq 0 ] \
	|| die "-s must be a power of two and at least 256 MiB, got $SIZE_MIB MiB (QEMU rejects any other SD image size)"

# --- the board --------------------------------------------------------------
#
# The same table the Makefile's test targets use, with the same two surprises:
#
#   - The Zero 2 W is emulated as a 3B and not a 3A+, because its device tree
#     takes a synchronous external abort in bcm2835_power_probe on raspi3ap.
#     One consequence worth knowing: it therefore gets the 3B's gigabyte where
#     the real board has half of one.
#   - The Pi 4 exposes the card as mmcblk1 where BCM2837 and real hardware both
#     use mmcblk0, so root= follows the machine rather than the board.
#
# Pi 5 and CM5 are absent because QEMU has no BCM2712 machine at all.
USB_NODE=
case "$BOARD" in
	pi-zero2w|zero2w) BOARD=pi-zero2w; MACHINE=raspi3b; DTB=bcm2710-rpi-zero-2-w.dtb ;;
	pi3)              MACHINE=raspi3b; DTB=bcm2710-rpi-3-b.dtb ;;
	pi4)              MACHINE=raspi4b; DTB=bcm2711-rpi-4-b.dtb; USB_NODE=/soc/usb@7e980000 ;;
	*) die "-b takes pi-zero2w, pi3 or pi4, got '$BOARD'" ;;
esac

# How much memory each board gets, and it is the most there is. QEMU pins every
# raspi machine to the RAM of the board revision it emulates and rejects any
# other -m outright - "Invalid RAM size, should be 1 GiB". So -m here states the
# maximum rather than choosing it, and a QEMU that ever changes the rule says so
# on the way up instead of quietly booting with less.
case "$MACHINE" in
	raspi3b) MEMORY=1G; ROOTDEV=/dev/mmcblk0p2 ;;
	raspi4b) MEMORY=2G; ROOTDEV=/dev/mmcblk1p2 ;;
esac

case "$RESOLUTION" in
	[0-9]*x[0-9]*) ;;
	*) die "-r takes a resolution like 1024x768, got '$RESOLUTION'" ;;
esac
FBWIDTH=${RESOLUTION%x*}
FBHEIGHT=${RESOLUTION#*x}

command -v qemu-system-aarch64 >/dev/null 2>&1 \
	|| die "qemu-system-aarch64 is not installed (brew install qemu / apt-get install qemu-system-arm)"
command -v mcopy >/dev/null 2>&1 \
	|| die "mtools is needed to read the kernel out of the boot partition (brew install mtools / apt-get install mtools)"

# --- into the script's own directory ----------------------------------------

cd -- "$here" || die "cannot enter $here"

WORKDIR=$here/.sepiaos-qemu
mkdir -p "$WORKDIR" || die "cannot write to $here - this script needs a writable directory"

# --- the image --------------------------------------------------------------
#
# One .img in the directory is the whole point, so two is an error rather than
# a guess: this script grows and then writes to whichever it picks, and picking
# the wrong one is not something a user would notice until later.
if [ -z "$IMAGE" ]; then
	set -- "$here"/*.img
	if [ ! -e "$1" ]; then
		die "no .img file in $here - unpack a release image beside this script, or name one with -i"
	fi
	if [ "$#" -gt 1 ]; then
		echo "sepiaos.sh: $# images in $here:" >&2
		for img in "$@"; do echo "  $(basename -- "$img")" >&2; done
		die "name the one to boot with -i"
	fi
	IMAGE=$1
fi
[ -f "$IMAGE" ] || die "$IMAGE does not exist"

# stat's spelling is the BSD one on macOS and the GNU one everywhere else, and
# neither accepts the other's flag. `wc -c` would be portable but reads the
# whole file, which on a sparse 128 GiB card is not a small thing to do.
file_size() {
	stat -f %z -- "$1" 2>/dev/null || stat -c %s -- "$1" 2>/dev/null
}

size_now=$(file_size "$IMAGE") || die "cannot read the size of $IMAGE"
want=$(( SIZE_MIB * 1048576 ))

if [ "$size_now" -eq "$want" ]; then
	# Already the size asked for, which is the normal case from the second run
	# onwards. Said out loud rather than passed over in silence, so that a run
	# that does nothing to the image looks different from one that grew it.
	echo "sepiaos.sh: $(basename -- "$IMAGE") is already $SIZE_MIB MiB - not resizing it"
elif [ "$size_now" -lt "$want" ]; then
	echo "sepiaos.sh: growing $(basename -- "$IMAGE") from $(( size_now / 1048576 )) MiB to $SIZE_MIB MiB"
	# Seeking past the end leaves a hole rather than writing anything, so the
	# card costs what has been stored in it and not its nominal size.
	dd if=/dev/zero of="$IMAGE" bs=1 count=0 seek="$want" 2>/dev/null \
		|| die "could not grow $IMAGE to $SIZE_MIB MiB"
	echo "sepiaos.sh: first boot will grow the root filesystem into it and add swap"
else
	# Never truncated. The image is the only copy, and by the time it is bigger
	# than this it is bigger because a first boot already grew a filesystem into
	# the space - cutting it back to -s would take the end of that filesystem
	# with it.
	SIZE_MIB=$(( size_now / 1048576 ))
	[ $(( SIZE_MIB & (SIZE_MIB - 1) )) -eq 0 ] \
		|| die "$IMAGE is $SIZE_MIB MiB, which is not a power of two, so QEMU will not take it as a card"
	echo "sepiaos.sh: image is already $SIZE_MIB MiB, larger than the $(( want / 1048576 )) MiB asked for - left as it is"
fi

# Partition 1 starts wherever this image's own MBR says it does: the LBA start
# is the 32-bit little-endian field at offset 454.
start=$(od -An -tu4 -j 454 -N4 "$IMAGE" | tr -d ' ')
[ -n "$start" ] && [ "$start" -gt 0 ] || die "$IMAGE has no partition 1"

# --- the kernel and the device tree -----------------------------------------
#
# Extracted once and then left alone. The image's own timestamp cannot be the
# trigger the way it is in tools/qemu.sh, because here the guest writes to the
# image on every boot and it would re-extract every launch. What actually
# changes what is needed is the board, so that is what is recorded; -x forces it
# for the case this cannot see, which is a new image dropped in under the same
# name.
STAMP=$WORKDIR/extracted
if [ "$EXTRACT" = 1 ] || [ ! -f "$WORKDIR/$KERNEL" ] || [ ! -f "$WORKDIR/$DTB" ] \
   || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$BOARD $(basename -- "$IMAGE")" ]; then
	echo "sepiaos.sh: taking $KERNEL and $DTB out of the boot partition"
	mcopy -o -i "$IMAGE@@$(( start * 512 ))" "::$KERNEL" "::$DTB" "$WORKDIR/" \
		|| die "$KERNEL or $DTB is not in the boot partition of $IMAGE"
	echo "$BOARD $(basename -- "$IMAGE")" > "$STAMP"
fi

# A Pi 4 has no keyboard under QEMU until this one property is flipped, and
# without a keyboard the window shows a login prompt that cannot be answered.
#
# On a real Pi 4 the USB ports hang off a VL805 XHCI behind PCIe, so
# bcm2711-rpi-4-b.dtb ships the on-SoC controller as status = "disabled" and
# only the dwc2 overlay ever turns it on. QEMU is the other way round: it
# emulates the on-SoC controller and no PCIe at all. So -device usb-kbd attaches
# on QEMU's side - `info usb` lists it - and the guest never enumerates it,
# because as far as the kernel is concerned there is no controller there.
#
# Only the extracted copy under .sepiaos-qemu is touched, never the image, and
# only for the machine that needs it - the Pi 3 and the Zero 2 W have their
# controller enabled already.
if [ -n "$USB_NODE" ]; then
	if command -v fdtput >/dev/null 2>&1 && command -v fdtget >/dev/null 2>&1; then
		if [ "$(fdtget "$WORKDIR/$DTB" "$USB_NODE" status 2>/dev/null)" != okay ]; then
			fdtput -t s "$WORKDIR/$DTB" "$USB_NODE" status okay \
				|| die "could not enable $USB_NODE in $WORKDIR/$DTB"
			echo "sepiaos.sh: enabled the on-SoC USB controller in $DTB, so the keyboard works"
		fi
	else
		echo "sepiaos.sh: dtc is not installed, so this $BOARD gets a screen and no keyboard."
		echo "sepiaos.sh: 'brew install dtc' (or apt-get install device-tree-compiler) fixes it;"
		echo "sepiaos.sh: 'sepiaos.sh -b pi3' needs nothing."
	fi
fi

# --- the display ------------------------------------------------------------
#
# zoom-to-fit is what makes the window resizable and the guest image scale with
# it. Without it the window is fixed at the guest's resolution, and with an
# 8x16 font on a high-density display that is barely readable. The backend is
# looked up rather than assumed: this QEMU build may not have the one this host
# would normally use.
if [ -z "$DISPLAY_ARG" ]; then
	backends=$(qemu-system-aarch64 -display help 2>/dev/null || true)
	if printf '%s\n' "$backends" | grep -q '^cocoa$'; then
		DISPLAY_ARG=cocoa,zoom-to-fit=on
	elif printf '%s\n' "$backends" | grep -q '^gtk$'; then
		DISPLAY_ARG=gtk,zoom-to-fit=on
	fi
fi

fullscreen=
if [ "$FULLSCREEN" = 1 ]; then
	fullscreen=-full-screen
fi

# QEMU never runs the firmware, so config.txt cannot set the framebuffer size
# the way it would on a real board; the kernel's own module parameters are what
# is left, and they are read whether the driver is builtin or not.
FBARGS="bcm2708_fb.fbwidth=$FBWIDTH bcm2708_fb.fbheight=$FBHEIGHT"

# QEMU emulates no Pi's own ethernet on any board it has: it says so about the
# Pi 4 on the way up ("brcm,bcm2711-genet-v5 has been disabled!"), and it has no
# model of the LAN9514 behind the Pi 3's internal USB hub either. So a network
# here means a USB one. The guest calls it usb0 rather than eth0, loads a module
# for it - nothing in the image autoloads modules, sepia-network does that - and
# udhcpc takes the 10.0.2.15 lease QEMU's built-in server always hands out.
netdevice=
if [ "$NETWORK" = 1 ]; then
	netdevice="-netdev user,id=n0 -device usb-net,netdev=n0"
fi

snapshot=
if [ "$THROWAWAY" = 1 ]; then
	snapshot=,snapshot=on
fi

echo "sepiaos.sh: $(basename -- "$IMAGE") as a $BOARD ($MACHINE, $MEMORY, $SIZE_MIB MiB card)"
if [ "$DISPLAY_ARG" = none ]; then
	echo "sepiaos.sh: no display - there is no way to log in"
else
	echo "sepiaos.sh: login prompt is in the QEMU window; resize it to scale the console up"
fi
if [ "$NETWORK" = 1 ]; then
	echo "sepiaos.sh: with a network - the guest leases 10.0.2.15, the host is 10.0.2.2"
fi
if [ "$THROWAWAY" = 1 ]; then
	echo "sepiaos.sh: throwaway run - the guest's writes are dropped when QEMU exits"
fi
echo "sepiaos.sh: Ctrl-A X quits, Ctrl-A C opens the QEMU monitor"

# --- launch -----------------------------------------------------------------
#
# `reboot` in the guest restarts QEMU rather than resetting the machine, and
# that is not a preference.
#
# QEMU's raspi3b does not come back from a warm reset while a USB device is
# attached to its dwc2 controller: with no USB keyboard it resets and boots
# again, with `-device usb-kbd` it never comes back, and the guest reaches
# `reboot: Restarting system` identically either way. A USB keyboard is the only
# way to type on this machine - there is no PS/2 controller on a Pi - so the
# keyboard cannot be given up, and the reset cannot be used.
#
# So `-no-reboot` turns the guest's reset request into a clean QEMU exit, and
# this loop starts it again. The guest boots cold each time, which also avoids
# the two things a warm reset leaves behind here: a framebuffer whose red and
# blue channels have swapped, and a serial console that has gone quiet. This
# matters most on the very first run, because first boot grows the filesystem
# and then reboots into it.
#
# Telling a reboot from a quit needs the kernel, because both exit 0. The
# console is logged to a file as well as shown, and `reboot: Restarting system`
# - printed at emerg level, so it survives the console quietening rcS does - is
# what distinguishes them. `halt` and `poweroff` print something else and so
# stay down. The log is truncated on every launch, so a marker from an earlier
# boot cannot restart anything.
CONSOLE_LOG=$WORKDIR/console.log
fast=0

while :; do
	started=$(date +%s)

	qemu-system-aarch64 \
		-machine "$MACHINE" -m "$MEMORY" \
		${DISPLAY_ARG:+-display "$DISPLAY_ARG"} \
		-name "SepiaOS" \
		-no-reboot \
		-kernel "$WORKDIR/$KERNEL" \
		-dtb "$WORKDIR/$DTB" \
		-drive file="$IMAGE",format=raw,if=sd"$snapshot" \
		-device usb-kbd \
		$netdevice \
		$fullscreen \
		-append "console=$CONSOLE,115200 console=tty1 $FBARGS root=$ROOTDEV rootfstype=ext4 rootwait" \
		-chardev stdio,id=sepia-console,mux=on,signal=off,logfile="$CONSOLE_LOG" \
		-serial chardev:sepia-console \
		-mon chardev=sepia-console || true

	if ! tail -c 8192 "$CONSOLE_LOG" 2>/dev/null | grep -aq 'Restarting system'; then
		break
	fi

	# A guest that reboots the moment it starts would otherwise spin here.
	if [ $(( $(date +%s) - started )) -lt 10 ]; then
		fast=$((fast + 1))
	else
		fast=0
	fi
	if [ "$fast" -ge 3 ]; then
		echo "sepiaos.sh: the guest has rebooted three times in under ten seconds each;"
		echo "sepiaos.sh: stopping rather than looping. Console log: $CONSOLE_LOG"
		break
	fi

	echo "sepiaos.sh: the guest asked to reboot; starting it again"
done

# Back where the user was, as promised. The EXIT trap above does this too, for
# the paths that do not reach here.
cd -- "$called_from"
