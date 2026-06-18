#!/usr/bin/env bash
# Reformat yoga's internal eMMC (/dev/mmcblk1) for underyoga.
#
# Run on YOGA, not spray. To add slot 1 to underyoga's LUKS,
# decrypt cross-sd-key.age on the build host (spray), scp the keyfile
# to yoga's tmpfs, use it, then shred both cleartext copies. Modern
# yoga-sd systems decrypt this secret themselves after boot; this
# script exists for initial provisioning from an arbitrary working
# Yoga state.
#
# Layout produced:
#   /dev/mmcblk1p1  GPT BIOS-boot, 1 MiB, bios_grub flag, unformatted
#   /dev/mmcblk1p2  ext4 /boot,    512 MiB, label=underyoga-boot, boot flag
#   /dev/mmcblk1p3  LUKS2 root,    rest (~14 GiB), inside ext4 label=underyoga-root
#
# Prompts:
#   - sudo password on yoga (one-time-cached)
#   - LUKS slot-0 passphrase, twice (initrd password at every boot)
#
# Usage: this script is INTENDED TO BE INVOKED FROM SPRAY, where the
# agenix keyfile lives.
#
#   ./reformat-emmc-underyoga.sh
#
# YOGA must be reachable as spencer@$YOGA_HOST.
set -euo pipefail

YOGA_HOST="${YOGA_HOST:-192.168.1.154}"
NIXCONF=/home/spencer/git-repos/spencerharmon/nixconf
BOOTSTRAP_DIR=/tmp/yoga-bootstrap
CROSS_KEY_LOCAL=$BOOTSTRAP_DIR/cross-sd.key

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*"; }

[[ -d $NIXCONF/secrets ]] || die "$NIXCONF/secrets not found; running from wrong directory?"

# 1. Sanity: yoga reachable and SD-booted
log "Sanity: yoga reachable"
ssh -o BatchMode=yes -o ConnectTimeout=5 "spencer@$YOGA_HOST" 'hostname; mount | grep -E "^/dev/(mmcblk0|sd)"' \
    || die "Can't ssh spencer@$YOGA_HOST or yoga isn't responsive."

YOGA_HOSTNAME=$(ssh "spencer@$YOGA_HOST" hostname)
[[ $YOGA_HOSTNAME == "yoga" ]] || die "Refusing to reformat eMMC: target's hostname is '$YOGA_HOSTNAME', expected 'yoga' (must be SD-booted)."

log "Verifying yoga is SD-booted (root on mmcblk0, not mmcblk1)"
ROOT_DEV=$(ssh "spencer@$YOGA_HOST" "findmnt -no SOURCE /")
case "$ROOT_DEV" in
    /dev/mmcblk0p*) echo "yoga's root is on $ROOT_DEV (SD card). Safe to reformat mmcblk1." ;;
    /dev/mmcblk1p*) die "yoga's root is on $ROOT_DEV (eMMC). Cannot reformat the disk we are booted from. Boot from SD first." ;;
    *) die "Unexpected root device $ROOT_DEV. Aborting out of paranoia." ;;
esac

# 2. Decrypt the cross-SD keyfile on spray (where the agenix user
#    identity lives), push to yoga's tmpfs.
log "Decrypting cross-sd-key.age on spray"
mkdir -p "$BOOTSTRAP_DIR"
chmod 700 "$BOOTSTRAP_DIR"
( cd "$NIXCONF/secrets" && nix run --no-warn-dirty github:ryantm/agenix -- -d cross-sd-key.age ) > "$CROSS_KEY_LOCAL"
chmod 0400 "$CROSS_KEY_LOCAL"
[[ $(stat -c %s "$CROSS_KEY_LOCAL") == 64 ]] || die "Decrypted keyfile is not 64 bytes (got $(stat -c %s "$CROSS_KEY_LOCAL"))."

log "scp keyfile to yoga's tmpfs (/run/cross-sd-key.tmp; vanishes at reboot)"
scp "$CROSS_KEY_LOCAL" "spencer@$YOGA_HOST:/tmp/cross-sd.key" >/dev/null
ssh "spencer@$YOGA_HOST" 'sudo install -m 0400 -o root -g root /tmp/cross-sd.key /run/cross-sd-key.tmp && shred -u /tmp/cross-sd.key'

# Local shred too: agenix can always re-derive.
shred -u "$CROSS_KEY_LOCAL"

# 3. Confirm destruction on yoga
log "Final confirmation before reformat"
ssh "spencer@$YOGA_HOST" 'lsblk /dev/mmcblk1'
echo
echo "About to wipe /dev/mmcblk1 (yoga's internal eMMC) and install"
echo "a fresh underyoga + LUKS root."
echo
read -rp "Type 'mmcblk1' to confirm reformat: " CONFIRM
[[ $CONFIRM == "mmcblk1" ]] || die "Confirmation mismatch; aborting."

# 4. Reformat. Everything below runs on yoga via ssh.
log "Tearing down any mounts on mmcblk1"
ssh "spencer@$YOGA_HOST" 'sudo umount /mnt/boot 2>/dev/null || true; sudo umount /mnt 2>/dev/null || true; sudo umount /dev/mmcblk1p1 2>/dev/null || true; sudo cryptsetup close underyoga-root 2>/dev/null || true'

log "wipefs + GPT + bios_grub + /boot + LUKS partitions"
ssh "spencer@$YOGA_HOST" '
set -e
sudo wipefs -a /dev/mmcblk1
sudo parted /dev/mmcblk1 -- mklabel gpt
sudo parted /dev/mmcblk1 -- mkpart bios_grub 1MiB 2MiB
sudo parted /dev/mmcblk1 -- set 1 bios_grub on
sudo parted /dev/mmcblk1 -- mkpart underyoga-boot ext4 2MiB 514MiB
sudo parted /dev/mmcblk1 -- set 2 boot on
sudo parted /dev/mmcblk1 -- mkpart underyoga-luks 514MiB 100%
sudo partprobe /dev/mmcblk1
sudo parted /dev/mmcblk1 -- print
'

log "mkfs /boot"
ssh "spencer@$YOGA_HOST" 'sudo mkfs.ext4 -L underyoga-boot /dev/mmcblk1p2'

log "LUKS-format root (you will be prompted for the slot-0 passphrase; this becomes the boot-time password)"
ssh -t "spencer@$YOGA_HOST" '
sudo cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 256 \
    --pbkdf argon2id \
    --pbkdf-memory 524288 \
    --pbkdf-parallel 2 \
    --iter-time 2000 \
    /dev/mmcblk1p3
'

log "Opening LUKS as underyoga-root (re-enter slot-0 passphrase)"
ssh -t "spencer@$YOGA_HOST" 'sudo cryptsetup open /dev/mmcblk1p3 underyoga-root'

log "mkfs ext4 inside LUKS"
ssh "spencer@$YOGA_HOST" 'sudo mkfs.ext4 -L underyoga-root /dev/mapper/underyoga-root'

log "Adding cross-SD keyfile to LUKS slot 1 (will prompt for slot-0 passphrase)"
ssh -t "spencer@$YOGA_HOST" 'sudo cryptsetup luksAddKey --key-slot 1 /dev/mmcblk1p3 /run/cross-sd-key.tmp'

log "Verifying both slots are present (argon2id)"
ssh "spencer@$YOGA_HOST" 'sudo cryptsetup luksDump /dev/mmcblk1p3 | grep -E "^  [0-9]+:|Keyslots:|PBKDF:" | head -30'

log "Shredding keyfile from yoga's tmpfs"
ssh "spencer@$YOGA_HOST" 'sudo shred -u /run/cross-sd-key.tmp'

log "Mounting target at /mnt + /mnt/boot for nixos-install"
ssh "spencer@$YOGA_HOST" '
sudo mkdir -p /mnt
sudo mount /dev/mapper/underyoga-root /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/disk/by-label/underyoga-boot /mnt/boot
findmnt /mnt
findmnt /mnt/boot
'

BOOT_PARTUUID=$(ssh "spencer@$YOGA_HOST" 'sudo blkid -s PARTUUID -o value /dev/mmcblk1p2')
LUKS_PARTUUID=$(ssh "spencer@$YOGA_HOST" 'sudo blkid -s PARTUUID -o value /dev/mmcblk1p3')

log "DONE."
echo
echo "Paste these into systems/underyoga/configuration.nix:"
echo
echo "  underyoga = {"
echo "    bootPartUuid = \"$BOOT_PARTUUID\";"
echo "    luksPartUuid = \"$LUKS_PARTUUID\";"
echo "    installDevice = \"/dev/mmcblk1\";"
echo "  };"
echo
echo "Then run scripts/install-underyoga.sh from spray to build + push + nixos-install."
