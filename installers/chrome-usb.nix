{ lib, pkgs, modulesPath, ... }:
# "chrome-usb": a regular installed NixOS that lives on a USB stick, used to
# (re)install chrome-fleet boxes (HP Chromebox CB1, MrChromebox UEFI) that
# have no console. Unlike the live ISO (which hung on CB1 hardware with no
# way to see why), this boots exactly like an installed chrome host —
# systemd-boot, a plain ext4 root, dhcpcd only — and keeps a PERSISTENT
# journal on the stick, so a failed boot can be diagnosed afterwards by
# plugging the stick into any host.
#
# Layout (labels are distinct from the hosts' NIXBOOT/NIXROOT so the stick
# never mounts, or is mistaken for, an internal disk):
#   GPT p1  512M  vfat  ESP      -> /boot  (systemd-boot + \EFI\BOOT\BOOTX64.EFI)
#   GPT p2  rest  ext4  USBROOT  -> /      (grown to fill the stick on 1st boot)
#
# Built as a complete raw disk image (packages.x86_64-linux.chrome-usb-image)
# and written sequentially — installing file-by-file onto a cheap USB 2.0
# stick runs at ~170 KiB/s, a sequential dd at ~5 MB/s:
#   nix build .#chrome-usb-image
#   dd if=result/nixos.img of=/dev/disk/by-id/usb-<stick> bs=4M conv=fsync oflag=direct
# Boot it headless with a one-time `efibootmgr --bootnext`, or simply by
# having no other bootable disk.
{
  imports = [
    "${modulesPath}/installer/scan/not-detected.nix"
    "${modulesPath}/profiles/all-hardware.nix"
  ];

  networking.hostName = "chrome-usb";
  system.stateVersion = "26.05";

  fileSystems."/" = {
    device = "/dev/disk/by-label/USBROOT";
    fsType = "ext4";
    options = [ "noatime" ];
    autoResize = true;
  };
  boot.growPartition = true;
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # Removable media: never write firmware boot variables at install time;
  # bootctl also installs the \EFI\BOOT\BOOTX64.EFI fallback the firmware
  # boots when no other disk is bootable.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.timeout = 1;

  boot.initrd.availableKernelModules = [
    "xhci_pci" "ehci_pci" "usb_storage" "uas" "sd_mod" "ahci"
  ];
  hardware.enableRedistributableFirmware = true;

  # Same network stack as the installed chrome hosts: dhcpcd only (no
  # NetworkManager), on whatever wired NIC appears.
  networking.useDHCP = true;
  networking.networkmanager.enable = false;
  networking.wireless.enable = false;

  # Advertise as chrome-usb.local in case the lease is unknown.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID+HZIIpyKjtjEgGktsmicRO0qpyCiPnD2YGhBgZAUXj spencer@spray"
  ];

  # Post-mortem: keep the journal on the stick across boots.
  services.journald.storage = "persistent";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "spencer" ];
  };

  environment.systemPackages = with pkgs; [
    git
    efibootmgr
    gptfdisk
    parted
    dosfstools
    e2fsprogs
    xfsprogs
    smartmontools
    pciutils
    dmidecode
    rsync
  ];
}
