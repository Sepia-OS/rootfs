#!/bin/sh
# Launch a built SepiaOS image under QEMU as a Raspberry Pi 3, with a screen.
#
#   tools/qemu.sh              boot the newest image in build/image
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
# The framebuffer the guest is told to use. Smaller means fewer, larger
# characters once the window is scaled up; larger means a bigger window at the
# same text size. 1024x768 with the 8x16 font is a 128x48 console.
RESOLUTION=1024x768

MACHINE=raspi3b
KERNEL=kernel8.img
DTB=bcm2710-rpi-3-b.dtb
# ttyAMA1, not ttyAMA0: under this machine the PL011 registers as ttyAMA1 and
# console=ttyAMA0 binds to nothing at all. Everything still appears here,
# because earlycon writes to the UART registers directly, but no console gets
# registered and userspace ends up with none.
CONSOLE=ttyAMA1
ROOTDEV=/dev/mmcblk0p2

die() { echo "qemu.sh: $*" >&2; exit 1; }

usage() {
	cat <<EOF
usage: tools/qemu.sh [options]

Boots a SepiaOS image under QEMU as a Raspberry Pi 3. The login prompt appears
in the window QEMU opens; the kernel log appears here. Ctrl-A X quits.

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

The window can be resized and the console scales with it. That is the only way
to make the text bigger: the Raspberry Pi kernel has just two console fonts
compiled in, VGA8x16 and VGA8x8, so fbcon=font: cannot go above 8x16 pixels.
A smaller -r therefore reads better once the window is enlarged, and -F -r
640x480 is about as large as the characters get.

The image itself is never written to. It is copied once to the working copy and
padded out to -s, which is what gives first boot a card to grow into; that
first boot is then run headlessly, once, before the window opens. After that
the same copy is reused, so a changed password or an added file is still there
next time. For a headless check that the image boots, use 'make test'.
EOF
}

while getopts 'i:c:s:r:D:Ffth' opt; do
	case "$opt" in
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

[ "$FRESH" = 1 ] && rm -f "$COPY" "$COPY.prepared"

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

if [ ! -f "$WORKDIR/$KERNEL" ] || [ "$IMAGE" -nt "$WORKDIR/$KERNEL" ]; then
	echo "qemu.sh: taking $KERNEL and $DTB out of the boot partition"
	mcopy -o -i "$IMAGE@@$(( start * 512 ))" "::$KERNEL" "::$DTB" "$WORKDIR/" \
		|| die "$KERNEL or $DTB is not in the boot partition of $IMAGE"
fi

# First boot grows the filesystem into the card and reboots, and that reboot is
# worth getting out of the way before the window opens. QEMU's raspi3b does not
# come back from a warm reset cleanly: the framebuffer comes back with its red
# and blue channels swapped, and the serial console stops producing output
# altogether, so an interactive session that starts before the reboot ends up
# unreadable in the window and silent in the terminal. A cold boot of an
# already-grown card has neither problem.
#
# The pass runs headless with the serial as the only console - no console=tty1 -
# so that what first boot says arrives in a log rather than on a framebuffer
# nobody is looking at.
PREPARED=$COPY.prepared
PREPARE_TIMEOUT=180

if [ ! -f "$PREPARED" ]; then
	prepare_log=$WORKDIR/first-boot.log
	echo "qemu.sh: running first boot headlessly, so the window opens on a settled system"
	rm -f "$prepare_log"
	qemu-system-aarch64 \
		-machine "$MACHINE" -display none \
		-kernel "$WORKDIR/$KERNEL" -dtb "$WORKDIR/$DTB" \
		-drive file="$COPY",format=raw,if=sd \
		-append "console=$CONSOLE,115200 root=$ROOTDEV rootfstype=ext4 rootwait" \
		-serial file:"$prepare_log" </dev/null >/dev/null 2>&1 &
	prepare_pid=$!
	i=0
	while [ "$i" -lt "$PREPARE_TIMEOUT" ]; do
		sleep 1
		i=$((i + 1))
		if grep -aq 'sepia-gettys: login prompt' "$prepare_log" 2>/dev/null; then break; fi
		if ! kill -0 "$prepare_pid" 2>/dev/null; then break; fi
	done
	sleep 1
	kill -9 "$prepare_pid" 2>/dev/null || true
	wait "$prepare_pid" 2>/dev/null || true
	if grep -aq 'sepia-gettys: login prompt' "$prepare_log" 2>/dev/null; then
		# The serial log carries CRLF; without stripping the CR every line
		# printed here returns the cursor and overwrites the one before it.
		tr -d '\r' < "$prepare_log" | sed -n 's/^sepia-firstboot: /qemu.sh:   /p' 
		touch "$PREPARED"
	else
		echo "qemu.sh: first boot did not finish in ${PREPARE_TIMEOUT}s - starting anyway"
		echo "qemu.sh: what it managed is in $prepare_log"
	fi
fi

fullscreen=
if [ "$FULLSCREEN" = 1 ]; then
	fullscreen=-full-screen
fi

snapshot=
if [ "$THROWAWAY" = 1 ]; then
	snapshot=,snapshot=on
	echo "qemu.sh: throwaway session - nothing written this run is kept"
fi

if [ "$DISPLAY_ARG" = none ]; then
	echo "qemu.sh: $MACHINE, $SIZE_MIB MiB card, no display - there is no way to log in"
else
	echo "qemu.sh: $MACHINE, $SIZE_MIB MiB card, ${RESOLUTION} screen, login prompt is in the QEMU window"
	echo "qemu.sh: resize the window to scale the console up; -F starts full screen"
fi
echo "qemu.sh: Ctrl-A X quits, Ctrl-A C opens the QEMU monitor"

exec qemu-system-aarch64 \
	-machine "$MACHINE" \
	${DISPLAY_ARG:+-display "$DISPLAY_ARG"} \
	-name "SepiaOS" \
	-kernel "$WORKDIR/$KERNEL" \
	-dtb "$WORKDIR/$DTB" \
	-drive file="$COPY",format=raw,if=sd"$snapshot" \
	-device usb-kbd \
	$fullscreen \
	-append "console=$CONSOLE,115200 console=tty1 $FBARGS root=$ROOTDEV rootfstype=ext4 rootwait" \
	-serial mon:stdio
