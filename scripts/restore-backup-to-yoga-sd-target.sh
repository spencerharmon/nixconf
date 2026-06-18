#!/usr/bin/env bash
# Restore yoga eMMC backup archive into a mounted yoga-sd target at /mnt.
#
# Intended situation:
#   - Running on spray.
#   - Encrypted yoga-sd root is mounted at /mnt.
#   - Boot partition is mounted at /mnt/boot.
#   - Archive is at /tmp/yoga-emmc-rescue.tar.zst OR fetchable from
#     spencer@$YOGA_HOST:/root/yoga-emmc-rescue.tar.zst via sudo cat.
#
# Restores safe paths in-place:
#   home
#   root
#   var/lib/bluetooth      if present
#   var/lib/tailscale      if present
#   var/spool/cron         if present
#
# Extracts risky/reference paths under /mnt/var/lib/yoga-emmc-backup:
#   etc/ssh, etc/machine-id, etc/nixos
#   var/lib/iwd, var/lib/NetworkManager
#   var/log/journal
#   var/lib/postgresql, mysql, docker, containers (if present)
#
# Copies the archive itself to /mnt/root/yoga-emmc-rescue.tar.zst.
# Repairs /mnt/home/spencer/.emacs to point at the current
# home-manager-files store path if present, avoiding the old dangling
# symlink from the backup.
set -euo pipefail

ROOT=${ROOT:-/mnt}
ARCHIVE=${ARCHIVE:-/tmp/yoga-emmc-rescue.tar.zst}
YOGA_HOST=${YOGA_HOST:-192.168.1.154}
REMOTE_ARCHIVE=${REMOTE_ARCHIVE:-/root/yoga-emmc-rescue.tar.zst}
BACKUP_DIR=${BACKUP_DIR:-/var/lib/yoga-emmc-backup}
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,55p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "missing command: $1"; }
for c in ssh zstd tar findmnt grep awk sort sudo; do need "$c"; done

log "Sanity checks"
findmnt "$ROOT" >/dev/null || die "$ROOT not mounted"
findmnt "$ROOT/boot" >/dev/null || die "$ROOT/boot not mounted"
[[ -d "$ROOT/nix/store" ]] || die "$ROOT/nix/store missing"
[[ -d "$ROOT/etc" ]] || die "$ROOT/etc missing"
findmnt "$ROOT"
findmnt "$ROOT/boot"

if [[ ! -f "$ARCHIVE" ]]; then
  log "Archive missing locally; fetching from yoga: $YOGA_HOST:$REMOTE_ARCHIVE"
  ssh "spencer@$YOGA_HOST" "sudo cat '$REMOTE_ARCHIVE'" > "$ARCHIVE"
fi

log "Verify archive"
ls -lh "$ARCHIVE"
zstd -t "$ARCHIVE"
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
zstd -d -c "$ARCHIVE" | tar -tf - > "$LIST"
echo "entries: $(wc -l < "$LIST")"

affirm_prefix() {
  local p=$1
  grep -q "^$p\(/\|$\)" "$LIST"
}

build_args() {
  local outvar=$1; shift
  local arr=()
  for p in "$@"; do
    if affirm_prefix "$p"; then arr+=("$p"); fi
  done
  printf -v "$outvar" '%s\n' "${arr[@]}"
}

SAFE_CANDIDATES=(
  home
  root
  var/lib/bluetooth
  var/lib/tailscale
  var/spool/cron
)
ASIDE_CANDIDATES=(
  etc/ssh
  etc/machine-id
  etc/nixos
  var/lib/iwd
  var/lib/NetworkManager
  var/log/journal
  var/lib/postgresql
  var/lib/mysql
  var/lib/docker
  var/lib/containers
)

SAFE_ARGS=()
for p in "${SAFE_CANDIDATES[@]}"; do affirm_prefix "$p" && SAFE_ARGS+=("$p"); done
ASIDE_ARGS=()
for p in "${ASIDE_CANDIDATES[@]}"; do affirm_prefix "$p" && ASIDE_ARGS+=("$p"); done

log "Restore plan"
echo "safe -> $ROOT:"
printf '  %s\n' "${SAFE_ARGS[@]:-(none)}"
echo "aside -> $ROOT$BACKUP_DIR:"
printf '  %s\n' "${ASIDE_ARGS[@]:-(none)}"
echo
sudo df -h "$ROOT" | tail -1

echo
if [[ "$ASSUME_YES" == 1 ]]; then
  echo "Proceed extracting into $ROOT? [auto-yes]"
else
  read -rp "Proceed extracting into $ROOT? [y/N] " ANS
  [[ $ANS == [yY] ]] || die "aborted"
fi

log "Copy archive to target /root"
sudo mkdir -p "$ROOT/root"
sudo install -m 0644 -o 1000 -g 100 "$ARCHIVE" "$ROOT/root/yoga-emmc-rescue.tar.zst"
sudo ls -lh "$ROOT/root/yoga-emmc-rescue.tar.zst"

if (( ${#SAFE_ARGS[@]} )); then
  log "Extract safe paths into $ROOT"
  zstd -d -c "$ARCHIVE" | sudo tar \
    --extract \
    --acls --xattrs --xattrs-include='*' \
    --numeric-owner \
    --same-owner \
    -C "$ROOT" \
    "${SAFE_ARGS[@]}"
fi

if (( ${#ASIDE_ARGS[@]} )); then
  log "Extract aside/reference paths into $ROOT$BACKUP_DIR"
  sudo mkdir -p "$ROOT$BACKUP_DIR"
  zstd -d -c "$ARCHIVE" | sudo tar \
    --extract \
    --acls --xattrs --xattrs-include='*' \
    --numeric-owner \
    --same-owner \
    -C "$ROOT$BACKUP_DIR" \
    "${ASIDE_ARGS[@]}"
fi

log "Repair home-manager managed .emacs symlink if possible"
HMFILES=$(find "$ROOT/nix/store" -maxdepth 1 -type d -name '*home-manager-files' | sort | tail -1 || true)
if [[ -n "$HMFILES" && -e "$HMFILES/.emacs" ]]; then
  sudo mkdir -p "$ROOT/home/spencer"
  sudo rm -f "$ROOT/home/spencer/.emacs"
  # Store path is absolute in the target system too; do not prefix /mnt.
  sudo ln -s "${HMFILES#$ROOT}/.emacs" "$ROOT/home/spencer/.emacs"
  sudo chown -h 1000:100 "$ROOT/home/spencer/.emacs"
  echo "linked .emacs -> ${HMFILES#$ROOT}/.emacs"
else
  echo "no home-manager-files/.emacs found; first boot home-manager will repair"
fi

log "Post-restore checks"
sudo du -sh "$ROOT/home" "$ROOT/root" "$ROOT$BACKUP_DIR" 2>/dev/null || true
sudo ls -la "$ROOT/home/spencer" | head -25 || true
sudo test -s "$ROOT/etc/ssh/ssh_host_ed25519_key"
sudo test -s "$ROOT/boot/grub/grub.cfg"

echo
log "DONE; target left mounted"
echo "Next if you want to unmount:"
echo "  sync && sudo umount $ROOT/boot && sudo umount $ROOT && sudo cryptsetup close yoga-sd-root"
