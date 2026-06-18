#!/usr/bin/env bash
# Run on yoga (NOT spray). Reformats /dev/mmcblk1 with MBR + ext4 /boot
# + LUKS root, then runs perf tests, mkfs ext4 inside LUKS, adds
# slot-1 keyfile, mounts everything for nixos-install.
#
# Layout produced:
#   /dev/mmcblk1p1  ext4 /boot,  ~512 MiB, label=underyoga-boot, boot flag
#   /dev/mmcblk1p2  LUKS2 root,  rest (~14 GiB)
#                   PARTUUID = unique
#                   └─ ext4 inside, label=underyoga-root
#
# MBR (not GPT): no bios_grub partition needed; grub stage1.5 lands
# in the post-MBR sector gap. Matches the SD-card layout in
# profiles/yoga-sd.nix.
#
# Requires:
#   - cross-SD keyfile already at /run/cross-sd-key.tmp
#     (pushed by spray; tmpfs, gone at reboot)
#
# Re-runnable: each step closes/unmounts any previous state first.
set -euo pipefail

DEV=/dev/mmcblk1
LUKS_PART=${DEV}p2
BOOT_PART=${DEV}p1
MAPPER=underyoga-root
KEYFILE=/run/cross-sd-key.tmp

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*"; }

# Sanity
[[ -b $DEV ]] || die "$DEV missing."
[[ -r $KEYFILE ]] || sudo test -r "$KEYFILE" || die "$KEYFILE missing. Re-run the spray-side keyfile push."
[[ $(hostname) == "yoga" ]] || die "Run on yoga, not $(hostname)."

# Make sure required tools are present (parted, cryptsetup not in
# minimal recovery/base system). Use one nix-shell envelope rather than spawning
# many.
TOOLS_SHELL='nix-shell -p cryptsetup parted e2fsprogs util-linux --run'

log "Tearing down any previous attempt"
sudo umount /mnt/boot 2>/dev/null || true
sudo umount /mnt 2>/dev/null || true
$TOOLS_SHELL "sudo cryptsetup close $MAPPER 2>/dev/null || true"
sudo umount ${DEV}p1 2>/dev/null || true
sudo umount ${DEV}p2 2>/dev/null || true
sudo umount ${DEV}p3 2>/dev/null || true

# 0. Partition with MBR. Idempotent rewrite -- wipefs + mklabel msdos
# obliterates any previous GPT or MBR. Two partitions: /boot (~512 MiB,
# boot flag) and LUKS root (rest).
log "STEP 0: wipefs + MBR partition + mkfs /boot"
sudo wipefs -a $DEV
$TOOLS_SHELL "sudo parted $DEV -- mklabel msdos && \
  sudo parted $DEV -- mkpart primary ext4 1MiB 513MiB && \
  sudo parted $DEV -- set 1 boot on && \
  sudo parted $DEV -- mkpart primary 513MiB 100% && \
  sudo partprobe $DEV && \
  sudo parted $DEV -- print"
$TOOLS_SHELL "sudo mkfs.ext4 -L underyoga-boot $BOOT_PART" 2>&1 | tail -5

# 1. LUKS format. Interactive. Same params as profiles/yoga-sd.nix
# (aes-xts-plain64, argon2id, 512 MiB memory, 2s iter).
log "STEP 1: cryptsetup luksFormat (you will be prompted for the slot-0 passphrase TWICE)"
$TOOLS_SHELL "sudo cryptsetup luksFormat \\
    --type luks2 \\
    --cipher aes-xts-plain64 \\
    --key-size 256 \\
    --pbkdf argon2id \\
    --pbkdf-memory 524288 \\
    --pbkdf-parallel 2 \\
    --iter-time 2000 \\
    $LUKS_PART"

# 2. Open
log "STEP 2: cryptsetup open (re-enter the slot-0 passphrase)"
$TOOLS_SHELL "sudo cryptsetup open $LUKS_PART $MAPPER"

# 3. Performance tests
log "STEP 3a: cryptsetup benchmark (CPU-bound, no I/O; measures max cipher throughput on N3150)"
$TOOLS_SHELL "cryptsetup benchmark --cipher aes-xts-plain64 --key-size 256"
echo
$TOOLS_SHELL "cryptsetup benchmark"   # all ciphers / KDFs

log "STEP 3b: dd write through the mapper (sequential, O_DIRECT, no cache; measures LUKS + eMMC together)"
echo "Writing 2 GiB (512 x 4 MiB blocks)..."
sudo dd if=/dev/zero of=/dev/mapper/$MAPPER bs=4M count=512 oflag=direct conv=fsync status=progress 2>&1 | tail -5

log "STEP 3c: drop caches, then dd read through the mapper"
sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
sudo dd if=/dev/mapper/$MAPPER of=/dev/null bs=4M count=512 iflag=direct status=progress 2>&1 | tail -5

log "STEP 3d: random read latency proxy (4 KiB blocks, no cache)"
sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
echo "Random read 64 MiB in 4 KiB chunks (~16k IOPS-bound):"
$TOOLS_SHELL "time sudo dd if=/dev/mapper/$MAPPER of=/dev/null bs=4K count=16384 iflag=direct status=none"

echo
read -rp "Continue to mkfs + nixos-install prep? [y/N] " ANS
[[ $ANS == [yY] ]] || die "Stopped after perf test, as requested. LUKS is still open as $MAPPER; close with: sudo cryptsetup close $MAPPER"

# 4. mkfs (perf tests overwrote whatever was there; safe to mkfs now)
log "STEP 4: mkfs ext4 inside LUKS"
$TOOLS_SHELL "sudo mkfs.ext4 -L underyoga-root /dev/mapper/$MAPPER"

# 5. Add slot 1 keyfile (prompts for slot-0 to authorize)
log "STEP 5: luksAddKey slot 1 (cross-SD keyfile; will prompt for slot-0 passphrase)"
$TOOLS_SHELL "sudo cryptsetup luksAddKey --key-slot 1 $LUKS_PART $KEYFILE"

log "STEP 5b: luksDump showing both slots"
$TOOLS_SHELL "sudo cryptsetup luksDump $LUKS_PART | grep -E '^  [0-9]+:|Keyslots:|PBKDF:'" | head -30

log "Shredding keyfile from tmpfs (no longer needed; agenix has it)"
sudo shred -u "$KEYFILE"

# 6. Mount
log "STEP 6: mount /mnt + /mnt/boot for nixos-install"
sudo mkdir -p /mnt
sudo mount /dev/mapper/$MAPPER /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/disk/by-label/underyoga-boot /mnt/boot
findmnt /mnt
findmnt /mnt/boot

# 7. PARTUUIDs
BOOT_PARTUUID=$(sudo blkid -s PARTUUID -o value $BOOT_PART)
LUKS_PARTUUID=$(sudo blkid -s PARTUUID -o value $LUKS_PART)

log "DONE. Paste these into systems/underyoga/configuration.nix on spray:"
echo
echo "  underyoga = {"
echo "    bootPartUuid = \"$BOOT_PARTUUID\";"
echo "    luksPartUuid = \"$LUKS_PARTUUID\";"
echo "    installDevice = \"/dev/mmcblk1\";"
echo "  };"
echo
echo "Then run scripts/install-underyoga.sh from spray."
