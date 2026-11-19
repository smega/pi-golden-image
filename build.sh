#!/bin/bash
# Runs inside a privileged container (see Dockerfile + README). Loop-mounts
# the input Raspberry Pi OS Lite (arm64) image, chroots into it with
# qemu-aarch64-static, removes the packages listed in strip-packages.list,
# cleans up, then shrinks the result with PiShrink.
set -euo pipefail

INPUT_IMG="${1:?Usage: build.sh <input.img> <output.img> [strip-list]}"
OUTPUT_IMG="${2:?Usage: build.sh <input.img> <output.img> [strip-list]}"
STRIP_LIST="${3:-/work/strip-packages.list}"

[ -f "$INPUT_IMG" ] || { echo "No such file: $INPUT_IMG" >&2; exit 1; }
[ -f "$STRIP_LIST" ] || { echo "No such file: $STRIP_LIST" >&2; exit 1; }

WORK_IMG="$(dirname "$OUTPUT_IMG")/.work-$(basename "$OUTPUT_IMG")"
MNT="$(mktemp -d)"
BOOT_LOOP=""
ROOT_LOOP=""

log() { echo "[golden-image] $*"; }

cleanup() {
  set +e
  umount "$MNT/dev/pts" 2>/dev/null
  umount "$MNT/dev" 2>/dev/null
  umount "$MNT/proc" 2>/dev/null
  umount "$MNT/sys" 2>/dev/null
  umount "$MNT/boot/firmware" 2>/dev/null
  umount "$MNT" 2>/dev/null
  [ -n "$BOOT_LOOP" ] && losetup -d "$BOOT_LOOP" 2>/dev/null
  [ -n "$ROOT_LOOP" ] && losetup -d "$ROOT_LOOP" 2>/dev/null
  rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

log "Working copy: $INPUT_IMG -> $WORK_IMG"
cp --reflink=auto "$INPUT_IMG" "$WORK_IMG"

# Not using --partscan (inside a container the loopNpM subnodes don't
# reliably show up); instead we read the partition start offsets from
# parted and open a separate offset-based loop device for boot and root.
# Deliberately no --sizelimit: on some host/container combinations
# (e.g. an older host kernel with a newer util-linux in the container)
# losetup --sizelimit fails with ENOENT, and it isn't needed anyway -
# mount/chroot/zerofree never read past a filesystem's own
# superblock-declared bounds.
log "Reading partition table"
PARTED_OUT=$(parted -s -m "$WORK_IMG" unit B print)
P1_LINE=$(echo "$PARTED_OUT" | awk -F: '$1=="1"{print}')
P2_LINE=$(echo "$PARTED_OUT" | awk -F: '$1=="2"{print}')
[ -n "$P1_LINE" ] && [ -n "$P2_LINE" ] || { log "ERROR: couldn't find 2 partitions in parted output"; exit 1; }
P1_START=$(echo "$P1_LINE" | awk -F: '{print $2}' | tr -d 'B')
P2_START=$(echo "$P2_LINE" | awk -F: '{print $2}' | tr -d 'B')

log "Loop devices: boot @$P1_START, root @$P2_START"
ROOT_LOOP=$(losetup --find --show -o "$P2_START" "$WORK_IMG")
BOOT_LOOP=$(losetup --find --show -o "$P1_START" "$WORK_IMG")

log "Mounting at $MNT"
mount "$ROOT_LOOP" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "$BOOT_LOOP" "$MNT/boot/firmware"

log "Copying qemu-aarch64-static into the chroot"
cp /usr/bin/qemu-aarch64-static "$MNT/usr/bin/"

# chroot+qemu-aarch64-static only carries the FIRST exec (bash) into
# emulation - any further process bash spawns (apt-get, dpkg, maintainer
# scripts) would otherwise be handed straight to the kernel's own execve(),
# which fails on an aarch64 binary with "Exec format error" unless
# binfmt_misc is told to route every aarch64 ELF through
# qemu-aarch64-static automatically. This registers that in the
# container's own (procfs/mount-namespace isolated) binfmt_misc table,
# not the host kernel's.
update-binfmts --enable qemu-aarch64 || {
  log "ERROR: update-binfmts --enable qemu-aarch64 failed - needs --privileged + kernel binfmt_misc support"
  exit 1
}

mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount -t sysfs sysfs "$MNT/sys"

# policy-rc.d: package postinst/prerm scripts running inside the chroot
# must not start/stop any service (classic Debian mechanism).
cat > "$MNT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$MNT/usr/sbin/policy-rc.d"

# Stub out update-initramfs: the dpkg trigger after removing packages would
# otherwise regenerate BOTH kernel-flavour initrds, which under qemu
# emulation is either very slow or hangs outright - and it's pointless
# anyway, since no kernel package is changing and the existing initrds
# stay valid.
if [ -x "$MNT/usr/sbin/update-initramfs" ]; then
  mv "$MNT/usr/sbin/update-initramfs" "$MNT/usr/sbin/update-initramfs.golden-image-real"
  cat > "$MNT/usr/sbin/update-initramfs" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$MNT/usr/sbin/update-initramfs"
fi

# resolv.conf temporarily overwritten so apt-get in the chroot can reach
# the network - the SD card's own dhcpcd/NetworkManager will overwrite it
# on first boot anyway, and we restore it at the end. (It can be a
# symlink, e.g. to a systemd-resolved stub, so we mv it aside rather than
# cp it, which would otherwise follow the dangling symlink.)
if [ -e "$MNT/etc/resolv.conf" ] || [ -L "$MNT/etc/resolv.conf" ]; then
  mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.golden-image-bak"
fi
echo "nameserver 1.1.1.1" > "$MNT/etc/resolv.conf"

cp "$STRIP_LIST" "$MNT/tmp/strip-packages.list"

log "Removing packages inside the chroot"
# One single apt-get purge call for ALL installed packages at once - not
# one by one (purging one at a time re-runs full dependency resolution
# each time, and got stuck somewhere in an inconsistent intermediate state
# under qemu emulation). Names that aren't installed are filtered out by
# dpkg -s first; the 300s timeout is a safety net in case something still
# gets stuck, so at least we know which step.
chroot "$MNT" /usr/bin/qemu-aarch64-static /bin/bash -eu -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  TO_PURGE=""
  while read -r pkg; do
    dpkg -s "$pkg" >/dev/null 2>&1 && TO_PURGE="$TO_PURGE $pkg"
  done < <(grep -vE "^[[:space:]]*(#|$)" /tmp/strip-packages.list)
  if [ -n "$TO_PURGE" ]; then
    timeout 300 apt-get -y purge $TO_PURGE
  fi
  timeout 300 apt-get -y autoremove --purge
  apt-get clean
  rm -f /tmp/strip-packages.list
'

if [ -e "$MNT/usr/sbin/update-initramfs.golden-image-real" ]; then
  mv -f "$MNT/usr/sbin/update-initramfs.golden-image-real" "$MNT/usr/sbin/update-initramfs"
fi

log "Restoring resolv.conf, cleaning up"
rm -f "$MNT/etc/resolv.conf"
if [ -e "$MNT/etc/resolv.conf.golden-image-bak" ] || [ -L "$MNT/etc/resolv.conf.golden-image-bak" ]; then
  mv "$MNT/etc/resolv.conf.golden-image-bak" "$MNT/etc/resolv.conf"
fi
rm -f "$MNT/etc/machine-id"
rm -f "$MNT/usr/sbin/policy-rc.d"
rm -f "$MNT/usr/bin/qemu-aarch64-static"
find "$MNT/var/log" -type f -exec truncate -s 0 {} \;
rm -rf "$MNT/var/cache/apt/archives/"*.deb
rm -f "$MNT/root/.bash_history"

umount "$MNT/dev/pts"
umount "$MNT/dev"
umount "$MNT/proc"
umount "$MNT/sys"
umount "$MNT/boot/firmware"
umount "$MNT"

log "zerofree on the root partition (better compression after shrink/xz)"
zerofree "$ROOT_LOOP"

losetup -d "$BOOT_LOOP"
losetup -d "$ROOT_LOOP"
BOOT_LOOP=""
ROOT_LOOP=""
trap - EXIT
rmdir "$MNT"

log "Shrinking with PiShrink"
# -n: don't check for a newer PiShrink release (we're in a container, no
# reason to reach out to the network for that either). Deliberately NOT
# -s: we need the autoexpand first-boot script so the finished image fills
# whatever size SD card it gets written to.
pishrink.sh -n "$WORK_IMG"

mv "$WORK_IMG" "$OUTPUT_IMG"
log "Done: $OUTPUT_IMG"
