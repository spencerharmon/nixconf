# yoga-sd-0: first SD-card-resident yoga.
#
# Identity supplied here; all behaviour comes from profiles/yoga-sd.nix
# and the standard yoga module set in flake.nix.
#
# To populate the PARTUUIDs after partitioning the SD on the installer:
#
#   sudo parted /dev/sdb -- mklabel msdos
#   sudo parted /dev/sdb -- mkpart primary ext4 1MiB 1025MiB
#   sudo parted /dev/sdb -- set 1 boot on
#   sudo parted /dev/sdb -- mkpart primary 1025MiB 100%
#   sudo mkfs.ext4 -L yoga-sd-boot /dev/sdb1
#   sudo cryptsetup luksFormat --type luks2 \
#       --cipher aes-xts-plain64 --key-size 256 \
#       --pbkdf argon2id --pbkdf-memory 524288 --pbkdf-parallel 2 \
#       --iter-time 2000 \
#       /dev/sdb2
#   sudo cryptsetup open /dev/sdb2 yoga-sd-root
#   sudo mkfs.ext4 -L yoga-sd-0-root /dev/mapper/yoga-sd-root
#
#   blkid -s PARTUUID -o value /dev/sdb1   # -> bootPartUuid
#   blkid -s PARTUUID -o value /dev/sdb2   # -> luksPartUuid
{ ... }:
{
  yogaSd = {
    bootPartUuid = "6d223f66-01";
    luksPartUuid = "6d223f66-02";

    rootLabel = "yoga-sd-0-root";
  };
}
