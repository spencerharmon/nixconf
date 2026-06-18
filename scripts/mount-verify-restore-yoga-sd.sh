#!/usr/bin/env bash
# After a crash, safely re-open the encrypted yoga-sd target, fsck it,
# mount it at /mnt, verify/repair the target Nix store, then restore
# the yoga eMMC backup tarball into it.
#
# Default target: /dev/sdb (current SD reader path after spray reboot).
# Override:
#   DEVICE=/dev/sdX ./scripts/mount-verify-restore-yoga-sd.sh
#
# Assumed layout:
#   ${DEVICE}1 = ext4 /boot label yoga-sd-boot
#   ${DEVICE}2 = LUKS2 root -> /dev/mapper/yoga-sd-root -> ext4 label yoga-sd-0-root
#
# Uses:
#   scripts/cleanup-yoga-sd-target.sh            (store verify + repair + nixos-install)
#   scripts/restore-backup-to-yoga-sd-target.sh (archive extraction)
#
# Leaves /mnt and /mnt/boot mounted unless --unmount is passed.
set -euo pipefail

NIXCONF=${NIXCONF:-/home/spencer/git-repos/spencerharmon/nixconf}
DEVICE=${DEVICE:-/dev/sdb}
MAPPER=${MAPPER:-yoga-sd-root}
ROOT=${ROOT:-/mnt}
YOGA_HOST=${YOGA_HOST:-192.168.1.154}
ARCHIVE=${ARCHIVE:-/tmp/yoga-emmc-rescue.tar.zst}
REMOTE_ARCHIVE=${REMOTE_ARCHIVE:-/root/yoga-emmc-rescue.tar.zst}
YES=${YES:-0}
UNMOUNT=0
SKIP_STORE_VERIFY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=1 ;;
    --unmount) UNMOUNT=1 ;;
    --skip-store-verify) SKIP_STORE_VERIFY=1 ;;
    -h|--help)
      sed -n '2,50p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing command: $1"; }
for c in lsblk findmnt cryptsetup e2fsck mount umount ssh zstd tar sudo; do need "$c"; done

part() {
  local n=$1
  case "$DEVICE" in
    *mmcblk*|*nvme*) printf '%sp%s' "$DEVICE" "$n" ;;
    *)               printf '%s%s' "$DEVICE" "$n" ;;
  esac
}
BOOT_PART=$(part 1)
LUKS_PART=$(part 2)
MAPPER_DEV=/dev/mapper/$MAPPER

[[ -d "$NIXCONF" ]] || die "NIXCONF missing: $NIXCONF"
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"
[[ -b "$BOOT_PART" ]] || die "$BOOT_PART missing"
[[ -b "$LUKS_PART" ]] || die "$LUKS_PART missing"

log "Target device"
lsblk -f "$DEVICE"

if [[ "$YES" != 1 ]]; then
  read -rp "Proceed opening/mounting/restoring $DEVICE? Type exact device path: " CONFIRM
  [[ "$CONFIRM" == "$DEVICE" ]] || die "confirmation mismatch"
fi

log "Tear down stale mounts, if any"
sudo umount "$ROOT/boot" 2>/dev/null || true
sudo umount "$ROOT" 2>/dev/null || true
sudo umount "$BOOT_PART" 2>/dev/null || true
# If mapper is already open from before, keep it for now; fsck requires unmounted.
if findmnt "$MAPPER_DEV" >/dev/null 2>&1; then
  die "$MAPPER_DEV is still mounted somewhere; unmount it first"
fi

log "fsck boot partition (ext4 journal-safe preen)"
sudo e2fsck -f -p "$BOOT_PART" || {
  rc=$?
  echo "e2fsck -p returned $rc; manual repair required. Run: sudo e2fsck -f $BOOT_PART" >&2
  exit $rc
}

if [[ ! -e "$MAPPER_DEV" ]]; then
  log "Open LUKS root (enter slot-0 password)"
  sudo cryptsetup open "$LUKS_PART" "$MAPPER"
else
  log "LUKS mapper already open: $MAPPER_DEV"
fi

log "fsck root filesystem inside LUKS (ext4 journal-safe preen)"
sudo e2fsck -f -p "$MAPPER_DEV" || {
  rc=$?
  echo "e2fsck -p returned $rc; manual repair required. Run: sudo e2fsck -f $MAPPER_DEV" >&2
  exit $rc
}

log "Mount target at $ROOT + $ROOT/boot"
sudo mkdir -p "$ROOT"
sudo mount "$MAPPER_DEV" "$ROOT"
sudo mkdir -p "$ROOT/boot"
sudo mount "$BOOT_PART" "$ROOT/boot"
findmnt "$ROOT"
findmnt "$ROOT/boot"

log "Synchronize yoga-sd-0 config with current device path + PARTUUIDs"
BOOT_PARTUUID=$(sudo blkid -s PARTUUID -o value "$BOOT_PART")
LUKS_PARTUUID=$(sudo blkid -s PARTUUID -o value "$LUKS_PART")
python3 - <<PY
from pathlib import Path
p = Path("$NIXCONF/systems/yoga-sd-0/configuration.nix")
s = p.read_text()
start = s.index('  yogaSd = {')
end = s.index('  };', start) + len('  };')
new = '''  yogaSd = {
    bootPartUuid = "$BOOT_PARTUUID";
    luksPartUuid = "$LUKS_PARTUUID";

    rootLabel = "yoga-sd-0-root";
  };'''
p.write_text(s[:start] + new + s[end:])
PY

grep -n "bootPartUuid\|luksPartUuid" "$NIXCONF/systems/yoga-sd-0/configuration.nix"

log "Fetch backup archive if missing"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Fetching $REMOTE_ARCHIVE from spencer@$YOGA_HOST -> $ARCHIVE"
  ssh "spencer@$YOGA_HOST" "sudo cat '$REMOTE_ARCHIVE'" > "$ARCHIVE"
fi
ls -lh "$ARCHIVE"
zstd -t "$ARCHIVE"

if [[ "$SKIP_STORE_VERIFY" != 1 ]]; then
  log "Verify/repair target Nix store + rerun nixos-install"
  DEVICE="$DEVICE" MAPPER="$MAPPER" ROOT="$ROOT" "$NIXCONF/scripts/cleanup-yoga-sd-target.sh"
else
  log "Skipping target store verify/repair (--skip-store-verify)"
fi

log "Restore backup archive into mounted target"
RESTORE_ARGS=()
if [[ "$YES" == 1 ]]; then RESTORE_ARGS+=(--yes); fi
ROOT="$ROOT" ARCHIVE="$ARCHIVE" YOGA_HOST="$YOGA_HOST" "$NIXCONF/scripts/restore-backup-to-yoga-sd-target.sh" "${RESTORE_ARGS[@]}"

log "Final sanity checks"
sudo test -s "$ROOT/boot/grub/grub.cfg"
sudo test -s "$ROOT/etc/ssh/ssh_host_ed25519_key"
sudo test -e "$ROOT/home/spencer/.emacs"
sudo du -sh "$ROOT/home" "$ROOT/root" "$ROOT/var/lib/yoga-emmc-backup" 2>/dev/null || true
sudo grep '^menuentry\|^submenu' "$ROOT/boot/grub/grub.cfg" | head -20

if [[ "$UNMOUNT" == 1 ]]; then
  log "Sync + unmount + close LUKS"
  sync
  sudo umount "$ROOT/boot"
  sudo umount "$ROOT"
  sudo cryptsetup close "$MAPPER"
else
  log "DONE; target left mounted"
  echo "To finish manually:"
  echo "  sync && sudo umount $ROOT/boot && sudo umount $ROOT && sudo cryptsetup close $MAPPER"
fi
