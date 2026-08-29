#!/bin/sh
# Launch a built SepiaOS image under QEMU as a Raspberry Pi, with a screen.
#
#   tools/qemu.sh              boot the newest image in build/image, as a Pi 4
#   tools/qemu.sh -b pi3       boot it as a Pi 3 instead
#   tools/qemu.sh -n           boot it with no network device at all
#   tools/qemu.sh -f           start over from a fresh copy of it
#   tools/qemu.sh -t           throw away everything written this session
#   tools/qemu.sh -i some.img  boot a particular image
#   tools/qemu.sh -F -r 640x480  full screen, with the largest readable text
#   tools/qemu.sh -h           the rest of the options
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
#
# Everything the guest prints on the serial line - the kernel log, and the boot
# scripts until the getty starts - comes out on this terminal, along with
# QEMU's own errors. Ctrl-A then X quits; Ctrl-A then C reaches the QEMU
# monitor.
#
# There is deliberately no earlycon= here, unlike the test targets in the
# Makefile. earlycon prints everything from before the real console registers,
# and then the kernel replays that same buffer to the console when it does, so
# every early line arrives twice on this terminal. Worth it when diagnosing a
# kernel that will not boot; not worth it when using one that does.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

IMAGE=
WORKDIR=$here/build/qemu
COPY=
SIZE_MIB=4096
FRESH=0
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
# ttyAMA1 and console=ttyAMA0 binds to nothing at all. Everything still appears
# here, because earlycon writes to the UART registers directly, but no console
# gets registered and userspace ends up with none.
CONSOLE=ttyAMA1

die() { echo "qemu.sh: $*" >&2; exit 1; }

usage() {
	cat <<EOF
usage: tools/qemu.sh [options]

Boots a SepiaOS image under QEMU as a Raspberry Pi. The login prompt appears
in the window QEMU opens; the kernel log appears here. Ctrl-A X quits.

  -b BOARD   pi-zero2w, pi3 or pi4 (default: $BOARD)
  -n         no network device (by default the guest gets one)
  -i IMAGE   image to boot (default: the newest build/image/sepiaos-*.img)
  -c COPY    working copy to boot (default: build/qemu/run.img)
  -s MiB     size of the working copy, a power of two (default: $SIZE_MIB)
  -f         start from a fresh copy: forget the previous session
  -t         throwaway session: keep the copy, discard what this run writes
  -r WxH     framebuffer the guest uses (default: $RESOLUTION)
  -F         start full screen - with scaling on, this is the largest the
             console text can get
  -D DISPLAY pass a specific -display to QEMU (cocoa, gtk, sdl, vnc=:1, none)
             instead of the default, which is the host's own with scaling on
  -h         this help

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
again, which is the only way a reboot works here - see the comment above the
launch loop. 'halt', 'poweroff' and Ctrl-A X end the session instead.

The image itself is never written to. It is copied once to the working copy and
padded out to -s, which is what gives first boot a card to grow into. That
first boot happens in the window: it asks what the network and the keyboard
should be, grows the filesystem and reboots, and the guest comes straight back.
After that the same copy is reused, so a changed password or an added file is
still there next time. For a headless check that the image boots, use
'make test'.
EOF
}

while getopts 'b:i:c:s:r:D:Ffnth' opt; do
	case "$opt" in
		b) BOARD=$OPTARG ;;
		n) NETWORK=0 ;;
		i) IMAGE=$OPTARG ;;
		c) COPY=$OPTARG ;;
		s) SIZE_MIB=$OPTARG ;;
		r) RESOLUTION=$OPTARG ;;
		D) DISPLAY_ARG=$OPTARG ;;
		F) FULLSCREEN=1 ;;
		f) FRESH=1 ;;
		t) THROWAWAY=1 ;;
		h) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done

# The boards this can boot, and what QEMU has to be told for each. The same
# table the Makefile's test targets use, with the same two surprises in it:
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
# other -m outright - "Invalid RAM size, should be 1 GiB" - which was measured
# by asking each machine for 512M, 1G, 2G, 4G and 8G. So -m here states the
# maximum rather than choosing it, and a QEMU that ever changes the rule says
# so on the way up instead of quietly booting with less. There is no machine
# property for the board revision either, so no 8 GiB Pi 4 is to be had.
case "$MACHINE" in
	raspi3b) MEMORY=1G; ROOTDEV=/dev/mmcblk0p2 ;;
	raspi4b) MEMORY=2G; ROOTDEV=/dev/mmcblk1p2 ;;
esac

command -v qemu-system-aarch64 >/dev/null 2>&1 \
	|| die "qemu-system-aarch64 is not installed (brew install qemu / apt-get install qemu-system-arm)"
command -v mcopy >/dev/null 2>&1 \
	|| die "mtools is needed to read the kernel out of the boot partition (brew install mtools / apt-get install mtools)"

if [ -z "$IMAGE" ]; then
	# Newest first, so a rebuilt image is picked up without naming it.
	IMAGE=$(ls -t "$here"/build/image/sepiaos-*.img 2>/dev/null | head -1 || true)
	[ -n "$IMAGE" ] || die "no image in $here/build/image - run 'make image' first"
fi
[ -f "$IMAGE" ] || die "$IMAGE does not exist"

case "$SIZE_MIB" in
	''|*[!0-9]*) die "-s takes a size in MiB, got '$SIZE_MIB'" ;;
esac
# QEMU refuses any SD image whose size is not a power of two, and the message
# it gives ("Invalid SD card size") does not say that.
[ "$SIZE_MIB" -ge 256 ] && [ $(( SIZE_MIB & (SIZE_MIB - 1) )) -eq 0 ] \
	|| die "-s must be a power of two and at least 256, got $SIZE_MIB (QEMU rejects any other SD image size)"

case "$RESOLUTION" in
	[0-9]*x[0-9]*) ;;
	*) die "-r takes a resolution like 1024x768, got '$RESOLUTION'" ;;
esac
FBWIDTH=${RESOLUTION%x*}
FBHEIGHT=${RESOLUTION#*x}

# QEMU never runs the firmware, so config.txt cannot set the framebuffer size
# the way it would on a real board; the kernel's own module parameters are what
# is left, and they are read whether the driver is builtin or not.
FBARGS="bcm2708_fb.fbwidth=$FBWIDTH bcm2708_fb.fbheight=$FBHEIGHT"

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

[ -n "$COPY" ] || COPY=$WORKDIR/run.img
mkdir -p "$(dirname -- "$COPY")" "$WORKDIR"

[ "$FRESH" = 1 ] && rm -f "$COPY"

if [ ! -f "$COPY" ]; then
	echo "qemu.sh: copying $(basename -- "$IMAGE") to $COPY and padding it to $SIZE_MIB MiB"
	cp "$IMAGE" "$COPY"
	# Seeking past the end leaves a sparse file, so a 4 GiB card costs what is
	# written to it and not 4 GiB.
	dd if=/dev/zero of="$COPY" bs=1 count=0 seek=$(( SIZE_MIB * 1048576 )) 2>/dev/null \
		|| die "could not pad $COPY to $SIZE_MIB MiB"
	echo "qemu.sh: first boot will grow the root filesystem into it and add swap"
fi

# Partition 1 starts wherever this image's own MBR says it does: the LBA start
# is the 32-bit little-endian field at offset 454.
start=$(od -An -tu4 -j 454 -N4 "$IMAGE" | tr -d ' ')
[ -n "$start" ] && [ "$start" -gt 0 ] || die "$IMAGE has no partition 1"

# The device tree is named per board, so switching boards extracts the one the
# new board needs rather than reusing whatever was there.
if [ ! -f "$WORKDIR/$KERNEL" ] || [ ! -f "$WORKDIR/$DTB" ] \
   || [ "$IMAGE" -nt "$WORKDIR/$KERNEL" ]; then
	echo "qemu.sh: taking $KERNEL and $DTB out of the boot partition"
	mcopy -o -i "$IMAGE@@$(( start * 512 ))" "::$KERNEL" "::$DTB" "$WORKDIR/" \
		|| die "$KERNEL or $DTB is not in the boot partition of $IMAGE"
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
# Verified by screendump both ways: as shipped, typing at the Pi 4 login prompt
# does nothing at all; with the node enabled the keyboard comes up on
# fe980000.usb and `root` appears at the prompt.
#
# Only the extracted copy under build/qemu is touched, never the image, and
# only for the machine that needs it - the Pi 3 and the Zero 2 W have their
# controller enabled already, which is why they have always worked here.
if [ -n "$USB_NODE" ]; then
	if command -v fdtput >/dev/null 2>&1 && command -v fdtget >/dev/null 2>&1; then
		if [ "$(fdtget "$WORKDIR/$DTB" "$USB_NODE" status 2>/dev/null)" != okay ]; then
			fdtput -t s "$WORKDIR/$DTB" "$USB_NODE" status okay \
				|| die "could not enable $USB_NODE in $WORKDIR/$DTB"
			echo "qemu.sh: enabled the on-SoC USB controller in $DTB, so the keyboard works"
		fi
	else
		echo "qemu.sh: dtc is not installed, so this $BOARD gets a screen and no keyboard."
		echo "qemu.sh: 'brew install dtc' (or apt-get install device-tree-compiler) fixes it;"
		echo "qemu.sh: 'tools/qemu.sh -b pi3' needs nothing."
	fi
fi

# First boot happens in the window, like everything else. It grows the
# filesystem into the card, asks its two setup questions and reboots, and all
# three want a person watching: the questions are on the framebuffer, and the
# kernel output belongs on this terminal.
#
# It used to run headlessly here first, on the grounds that QEMU's raspi3b does
# not come back from a warm reset cleanly - the framebuffer returns with its
# red and blue channels swapped and the serial goes quiet. That does not apply
# to the session below, which passes -no-reboot: the guest's reset becomes a
# clean exit and the loop starts it again cold, which is the case that was
# always fine. Running it headlessly also swallowed the setup questions, since
# a serial console is not one sepia-firstboot will ask on.

fullscreen=
if [ "$FULLSCREEN" = 1 ]; then
	fullscreen=-full-screen
fi

# QEMU emulates no Pi's own ethernet on any board it has: it says so about the
# Pi 4 on the way up ("brcm,bcm2711-genet-v5 has been disabled!"), and it has no
# model of the LAN9514 behind the Pi 3's internal USB hub either. So a network
# here means a USB one. The guest calls it usb0 rather than eth0, loads a module
# for it - nothing in the image autoloads modules, sepia-network does that - and
# udhcpc takes the 10.0.2.15 lease QEMU's built-in server always hands out.
#
# Only this run gets it, never the first-boot pass above. That pass reboots, and
# QEMU's raspi3b does not come back from a warm reset with a USB device attached
# to its dwc2 controller - the same reason the keyboard is not attached there.
netdevice=
if [ "$NETWORK" = 1 ]; then
	netdevice="-netdev user,id=n0 -device usb-net,netdev=n0"
fi

snapshot=
if [ "$THROWAWAY" = 1 ]; then
	snapshot=,snapshot=on
	echo "qemu.sh: throwaway session - nothing written this run is kept"
fi

if [ "$DISPLAY_ARG" = none ]; then
	echo "qemu.sh: $BOARD as $MACHINE, $MEMORY, $SIZE_MIB MiB card, no display - there is no way to log in"
else
	echo "qemu.sh: $BOARD as $MACHINE, $MEMORY, $SIZE_MIB MiB card, ${RESOLUTION} screen, login prompt is in the QEMU window"
	echo "qemu.sh: resize the window to scale the console up; -F starts full screen"
fi
if [ "$NETWORK" = 1 ]; then
	echo "qemu.sh: with a network - the guest leases 10.0.2.15, the host is 10.0.2.2"
fi
echo "qemu.sh: Ctrl-A X quits, Ctrl-A C opens the QEMU monitor"

# `reboot` in the guest restarts QEMU rather than resetting the machine, and
# that is not a preference either.
#
# QEMU's raspi3b does not come back from a warm reset while a USB device is
# attached to its dwc2 controller. Tested all four combinations: with no USB
# keyboard it resets and boots again whether or not the framebuffer console is
# in use; with `-device usb-kbd` it never comes back, and the guest reaches
# `reboot: Restarting system` identically in every case. A USB keyboard is the
# only way to type on this machine - there is no PS/2 controller on a Pi - so
# the keyboard cannot be given up, and the reset cannot be used.
#
# So `-no-reboot` turns the guest's reset request into a clean QEMU exit, and
# this loop starts it again. The guest boots cold each time, which also avoids
# the two things a warm reset leaves behind here: a framebuffer whose red and
# blue channels have swapped, and a serial console that has gone quiet.
#
# Telling a reboot from a quit needs the kernel, because both exit 0. The
# console is logged to a file as well as shown, and `reboot: Restarting system`
# - printed at emerg level, so it survives the console quietening rcS does - is
# what distinguishes them. `halt` and `poweroff` print something else and so
# stay down, which is what they are for. The log is truncated on every launch,
# so a marker from an earlier boot cannot restart anything.
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
		-drive file="$COPY",format=raw,if=sd"$snapshot" \
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
		echo "qemu.sh: the guest has rebooted three times in under ten seconds each;"
		echo "qemu.sh: stopping rather than looping. Console log: $CONSOLE_LOG"
		break
	fi

	echo "qemu.sh: the guest asked to reboot; starting it again"
done
