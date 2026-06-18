#!/usr/bin/env bash
# Deploy encrypted yoga-sd-0 to an SD card attached to spray.
#
# Default target: /dev/sdc. Override with:
#   DEVICE=/dev/sdX ./scripts/deploy-yoga-sd-0-encrypted.sh
#
# Destroys the whole target device. Produces:
#   p1: /boot, ext4, label=yoga-sd-boot, 1 GiB, boot flag
#   p2: LUKS2, rest of device
#       └─ ext4, label=yoga-sd-0-root
#
# Prompts:
#   - confirmation: type the device path
#   - LUKS slot-0 password twice for luksFormat
#   - LUKS slot-0 password once for luksOpen
#   - LUKS slot-0 password once for luksAddKey authorization
#
# Uses agenix secrets:
#   - cross-sd-key.age: added to LUKS slot 1
#   - yoga-host-key.age: pre-placed into target /etc/ssh for first boot
set -euo pipefail

NIXCONF=/home/spencer/git-repos/spencerharmon/nixconf
DEVICE=${DEVICE:-/dev/sdc}
TARGET=yoga-sd-0
BOOT_LABEL=yoga-sd-boot
ROOT_LABEL=yoga-sd-0-root
MAPPER=yoga-sd-root
BOOTSTRAP_DIR=/tmp/yoga-bootstrap
CROSS_KEY_TMP=$BOOTSTRAP_DIR/cross-sd.key
HOST_KEY_TMP=$BOOTSTRAP_DIR/ssh_host_ed25519_key

log() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

part() {
  local n=$1
  case "$DEVICE" in
    *mmcblk*|*nvme*) printf '%sp%s' "$DEVICE" "$n" ;;
    *)               printf '%s%s' "$DEVICE" "$n" ;;
  esac
}

BOOT_PART=$(part 1)
LUKS_PART=$(part 2)

[[ -d $NIXCONF ]] || die "$NIXCONF missing"
[[ -b $DEVICE ]] || die "$DEVICE is not a block device"
[[ $DEVICE != /dev/sda ]] || die "Refusing to wipe /dev/sda. Override script if you really mean it."

log "Target device"
lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINTS "$DEVICE"
read -rp "DESTROY $DEVICE and install encrypted $TARGET? Type exact device path: " CONFIRM
[[ $CONFIRM == "$DEVICE" ]] || die "Confirmation mismatch; aborting."

log "Tear down old mounts/mappers"
sudo umount /mnt/boot 2>/dev/null || true
sudo umount /mnt 2>/dev/null || true
sudo umount "$BOOT_PART" 2>/dev/null || true
sudo umount "$LUKS_PART" 2>/dev/null || true
sudo cryptsetup close "$MAPPER" 2>/dev/null || true

log "Partition SD (MBR: 1 GiB /boot + LUKS root)"
sudo wipefs -a "$DEVICE"
sudo parted "$DEVICE" -- mklabel msdos
sudo parted "$DEVICE" -- mkpart primary ext4 1MiB 1025MiB
sudo parted "$DEVICE" -- set 1 boot on
sudo parted "$DEVICE" -- mkpart primary 1025MiB 100%
sudo partprobe "$DEVICE"
sudo parted "$DEVICE" -- print

log "mkfs /boot"
sudo mkfs.ext4 -L "$BOOT_LABEL" "$BOOT_PART"

log "LUKS format root partition (slot 0 = boot password)"
sudo cryptsetup luksFormat \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 256 \
  --pbkdf argon2id \
  --pbkdf-memory 524288 \
  --pbkdf-parallel 2 \
  --iter-time 2000 \
  "$LUKS_PART"

log "Open LUKS root"
sudo cryptsetup open "$LUKS_PART" "$MAPPER"

log "mkfs root inside LUKS"
sudo mkfs.ext4 -L "$ROOT_LABEL" "/dev/mapper/$MAPPER"

log "Decrypt cross-SD key and add it to LUKS slot 1"
mkdir -p "$BOOTSTRAP_DIR"
chmod 700 "$BOOTSTRAP_DIR"
( cd "$NIXCONF/secrets" && nix run --no-warn-dirty github:ryantm/agenix -- -d cross-sd-key.age ) > "$CROSS_KEY_TMP"
chmod 0400 "$CROSS_KEY_TMP"
[[ $(stat -c %s "$CROSS_KEY_TMP") == 64 ]] || die "cross-sd key is not 64 bytes"
sudo cryptsetup luksAddKey --key-slot 1 "$LUKS_PART" "$CROSS_KEY_TMP"
chmod 600 "$CROSS_KEY_TMP"
shred -u "$CROSS_KEY_TMP"

log "Verify LUKS slots"
sudo cryptsetup luksDump "$LUKS_PART" | grep -E '^  [0-9]+:|Keyslots:|PBKDF:' | head -30

BOOT_PARTUUID=$(sudo blkid -s PARTUUID -o value "$BOOT_PART")
LUKS_PARTUUID=$(sudo blkid -s PARTUUID -o value "$LUKS_PART")
[[ -n $BOOT_PARTUUID && -n $LUKS_PARTUUID ]] || die "failed to read PARTUUIDs"

log "Update systems/yoga-sd-0/configuration.nix with new PARTUUIDs + install device"
python3 - <<PY
from pathlib import Path
p = Path("$NIXCONF/systems/yoga-sd-0/configuration.nix")
s = p.read_text()
start = s.index('  yogaSd = {')
end = s.index('  };', start) + len('  };')
new = '''  yogaSd = {
    bootPartUuid = "$BOOT_PARTUUID";
    luksPartUuid = "$LUKS_PARTUUID";

    rootLabel = "$ROOT_LABEL";
  };'''
p.write_text(s[:start] + new + s[end:])
PY

git -C "$NIXCONF" add -N systems/yoga-sd-0/configuration.nix profiles/yoga-sd.nix scripts/deploy-yoga-sd-0-encrypted.sh >/dev/null 2>&1 || true

log "Build $TARGET closure"
cd "$NIXCONF"
CLOSURE=$(nix build --no-warn-dirty --no-link --print-out-paths ".#nixosConfigurations.$TARGET.config.system.build.toplevel")
echo "closure: $CLOSURE"
nix path-info -Sh "$CLOSURE"

log "Mount target at /mnt"
sudo mkdir -p /mnt
sudo mount "/dev/mapper/$MAPPER" /mnt
sudo mkdir -p /mnt/boot
sudo mount "$BOOT_PART" /mnt/boot
findmnt /mnt
findmnt /mnt/boot

log "Decrypt yoga host key and pre-place into target /etc/ssh"
( cd "$NIXCONF/secrets" && nix run --no-warn-dirty github:ryantm/agenix -- -d yoga-host-key.age ) > "$HOST_KEY_TMP"
chmod 600 "$HOST_KEY_TMP"
DERIVED_PUB=$(ssh-keygen -y -f "$HOST_KEY_TMP" | awk '{print $2}')
EXPECTED_PUB=$(grep 'root@yoga' "$NIXCONF/secrets/secrets.nix" | grep -oE 'AAAA[A-Za-z0-9+/]+=*')
[[ $DERIVED_PUB == "$EXPECTED_PUB" ]] || die "decrypted yoga host key does not match secrets.nix"
sudo mkdir -p /mnt/etc/ssh
sudo install -m 600 -o root -g root "$HOST_KEY_TMP" /mnt/etc/ssh/ssh_host_ed25519_key
sudo bash -c 'ssh-keygen -y -f /mnt/etc/ssh/ssh_host_ed25519_key > /mnt/etc/ssh/ssh_host_ed25519_key.pub'
sudo chmod 644 /mnt/etc/ssh/ssh_host_ed25519_key.pub
shred -u "$HOST_KEY_TMP"

log "Build version-matched nixos-install-tools"
NIXOS_TOOLS=$(nix build --no-warn-dirty --no-link --print-out-paths --impure --expr \
  '(builtins.getFlake (toString '$NIXCONF')).inputs.nixpkgs.legacyPackages.x86_64-linux.nixos-install-tools')

log "Run nixos-install (nodev: generates grub.cfg/kernels, does not write MBR)"
sudo "$NIXOS_TOOLS/bin/nixos-install" \
  --root /mnt \
  --flake ".#$TARGET" \
  --no-root-passwd \
  --no-channel-copy

log "Install GRUB MBR to current device ($DEVICE)"
sudo "$CLOSURE/sw/bin/grub-install" \
  --target=i386-pc \
  --boot-directory=/mnt/boot \
  "$DEVICE"

log "Post-install sanity checks"
sudo grep -A4 'menuentry' /mnt/boot/grub/grub.cfg | head -20 || true
sudo ls /mnt/boot/kernels | head
sudo test -e /mnt/etc/ssh/ssh_host_ed25519_key
sudo test -e /mnt/run || true
sudo du -sh /mnt/nix/store

log "Sync + unmount + close LUKS"
sync
sudo umount /mnt/boot
sudo umount /mnt
sudo cryptsetup close "$MAPPER"

log "DONE: encrypted $TARGET installed on $DEVICE"
echo "bootPartUuid=$BOOT_PARTUUID"
echo "luksPartUuid=$LUKS_PARTUUID"
echo
cat <<EOF
Next step to restore the backup onto this SD (after re-opening/mounting it):
  1. Re-open: sudo cryptsetup open $LUKS_PART $MAPPER
  2. Mount:   sudo mount /dev/mapper/$MAPPER /mnt && sudo mount $BOOT_PART /mnt/boot
  3. Copy/extract backup into /mnt (we will do this next)
EOF
