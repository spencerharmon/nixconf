# yoga-sd-1: second SD-card-resident yoga.
#
# Identity supplied here; all behaviour comes from profiles/yoga-sd.nix
# and the standard yoga module set in flake.nix. Structurally identical
# to systems/yoga-sd-0/configuration.nix — only the per-card identity
# (root label + this card's PARTUUIDs) differs. Hostname stays "yoga"
# and the shared agenix yoga host key is reused (see profiles/yoga-sd.nix).
#
# The two PARTUUIDs below are per-card and only exist AFTER this SD is
# partitioned. They are NOT hand-authored: scripts/deploy-yoga-sd-1-encrypted.sh
# reads them with `blkid` immediately after partitioning and rewrites the
# `yogaSd` block below with the real values before it builds the closure.
# The placeholders here are deliberately non-matching so a build that was
# NOT run through the deploy script fails to find a root device at boot
# (loud fail) instead of silently booting some other card.
#
# Manual populate (same commands the deploy script runs), if ever needed:
#
#   sudo parted /dev/sdX -- mklabel msdos
#   sudo parted /dev/sdX -- mkpart primary ext4 1MiB 1025MiB
#   sudo parted /dev/sdX -- set 1 boot on
#   sudo parted /dev/sdX -- mkpart primary 1025MiB 100%
#   sudo mkfs.ext4 -L yoga-sd-boot /dev/sdX1
#   sudo cryptsetup luksFormat --type luks2 \
#       --cipher aes-xts-plain64 --key-size 256 \
#       --pbkdf argon2id --pbkdf-memory 524288 --pbkdf-parallel 2 \
#       --iter-time 2000 \
#       /dev/sdX2
#   sudo cryptsetup open /dev/sdX2 yoga-sd-root
#   sudo mkfs.ext4 -L yoga-sd-1-root /dev/mapper/yoga-sd-root
#
#   blkid -s PARTUUID -o value /dev/sdX1   # -> bootPartUuid
#   blkid -s PARTUUID -o value /dev/sdX2   # -> luksPartUuid
{ ... }:
{
  yogaSd = {
    bootPartUuid = "UNPOPULATED-run-deploy-yoga-sd-1-encrypted.sh-boot";
    luksPartUuid = "UNPOPULATED-run-deploy-yoga-sd-1-encrypted.sh-luks";

    rootLabel = "yoga-sd-1-root";
  };
}
