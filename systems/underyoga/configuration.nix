# underyoga: minimal eMMC-resident NixOS for yoga.
#
# Identity supplied here; behaviour comes from profiles/underyoga.nix
# and the standard base modules. NOT a yoga-sd; does NOT import the
# laptop/spencer-home/coding-agents/ai-tools profiles. underyoga is
# a console-only recovery + dispatcher.
#
# To populate the PARTUUIDs after partitioning the eMMC on yoga, see
# scripts/reformat-emmc-underyoga.sh -- it prints the two PARTUUIDs
# at the end.
{ ... }:
{
  underyoga = {
    bootPartUuid = "c71b60b7-01";
    luksPartUuid = "c71b60b7-02";
    installDevice = "/dev/mmcblk1";
  };
}
