#!/usr/bin/env bash
# Deploy encrypted yoga-sd-1 to an SD card attached to spray.
#
# Idempotent + low-babysit. Safe to re-run after a mid-way failure: it
# inspects the current on-disk state and skips any destructive step whose
# result already exists, so a failure at (say) grub-install does NOT force
# another full wipe/format of the SD.
#
# Default target: /dev/sdb. Override with --device=/dev/sdX or DEVICE=/dev/sdX.
#
# Fresh install produces (only when the device is not already laid out this
# way, or when --force is given):
#   p1: /boot, ext4, label=yoga-sd-boot, 1 GiB, boot flag
#   p2: LUKS2, rest of device
#       └─ ext4, label=yoga-sd-1-root
#
# Flags / env:
#   --no-confirm, -y      Skip the "type the device path" confirmation.
#                         (Only asked at all when a destructive wipe is due.)
#   --force               Force a full wipe + repartition + reformat even if
#                         a valid layout is already present. DESTRUCTIVE.
#   --keep-mounted        Leave the target mounted at /mnt (and LUKS open) at
#                         the end, ready for a backup restore. Default: unmount
#                         and close the LUKS mapper.
#   --dry-run, -n         Detect device state, print the exact plan (what will
#                         be done vs skipped, destructive or not), then exit
#                         WITHOUT changing anything. Still asks for sudo, which
#                         is only used to read the device. Also reports (but
#                         does not perform) any pending nixconf fast-forward.
#   --no-sync             Do NOT auto-sync $NIXCONF. By default the script
#                         fetches origin and fast-forwards $NIXCONF to
#                         origin/main before building, so config fixes landed
#                         upstream are actually picked up (this tree is a
#                         separate clone from the one fixes are pushed to). The
#                         sync ONLY fast-forwards: it never rewinds, never drops
#                         local commits, and never clobbers a runtime-dirty
#                         configuration.nix. Use --no-sync to build the local
#                         tree exactly as-is.
#   --device=/dev/sdX     Target device (same as DEVICE=...).
#   -h, --help            Show this help.
#
#   DEVICE=/dev/sdX               Target device.
#   LUKS_PASSPHRASE=...           Supply the LUKS slot-0 passphrase non-
#                                 interactively (no prompt). For fully
#                                 unattended runs. Tradeoff: the passphrase is
#                                 then visible in this process's environment.
#
# Password handling (minimal intervention):
#   - sudo:  prompted once up front (`sudo -v`); a background keepalive
#            re-stamps the sudo timestamp every 45s so it CANNOT time out
#            during the long closure build/copy. (This was the original
#            failure mode.)
#   - LUKS:  the slot-0 passphrase is asked for at most once (twice, to
#            confirm, only on a fresh format) and reused for luksFormat,
#            luksOpen, and luksAddKey authorization via stdin — never written
#            to disk. On an idempotent re-run where the container is already
#            open and slot 1 is already populated, it is not asked for at all.
#
# Uses agenix secrets:
#   - cross-sd-key.age: added to LUKS slot 1 (skipped if slot 1 already set)
#   - yoga-host-key.age: pre-placed into target /etc/ssh for first boot
set -euo pipefail

NIXCONF=/home/spencer/git-repos/spencerharmon/nixconf
DEVICE=${DEVICE:-/dev/sdb}
TARGET=yoga-sd-1
BOOT_LABEL=yoga-sd-boot
ROOT_LABEL=yoga-sd-1-root
MAPPER=yoga-sd-root
BOOTSTRAP_DIR=/tmp/yoga-bootstrap
CROSS_KEY_TMP=$BOOTSTRAP_DIR/cross-sd.key
HOST_KEY_TMP=$BOOTSTRAP_DIR/ssh_host_ed25519_key

NO_CONFIRM=0
FORCE=0
KEEP_MOUNTED=0
DRY_RUN=0
NO_SYNC=0
SUDO_KEEPALIVE_PID=""
LUKS_PASS=""

log() { printf '\n=== %s ===\n' "$*"; }
info() { printf '  - %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit "${1:-0}"; }

# ---- argument parsing ------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    -y|--no-confirm)  NO_CONFIRM=1 ;;
    --force)          FORCE=1 ;;
    --keep-mounted)   KEEP_MOUNTED=1 ;;
    -n|--dry-run)     DRY_RUN=1 ;;
    --no-sync)        NO_SYNC=1 ;;
    --device=*)       DEVICE=${arg#--device=} ;;
    -h|--help)        usage 0 ;;
    *)                die "unknown argument: $arg (see --help)" ;;
  esac
done

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

# ---- cleanup / secure teardown --------------------------------------------
cleanup() {
  local rc=$?
  [[ -n $SUDO_KEEPALIVE_PID ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  [[ -f $CROSS_KEY_TMP ]] && shred -u "$CROSS_KEY_TMP" 2>/dev/null || true
  [[ -f $HOST_KEY_TMP ]] && shred -u "$HOST_KEY_TMP" 2>/dev/null || true
  return $rc
}
trap cleanup EXIT

# ---- state detection helpers ----------------------------------------------
fs_type()   { sudo blkid -s TYPE  -o value "$1" 2>/dev/null || true; }
fs_label()  { sudo blkid -s LABEL -o value "$1" 2>/dev/null || true; }
is_luks()   { sudo cryptsetup isLuks "$1" 2>/dev/null; }
mapper_open() { [[ -b /dev/mapper/$MAPPER ]]; }
# luks2 luksDump lists each keyslot as e.g. "  1: luks2"
slot_used() { sudo cryptsetup luksDump "$LUKS_PART" 2>/dev/null | grep -qE "^[[:space:]]+$1: luks2"; }

# ---- keep $NIXCONF current -------------------------------------------------
# This tree is a SEPARATE clone from the beehive-managed checkout that
# config fixes are pushed to (both share the same origin/main). Without
# this sync, a fix landed upstream is silently NOT built here and the
# deploy reproduces the already-fixed bug. Fast-forward only: never
# rewind, never drop local commits, never clobber a runtime-dirty
# configuration.nix (the PARTUUID injection below leaves it dirty).
sync_nixconf() {
  git -C "$NIXCONF" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    info "$NIXCONF is not a git checkout; building it as-is"; return 0; }
  if ! git -C "$NIXCONF" fetch --quiet origin 2>/dev/null; then
    warn "could not fetch origin (offline?); building the local nixconf tree as-is"
    return 0
  fi
  local head upstream
  upstream=$(git -C "$NIXCONF" rev-parse --verify --quiet origin/main) || {
    warn "origin/main not found; building local tree as-is"; return 0; }
  head=$(git -C "$NIXCONF" rev-parse HEAD)
  if [[ "$head" == "$upstream" ]]; then
    info "nixconf up to date ($(git -C "$NIXCONF" rev-parse --short HEAD) = origin/main)"
    return 0
  fi
  # Only proceed on a clean fast-forward (HEAD is an ancestor of origin/main).
  if ! git -C "$NIXCONF" merge-base --is-ancestor "$head" "$upstream"; then
    die "nixconf HEAD ($(git -C "$NIXCONF" rev-parse --short HEAD)) has commits not on origin/main; reconcile manually. Re-run with --no-sync to build the local tree as-is."
  fi
  if [[ $DRY_RUN == 1 ]]; then
    info "nixconf behind origin/main; WOULD fast-forward $(git -C "$NIXCONF" rev-parse --short "$head") -> $(git -C "$NIXCONF" rev-parse --short "$upstream") (skipped: --dry-run)"
    return 0
  fi
  # FF leaves an untouched dirty configuration.nix in place; if upstream
  # DID change that file while it is locally dirty, git refuses rather
  # than clobber -- surface it instead of guessing.
  if git -C "$NIXCONF" merge --ff-only "$upstream" >/dev/null 2>&1; then
    info "nixconf fast-forwarded to $(git -C "$NIXCONF" rev-parse --short HEAD) (origin/main)"
  else
    die "nixconf fast-forward to origin/main was blocked by local uncommitted changes (likely systems/$TARGET/configuration.nix). Commit or stash them and re-run, or use --no-sync."
  fi
}

# ---- sudo: prompt once, keep the timestamp warm ---------------------------
# sudo is needed just to *inspect* the device (blkid / cryptsetup), so it is
# acquired before state detection. This is the only credential needed to work
# out the plan; the LUKS passphrase is collected afterwards, once, so that
# after the plan is shown and confirmed there is no further interaction.
log "Acquire sudo (prompted once; kept warm for the whole run)"
sudo -v || die "sudo authentication failed"
( while true; do sudo -n true 2>/dev/null || exit; sleep 45; done ) &
SUDO_KEEPALIVE_PID=$!

# ---- sync nixconf to origin/main (unless --no-sync) ------------------------
log "Sync nixconf ($NIXCONF)"
if [[ $NO_SYNC == 1 ]]; then
  info "sync skipped (--no-sync); building the local tree as-is"
else
  sync_nixconf
fi

# ---- inspect device FIRST -------------------------------------------------
log "Target device"
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINTS "$DEVICE"

# Decide the destructive/idempotent path from the actual on-disk state.
DO_PARTITION=0
LAYOUT_REASON=""
if [[ $FORCE == 1 ]]; then
  DO_PARTITION=1
  LAYOUT_REASON="--force given"
elif is_luks "$LUKS_PART" && [[ $(fs_type "$BOOT_PART") == ext4 ]]; then
  DO_PARTITION=0
  LAYOUT_REASON="existing ext4 /boot + LUKS root detected"
else
  DO_PARTITION=1
  LAYOUT_REASON="no valid encrypted layout present"
fi

# Do we need the slot-0 passphrase at all this run?
NEED_PASS=0
if   [[ $DO_PARTITION == 1 ]]; then NEED_PASS=1   # format + open
elif ! mapper_open;          then NEED_PASS=1     # open existing container
elif ! slot_used 1;          then NEED_PASS=1     # authorize luksAddKey slot 1
fi

# ---- print the PLAN (what will actually happen) ---------------------------
log "Plan for $DEVICE"
if [[ $DO_PARTITION == 1 ]]; then
  printf '  !! DESTRUCTIVE: %s\n' "$LAYOUT_REASON"
  info "wipe + MBR partition (1 GiB /boot + LUKS root)"
  info "mkfs.ext4 /boot (label=$BOOT_LABEL)"
  info "luksFormat root (slot 0 = boot passphrase), then open + mkfs.ext4 (label=$ROOT_LABEL)"
else
  printf '  == NON-DESTRUCTIVE: %s; no data on %s will be wiped\n' "$LAYOUT_REASON" "$DEVICE"
  if [[ $(fs_type "$BOOT_PART") != ext4 ]]; then info "mkfs.ext4 /boot (label=$BOOT_LABEL)"
  elif [[ $(fs_label "$BOOT_PART") != "$BOOT_LABEL" ]]; then info "relabel /boot -> $BOOT_LABEL (non-destructive)"
  else info "/boot already ext4 label=$BOOT_LABEL (keep)"; fi
  info "luks root: keep existing container"
  if mapper_open; then info "luks: already open at /dev/mapper/$MAPPER (keep)"
  else info "luks: open /dev/mapper/$MAPPER (needs slot-0 passphrase)"; fi
  info "root fs: format only if not already ext4 (decided after unlock)"
fi
if slot_used 1; then info "slot 1 (cross-SD key): already present (keep)"
else info "slot 1 (cross-SD key): add from cross-sd-key.age"; fi
info "pre-place yoga host key into target /etc/ssh (skip if already correct)"
info "build closure, nixos-install (grub.cfg/kernels), grub-install MBR -> $DEVICE"
if [[ $NEED_PASS == 1 ]]; then info "LUKS slot-0 passphrase: required this run"
else info "LUKS slot-0 passphrase: NOT needed this run (fully unattended)"; fi
if [[ $KEEP_MOUNTED == 1 ]]; then info "will leave target mounted at /mnt (--keep-mounted)"
else info "will unmount + close LUKS at the end"; fi

# ---- dry run stops here ----------------------------------------------------
if [[ $DRY_RUN == 1 ]]; then
  log "Dry run (--dry-run): no changes made"
  exit 0
fi

# ---- destructive confirmation (only when a wipe is actually due) ----------
if [[ $DO_PARTITION == 1 && $NO_CONFIRM == 0 ]]; then
  read -rp "DESTROY $DEVICE and install encrypted $TARGET? Type exact device path: " CONFIRM
  [[ $CONFIRM == "$DEVICE" ]] || die "Confirmation mismatch; aborting."
elif [[ $DO_PARTITION == 1 ]]; then
  info "--no-confirm: skipping destroy confirmation for $DEVICE"
fi

# ---- collect the LUKS passphrase (at most once, up front) -----------------
# Everything after this point runs with no further interaction.
if [[ $NEED_PASS == 1 ]]; then
  if [[ -n ${LUKS_PASSPHRASE:-} ]]; then
    LUKS_PASS=$LUKS_PASSPHRASE
    info "Using LUKS passphrase from LUKS_PASSPHRASE env"
  elif [[ $DO_PARTITION == 1 ]]; then
    read -rsp "New LUKS passphrase (slot 0, boot password): " LUKS_PASS; echo
    read -rsp "Confirm LUKS passphrase: " _p2; echo
    [[ $LUKS_PASS == "$_p2" ]] || die "passphrases do not match"
    unset _p2
  else
    read -rsp "LUKS passphrase (slot 0) for $LUKS_PART: " LUKS_PASS; echo
  fi
  [[ -n $LUKS_PASS ]] || die "empty passphrase"

  # Fail fast: if the container already exists, verify the passphrase now,
  # before the long closure build, rather than deep into the run.
  if [[ $DO_PARTITION == 0 ]] && is_luks "$LUKS_PART"; then
    printf '%s' "$LUKS_PASS" | sudo cryptsetup open --test-passphrase "$LUKS_PART" --key-file - \
      || die "LUKS passphrase does not unlock slot 0 of $LUKS_PART"
    info "LUKS passphrase verified against existing container"
  fi
fi

# ---- teardown (only before a destructive repartition) ---------------------
if [[ $DO_PARTITION == 1 ]]; then
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
else
  log "Skip partitioning (valid layout already present)"
fi

# ---- /boot filesystem ------------------------------------------------------
log "/boot filesystem"
if [[ $DO_PARTITION == 1 || $(fs_type "$BOOT_PART") != ext4 ]]; then
  info "mkfs.ext4 $BOOT_PART (label=$BOOT_LABEL)"
  sudo mkfs.ext4 -F -L "$BOOT_LABEL" "$BOOT_PART"
elif [[ $(fs_label "$BOOT_PART") != "$BOOT_LABEL" ]]; then
  info "relabel $BOOT_PART -> $BOOT_LABEL (non-destructive)"
  sudo e2label "$BOOT_PART" "$BOOT_LABEL"
else
  info "already ext4 label=$BOOT_LABEL; skipping"
fi

# ---- LUKS format (destructive path only) ----------------------------------
if [[ $DO_PARTITION == 1 ]]; then
  log "LUKS format root partition (slot 0 = boot password)"
  printf '%s' "$LUKS_PASS" | sudo cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 256 \
    --pbkdf argon2id \
    --pbkdf-memory 524288 \
    --pbkdf-parallel 2 \
    --iter-time 2000 \
    --batch-mode \
    --key-file - \
    "$LUKS_PART"
else
  log "Skip LUKS format (container already present)"
fi

# ---- open the container ----------------------------------------------------
log "Open LUKS root"
if mapper_open; then
  info "/dev/mapper/$MAPPER already open; skipping"
else
  printf '%s' "$LUKS_PASS" | sudo cryptsetup open "$LUKS_PART" "$MAPPER" --key-file -
  info "opened /dev/mapper/$MAPPER"
fi

# ---- root filesystem inside LUKS ------------------------------------------
log "root filesystem inside LUKS"
if [[ $DO_PARTITION == 1 || $(fs_type "/dev/mapper/$MAPPER") != ext4 ]]; then
  info "mkfs.ext4 /dev/mapper/$MAPPER (label=$ROOT_LABEL)"
  sudo mkfs.ext4 -F -L "$ROOT_LABEL" "/dev/mapper/$MAPPER"
elif [[ $(fs_label "/dev/mapper/$MAPPER") != "$ROOT_LABEL" ]]; then
  info "relabel /dev/mapper/$MAPPER -> $ROOT_LABEL (non-destructive)"
  sudo e2label "/dev/mapper/$MAPPER" "$ROOT_LABEL"
else
  info "already ext4 label=$ROOT_LABEL; skipping"
fi

# ---- cross-SD keyfile in slot 1 -------------------------------------------
log "Cross-SD key in LUKS slot 1"
if slot_used 1; then
  info "slot 1 already populated; skipping"
else
  mkdir -p "$BOOTSTRAP_DIR"
  chmod 700 "$BOOTSTRAP_DIR"
  ( cd "$NIXCONF/secrets" && nix run --no-warn-dirty github:ryantm/agenix -- -d cross-sd-key.age ) > "$CROSS_KEY_TMP"
  chmod 0400 "$CROSS_KEY_TMP"
  [[ $(stat -c %s "$CROSS_KEY_TMP") == 64 ]] || die "cross-sd key is not 64 bytes"
  # Existing slot-0 passphrase (stdin) authorizes adding the new slot-1 key.
  printf '%s' "$LUKS_PASS" | sudo cryptsetup luksAddKey --key-slot 1 --key-file - "$LUKS_PART" "$CROSS_KEY_TMP"
  chmod 600 "$CROSS_KEY_TMP"
  shred -u "$CROSS_KEY_TMP"
  info "added cross-SD key to slot 1"
fi

log "Verify LUKS slots"
sudo cryptsetup luksDump "$LUKS_PART" | grep -E '^[[:space:]]+[0-9]+:|Keyslots:|PBKDF:' | head -30

# ---- PARTUUIDs + configuration.nix ----------------------------------------
BOOT_PARTUUID=$(sudo blkid -s PARTUUID -o value "$BOOT_PART")
LUKS_PARTUUID=$(sudo blkid -s PARTUUID -o value "$LUKS_PART")
[[ -n $BOOT_PARTUUID && -n $LUKS_PARTUUID ]] || die "failed to read PARTUUIDs"

log "Update systems/yoga-sd-1/configuration.nix with new PARTUUIDs + install device"
python3 - <<PY
from pathlib import Path
p = Path("$NIXCONF/systems/yoga-sd-1/configuration.nix")
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

git -C "$NIXCONF" add -N systems/yoga-sd-1/configuration.nix profiles/yoga-sd.nix scripts/deploy-yoga-sd-1-encrypted.sh >/dev/null 2>&1 || true

# ---- build the closure -----------------------------------------------------
log "Build $TARGET closure"
cd "$NIXCONF"
CLOSURE=$(nix build --no-warn-dirty --no-link --print-out-paths ".#nixosConfigurations.$TARGET.config.system.build.toplevel")
echo "closure: $CLOSURE"
nix path-info -Sh "$CLOSURE"

# ---- mount -----------------------------------------------------------------
log "Mount target at /mnt"
sudo mkdir -p /mnt
if findmnt -n /mnt >/dev/null 2>&1; then
  info "/mnt already mounted; skipping"
else
  sudo mount "/dev/mapper/$MAPPER" /mnt
fi
sudo mkdir -p /mnt/boot
if findmnt -n /mnt/boot >/dev/null 2>&1; then
  info "/mnt/boot already mounted; skipping"
else
  sudo mount "$BOOT_PART" /mnt/boot
fi
findmnt /mnt
findmnt /mnt/boot

# ---- pre-place yoga host key ----------------------------------------------
log "Yoga host key pre-placed into target /etc/ssh"
EXPECTED_PUB=$(grep 'root@yoga' "$NIXCONF/secrets/secrets.nix" | grep -oE 'AAAA[A-Za-z0-9+/]+=*')
[[ -n $EXPECTED_PUB ]] || die "could not read expected yoga host pubkey from secrets.nix"

place_host_key=1
if sudo test -e /mnt/etc/ssh/ssh_host_ed25519_key; then
  CUR_PUB=$(sudo ssh-keygen -y -f /mnt/etc/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}' || true)
  if [[ $CUR_PUB == "$EXPECTED_PUB" ]]; then
    info "correct host key already present; skipping"
    place_host_key=0
  else
    info "host key present but mismatched; replacing"
  fi
fi
if [[ $place_host_key == 1 ]]; then
  mkdir -p "$BOOTSTRAP_DIR"; chmod 700 "$BOOTSTRAP_DIR"
  ( cd "$NIXCONF/secrets" && nix run --no-warn-dirty github:ryantm/agenix -- -d yoga-host-key.age ) > "$HOST_KEY_TMP"
  chmod 600 "$HOST_KEY_TMP"
  DERIVED_PUB=$(ssh-keygen -y -f "$HOST_KEY_TMP" | awk '{print $2}')
  [[ $DERIVED_PUB == "$EXPECTED_PUB" ]] || die "decrypted yoga host key does not match secrets.nix"
  sudo mkdir -p /mnt/etc/ssh
  sudo install -m 600 -o root -g root "$HOST_KEY_TMP" /mnt/etc/ssh/ssh_host_ed25519_key
  sudo bash -c 'ssh-keygen -y -f /mnt/etc/ssh/ssh_host_ed25519_key > /mnt/etc/ssh/ssh_host_ed25519_key.pub'
  sudo chmod 644 /mnt/etc/ssh/ssh_host_ed25519_key.pub
  shred -u "$HOST_KEY_TMP"
fi

# ---- nixos-install ---------------------------------------------------------
log "Build version-matched nixos-install-tools"
NIXOS_TOOLS=$(nix build --no-warn-dirty --no-link --print-out-paths --impure --expr \
  '(builtins.getFlake (toString '$NIXCONF')).inputs.nixpkgs.legacyPackages.x86_64-linux.nixos-install-tools')

log "Run nixos-install (nodev: generates grub.cfg/kernels, does not write MBR)"
sudo "$NIXOS_TOOLS/bin/nixos-install" \
  --root /mnt \
  --flake ".#$TARGET" \
  --no-root-passwd \
  --no-channel-copy

# ---- GRUB MBR --------------------------------------------------------------
log "Install GRUB MBR to current device ($DEVICE)"
# grub-install is NOT at $CLOSURE/sw/bin; it lives in the grub package that is
# a runtime dependency of the closure. Locate it dynamically.
GRUB_PKG=$(nix-store -qR "$CLOSURE" | grep -E '/[a-z0-9]{32}-grub-[0-9]' | head -1)
[[ -n $GRUB_PKG ]] || die "could not locate grub package in closure requisites"
GRUB_INSTALL=$GRUB_PKG/sbin/grub-install
[[ -x $GRUB_INSTALL ]] || GRUB_INSTALL=$GRUB_PKG/bin/grub-install
[[ -x $GRUB_INSTALL ]] || die "grub-install not found under $GRUB_PKG"
info "using $GRUB_INSTALL"
sudo "$GRUB_INSTALL" \
  --target=i386-pc \
  --boot-directory=/mnt/boot \
  "$DEVICE"

# ---- sanity ----------------------------------------------------------------
log "Post-install sanity checks"
sudo grep -A4 'menuentry' /mnt/boot/grub/grub.cfg | head -20 || true
sudo ls /mnt/boot/kernels | head
sudo test -e /mnt/etc/ssh/ssh_host_ed25519_key
sudo test -e /mnt/run || true
sudo du -sh /mnt/nix/store

# ---- finish ----------------------------------------------------------------
sync
if [[ $KEEP_MOUNTED == 1 ]]; then
  log "Leaving target mounted (--keep-mounted)"
  info "root: /mnt   boot: /mnt/boot   mapper: /dev/mapper/$MAPPER"
else
  log "Sync + unmount + close LUKS"
  sudo umount /mnt/boot 2>/dev/null || true
  sudo umount /mnt 2>/dev/null || true
  sudo cryptsetup close "$MAPPER" 2>/dev/null || true
fi

log "DONE: encrypted $TARGET installed on $DEVICE"
echo "bootPartUuid=$BOOT_PARTUUID"
echo "luksPartUuid=$LUKS_PARTUUID"
echo
cat <<EOF
Next step to restore the backup onto this SD (after re-opening/mounting it):
  1. Re-open: sudo cryptsetup open $LUKS_PART $MAPPER
  2. Mount:   sudo mount /dev/mapper/$MAPPER /mnt && sudo mount $BOOT_PART /mnt/boot
  3. Copy/extract backup into /mnt (we will do this next)

Or re-run this script with --keep-mounted to skip steps 1-2.
EOF
