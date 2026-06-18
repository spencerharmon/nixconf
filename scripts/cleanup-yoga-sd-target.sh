#!/usr/bin/env bash
# Repair and finish a failed yoga-sd-0 install mounted at /mnt.
#
# Intended situation:
#   - Running on spray.
#   - New encrypted SD root is open as /dev/mapper/yoga-sd-root.
#   - Root is mounted at /mnt, boot at /mnt/boot.
#   - Previous nixos-install failed because one or more files under
#     /mnt/nix/store were corrupt/missing even though the target Nix DB
#     thought the store paths existed.
#
# What this script does:
#   1. Sanity-check mounts and flake target.
#   2. Build/locate the yoga-sd-0 system closure locally.
#   3. Compute local closure requisites.
#   4. Run target-store verification.
#   5. Parse bad /nix/store paths from verify output.
#   6. For each bad path that exists locally, replace /mnt/<path> with
#      a clean cp -aT from the local store.
#   7. Repeat verify/repair until clean or no progress.
#   8. Rerun version-matched nixos-install (nodev: grub.cfg/kernels only).
#   9. Run grub-install manually against current DEVICE.
#  10. Post-install sanity-check grub.cfg, kernels, host key, store size.
#
# Leaves /mnt and /mnt/boot mounted so backup restore can happen next.
# Use --unmount to unmount/close at the end.
#
# Usage:
#   ./scripts/cleanup-yoga-sd-target.sh
#   DEVICE=/dev/sdc MAPPER=yoga-sd-root ./scripts/cleanup-yoga-sd-target.sh
#   ./scripts/cleanup-yoga-sd-target.sh --unmount
set -euo pipefail

NIXCONF=${NIXCONF:-/home/spencer/git-repos/spencerharmon/nixconf}
TARGET=${TARGET:-yoga-sd-0}
ROOT=${ROOT:-/mnt}
DEVICE=${DEVICE:-/dev/sdc}
MAPPER=${MAPPER:-yoga-sd-root}
BOOT_PART=${BOOT_PART:-${DEVICE}1}
LOGDIR=${LOGDIR:-/tmp/yoga-sd-cleanup}
UNMOUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unmount) UNMOUNT=1 ;;
    -h|--help)
      sed -n '2,45p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "missing command: $1"; }
for c in nix nix-store grep sort awk sed cp rm findmnt lsblk file od; do need "$c"; done

mkdir -p "$LOGDIR"
VERIFY_LOG="$LOGDIR/verify.log"
BAD_PATHS="$LOGDIR/bad-paths.txt"
REQS="$LOGDIR/requisites.txt"

log "Sanity checks"
[[ -d "$NIXCONF" ]] || die "NIXCONF not found: $NIXCONF"
[[ -e "$NIXCONF/flake.nix" ]] || die "flake.nix missing in $NIXCONF"
findmnt "$ROOT" >/dev/null || die "$ROOT is not mounted"
findmnt "$ROOT/boot" >/dev/null || die "$ROOT/boot is not mounted"
[[ -d "$ROOT/nix/store" ]] || die "$ROOT/nix/store missing"
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"
lsblk "$DEVICE"
findmnt "$ROOT"
findmnt "$ROOT/boot"

log "Build local $TARGET closure"
cd "$NIXCONF"
CLOSURE=$(nix build --no-warn-dirty --no-link --print-out-paths ".#nixosConfigurations.$TARGET.config.system.build.toplevel")
[[ -n "$CLOSURE" && -e "$CLOSURE" ]] || die "failed to build closure"
echo "closure: $CLOSURE"
nix path-info -Sh "$CLOSURE"

log "Compute local closure requisites"
nix-store -qR "$CLOSURE" | sort -u > "$REQS"
echo "$(wc -l < "$REQS") requisites"

extract_bad_paths() {
  # Accept any absolute /nix/store path mentioned by nix-store verify,
  # normalize to top-level store path (/nix/store/<hash-name>), keep
  # only paths that are in the local closure requisites. This avoids
  # trying to repair unrelated garbage or /mnt-only paths.
  grep -Eo '/nix/store/[a-z0-9]{32}[^[:space:]"'"'"']*' "$VERIFY_LOG" \
    | sed -E 's#^(/nix/store/[^/]+).*#\1#' \
    | sort -u \
    | while read -r p; do
        grep -qxF "$p" "$REQS" && echo "$p" || true
      done \
    | sort -u > "$BAD_PATHS"
}

run_verify() {
  log "Verify target store contents"
  set +e
  sudo nix-store --store "local?root=$ROOT" --verify --check-contents >"$VERIFY_LOG" 2>&1
  rc=$?
  set -e
  cat "$VERIFY_LOG" | tail -80
  extract_bad_paths
  echo "bad closure paths detected: $(wc -l < "$BAD_PATHS")"
  return $rc
}

repair_bad_paths() {
  local repaired=0
  while read -r p; do
    [[ -n "$p" ]] || continue
    if [[ ! -e "$p" ]]; then
      echo "SKIP not in local store: $p"
      continue
    fi
    echo "repair: $p"
    sudo rm -rf "$ROOT$p"
    sudo mkdir -p "$(dirname "$ROOT$p")"
    sudo cp -aT "$p" "$ROOT$p"
    repaired=$((repaired + 1))
  done < "$BAD_PATHS"
  echo "$repaired" > "$LOGDIR/repaired-count"
}

# First, explicitly repair the known Perl corruption if present. This
# makes the common failure fast even if verify parsing misses it.
KNOWN=/nix/store/xc6nj52vhg4ndmyxw7c5q6iqm8jzrwdm-perl-5.42.0
if [[ -e "$KNOWN" && ( ! -e "$ROOT$KNOWN" || "$(file -b "$ROOT$KNOWN/lib/perl5/5.42.0/x86_64-linux-thread-multi/auto/Encode/Encode.so" 2>/dev/null || true)" != ELF* ) ]]; then
  log "Repair known Perl Encode.so corruption"
  sudo rm -rf "$ROOT$KNOWN"
  sudo mkdir -p "$(dirname "$ROOT$KNOWN")"
  sudo cp -aT "$KNOWN" "$ROOT$KNOWN"
  file "$ROOT$KNOWN/lib/perl5/5.42.0/x86_64-linux-thread-multi/auto/Encode/Encode.so"
  head -c 4 "$ROOT$KNOWN/lib/perl5/5.42.0/x86_64-linux-thread-multi/auto/Encode/Encode.so" | od -An -tx1
fi

# Iterate verify/repair. If verify fails but yields no repairable path,
# stop and ask operator for the log.
for pass in 1 2 3 4 5; do
  if run_verify; then
    log "Target store verification clean"
    break
  fi
  if [[ ! -s "$BAD_PATHS" ]]; then
    die "verify failed but no repairable closure paths were parsed. See $VERIFY_LOG"
  fi
  log "Repair pass $pass"
  repair_bad_paths
  if [[ "$(cat "$LOGDIR/repaired-count")" == "0" ]]; then
    die "no paths repaired; cannot make progress. See $VERIFY_LOG"
  fi
  if [[ $pass == 5 ]]; then
    die "too many repair passes; see $VERIFY_LOG"
  fi
done

log "Build version-matched nixos-install-tools"
NIXOS_TOOLS=$(nix build --no-warn-dirty --no-link --print-out-paths --impure --expr \
  '(builtins.getFlake (toString '$NIXCONF')).inputs.nixpkgs.legacyPackages.x86_64-linux.nixos-install-tools')
echo "tools: $NIXOS_TOOLS"

log "Rerun nixos-install (nodev: generates grub.cfg/kernels, does not write MBR)"
sudo "$NIXOS_TOOLS/bin/nixos-install" \
  --root "$ROOT" \
  --flake ".#$TARGET" \
  --no-root-passwd \
  --no-channel-copy

log "Install GRUB MBR to current device ($DEVICE)"
sudo "$CLOSURE/sw/bin/grub-install" \
  --target=i386-pc \
  --boot-directory="$ROOT/boot" \
  "$DEVICE"

log "Post-install sanity checks"
sudo test -s "$ROOT/boot/grub/grub.cfg"
sudo grep '^menuentry\|^submenu' "$ROOT/boot/grub/grub.cfg" | head -20
sudo test -d "$ROOT/boot/kernels"
sudo ls "$ROOT/boot/kernels" | head -20
sudo test -s "$ROOT/etc/ssh/ssh_host_ed25519_key"
sudo du -sh "$ROOT/nix/store"

log "MBR boot signature"
sudo dd if="$DEVICE" bs=512 count=1 2>/dev/null | od -An -tx1 -N16

if [[ "$UNMOUNT" == 1 ]]; then
  log "Unmount + close LUKS"
  sync
  sudo umount "$ROOT/boot"
  sudo umount "$ROOT"
  sudo cryptsetup close "$MAPPER"
else
  log "DONE; target left mounted for backup restore"
  echo "root: $ROOT"
  echo "boot: $ROOT/boot"
  echo "mapper: /dev/mapper/$MAPPER"
fi
