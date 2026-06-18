#!/usr/bin/env bash
# Restore a yoga-emmc-rescue.tar.zst archive (made by
# scripts/rescue-yoga-emmc.sh) onto the running system.
#
# Default behaviour is CONSERVATIVE: only the categories that have
# no overlap with a fresh nixos-install go to their original paths.
# Categories that conflict (host SSH keys, machine-id, /etc/nixos)
# land in /var/lib/yoga-emmc-backup/ for manual inspection instead.
#
# Per-category disposition:
#
#   home                          -> safe        (default: extract to /home)
#   root                          -> safe        (default: extract to /root)
#   etc/ssh                       -> aside       (would overwrite new host key)
#   etc/machine-id                -> aside       (systemd identity collision)
#   etc/nixos                     -> aside       (we use flake config now)
#   var/lib/iwd                   -> aside       (new install uses wpa_supplicant)
#   var/lib/NetworkManager        -> aside       (same)
#   var/lib/bluetooth             -> safe        (pairings; no collision)
#   var/lib/systemd/random-seed   -> skip        (running system has its own)
#   var/lib/tailscale             -> safe        (state; tailscaled handles re-key)
#   var/lib/postgresql            -> aside       (would overwrite DB; opt-in)
#   var/lib/mysql                 -> aside       (same)
#   var/lib/docker                -> aside       (huge; opt-in)
#   var/lib/containers            -> aside       (same)
#   var/spool/cron                -> safe        (crontabs)
#   var/log/journal               -> aside       (would mix with new journal)
#
# Flags:
#   --dry-run         List what would happen; don't extract.
#   --force-ssh       Restore host SSH keys to /etc/ssh (DANGEROUS:
#                     breaks agenix decryption of secrets encrypted
#                     to the new key).
#   --force-machine-id  Restore /etc/machine-id (DANGEROUS).
#   --force-nm        Restore NetworkManager state.
#   --force-iwd       Restore iwd state.
#   --force-db        Restore postgresql/mysql state (overwrites!).
#   --force-containers Restore docker/containers state.
#
# Usage:
#   sudo ./restore-yoga-emmc.sh /path/to/yoga-emmc-rescue.tar.zst
set -euo pipefail

ARCHIVE="${1:-}"
shift || true

DRY_RUN=0
FORCE_SSH=0
FORCE_MACHINE_ID=0
FORCE_NM=0
FORCE_IWD=0
FORCE_DB=0
FORCE_CONTAINERS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)           DRY_RUN=1 ;;
        --force-ssh)         FORCE_SSH=1 ;;
        --force-machine-id)  FORCE_MACHINE_ID=1 ;;
        --force-nm)          FORCE_NM=1 ;;
        --force-iwd)         FORCE_IWD=1 ;;
        --force-db)          FORCE_DB=1 ;;
        --force-containers)  FORCE_CONTAINERS=1 ;;
        -h|--help)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown flag $1" >&2
            exit 1
            ;;
    esac
    shift
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*"; }

[[ -n $ARCHIVE ]] || die "usage: $0 <archive.tar.zst> [--dry-run] [flags]"
[[ -f $ARCHIVE ]] || die "archive not found: $ARCHIVE"
[[ $(id -u) -eq 0 ]] || die "run as root (sudo $0 ...)"

# Verify it's a zstd-compressed tar that we can read.
log "Verifying archive"
if ! zstd -t "$ARCHIVE" 2>/dev/null; then
    die "$ARCHIVE failed zstd integrity check."
fi
ARCHIVE_LIST=$(mktemp)
trap 'rm -f "$ARCHIVE_LIST"' EXIT
zstd -d -c "$ARCHIVE" | tar -tf - > "$ARCHIVE_LIST" 2>/dev/null || die "tar listing failed"

ENTRIES=$(wc -l < "$ARCHIVE_LIST")
echo "archive contains $ENTRIES entries"

ASIDE_ROOT=/var/lib/yoga-emmc-backup
mkdir -p "$ASIDE_ROOT"

# Disposition table. Each row: "<top-level-path-prefix>|<disposition>|<reason>"
# Order matters: first matching prefix wins.
TABLE=(
    "home/|safe|user data"
    "root/|safe|root home"
    "etc/ssh/|aside|host SSH keys would overwrite new agenix-managed key"
    "etc/machine-id|aside|systemd identity collision"
    "etc/nixos/|aside|we use flake config now"
    "var/lib/iwd/|aside|new install uses wpa_supplicant"
    "var/lib/NetworkManager/|aside|new install uses wpa_supplicant"
    "var/lib/bluetooth/|safe|paired-device keys"
    "var/lib/systemd/random-seed|skip|running system has its own"
    "var/lib/tailscale/|safe|tailscale state"
    "var/lib/postgresql/|aside|would overwrite DB"
    "var/lib/mysql/|aside|would overwrite DB"
    "var/lib/docker/|aside|likely huge"
    "var/lib/containers/|aside|likely huge"
    "var/spool/cron/|safe|crontabs"
    "var/log/journal/|aside|would mix with current journal"
)

apply_force_overrides() {
    local entry="$1"
    case "$entry" in
        "etc/ssh/"*)               (( FORCE_SSH ))         && echo "safe" || echo "aside" ;;
        "etc/machine-id"*)         (( FORCE_MACHINE_ID ))  && echo "safe" || echo "aside" ;;
        "var/lib/NetworkManager/"*) (( FORCE_NM ))         && echo "safe" || echo "aside" ;;
        "var/lib/iwd/"*)           (( FORCE_IWD ))         && echo "safe" || echo "aside" ;;
        "var/lib/postgresql/"*)    (( FORCE_DB ))          && echo "safe" || echo "aside" ;;
        "var/lib/mysql/"*)         (( FORCE_DB ))          && echo "safe" || echo "aside" ;;
        "var/lib/docker/"*)        (( FORCE_CONTAINERS ))  && echo "safe" || echo "aside" ;;
        "var/lib/containers/"*)    (( FORCE_CONTAINERS ))  && echo "safe" || echo "aside" ;;
        *) echo "" ;;
    esac
}

classify() {
    local entry="$1"
    # Try force overrides first
    local forced
    forced=$(apply_force_overrides "$entry")
    if [[ -n $forced ]]; then
        echo "$forced"
        return
    fi
    # Then the table
    for row in "${TABLE[@]}"; do
        local prefix="${row%%|*}"
        local rest="${row#*|}"
        local disp="${rest%%|*}"
        if [[ $entry == "$prefix"* ]]; then
            echo "$disp"
            return
        fi
    done
    # Default: aside, because we don't know what it is
    echo "aside"
}

# Build per-category file lists for tar's --files-from extraction.
SAFE_LIST=$(mktemp)
ASIDE_LIST=$(mktemp)
SKIP_LIST=$(mktemp)
trap 'rm -f "$ARCHIVE_LIST" "$SAFE_LIST" "$ASIDE_LIST" "$SKIP_LIST"' EXIT

declare -A TOP_REASONS
while IFS= read -r entry; do
    # Skip directory-only entries (they get created automatically by tar -x)
    # Actually, keep them so empty dirs survive; tar handles either way.
    disp=$(classify "$entry")
    case "$disp" in
        safe)  echo "$entry" >> "$SAFE_LIST" ;;
        aside) echo "$entry" >> "$ASIDE_LIST" ;;
        skip)  echo "$entry" >> "$SKIP_LIST" ;;
    esac
done < "$ARCHIVE_LIST"

# Per-top-level summary
log "Disposition summary (per top-level path in archive)"
printf '%-40s %-7s %s\n' "top-level entry" "files" "disposition"
printf '%-40s %-7s %s\n' "----------------------------------------" "-------" "-----------"
declare -A TOPS
while IFS= read -r entry; do
    # First path component as the grouping key
    top="${entry%%/*}"
    if [[ $entry == "$top" ]]; then
        TOPS["$top"]+=$(printf 'X')
    else
        # Two-level for things like var/lib/xxx
        case "$top" in
            etc|var) top="${entry%%/*}/$(echo "$entry" | cut -d/ -f2)"; [[ $top == */ ]] && top="${top%/}" ;;
        esac
        case "$top" in
            var) top="$(echo "$entry" | cut -d/ -f1-3)" ;;
        esac
        TOPS["$top"]+=$(printf 'X')
    fi
done < "$ARCHIVE_LIST"

# Simpler: just emit dispositions per first-1-or-2 path components.
declare -A SEEN_GROUPS
while IFS= read -r entry; do
    # Bucket: first 2 components for var/lib and etc; first 1 otherwise.
    case "$entry" in
        var/lib/*) group=$(echo "$entry" | cut -d/ -f1-3) ;;
        etc/*)     group=$(echo "$entry" | cut -d/ -f1-2) ;;
        *)         group=$(echo "$entry" | cut -d/ -f1) ;;
    esac
    group="${group%/}"
    if [[ -z ${SEEN_GROUPS[$group]:-} ]]; then
        SEEN_GROUPS[$group]=1
        # Sample one entry under this group to classify
        sample=$(grep -m1 "^$group" "$ARCHIVE_LIST" || echo "$entry")
        disp=$(classify "$sample")
        # Count files
        count=$(grep -c "^$group" "$ARCHIVE_LIST" || true)
        printf '%-40s %-7s %s\n' "$group" "$count" "$disp"
    fi
done < "$ARCHIVE_LIST"

SAFE_COUNT=$(wc -l < "$SAFE_LIST")
ASIDE_COUNT=$(wc -l < "$ASIDE_LIST")
SKIP_COUNT=$(wc -l < "$SKIP_LIST")
log "Totals: safe=$SAFE_COUNT  aside=$ASIDE_COUNT  skip=$SKIP_COUNT"
echo "  safe  -> extracted into / (original locations)"
echo "  aside -> extracted into $ASIDE_ROOT (for inspection)"
echo "  skip  -> not extracted"
echo
echo "Aside paths can be promoted later with e.g.:"
echo "  rsync -a $ASIDE_ROOT/var/lib/bluetooth/ /var/lib/bluetooth/"

if (( DRY_RUN )); then
    log "DRY RUN — no extraction. Re-run without --dry-run to apply."
    exit 0
fi

read -rp "Proceed with extraction? [y/N] " ANS
[[ $ANS == [yY] ]] || die "Aborted."

if [[ -s $SAFE_LIST ]]; then
    log "Extracting safe paths into / "
    zstd -d -c "$ARCHIVE" | tar \
        --extract \
        --acls --xattrs --xattrs-include='*' \
        --numeric-owner \
        --keep-directory-symlink \
        -C / \
        --files-from "$SAFE_LIST" \
        --verbose 2>&1 | tail -20
fi

if [[ -s $ASIDE_LIST ]]; then
    log "Extracting aside paths into $ASIDE_ROOT"
    mkdir -p "$ASIDE_ROOT"
    zstd -d -c "$ARCHIVE" | tar \
        --extract \
        --acls --xattrs --xattrs-include='*' \
        --numeric-owner \
        -C "$ASIDE_ROOT" \
        --files-from "$ASIDE_LIST" \
        --verbose 2>&1 | tail -20
fi

if [[ -s $SKIP_LIST ]]; then
    log "Skipped:"
    head -5 "$SKIP_LIST"
    if (( SKIP_COUNT > 5 )); then
        echo "  ... and $((SKIP_COUNT - 5)) more"
    fi
fi

log "DONE"
echo "Restored to / : $SAFE_COUNT files"
echo "Set aside in $ASIDE_ROOT: $ASIDE_COUNT files"
echo
echo "Review the aside paths before promoting them. Example:"
echo "  sudo ls $ASIDE_ROOT/etc/ssh/"
echo "  sudo ls $ASIDE_ROOT/var/log/journal/"
echo
echo "To use the recovered journal alongside the running one:"
echo "  sudo journalctl -D $ASIDE_ROOT/var/log/journal --no-pager | head"
