{ lib, pkgs, modulesPath, ... }:
# Headless NixOS installer for the chrome fleet (HP Chromebox CB1, MrChromebox
# UEFI). Boots to DHCP + sshd with the admin key, so a box with no console can
# be (re)installed over SSH. Built from the same nixpkgs-chrome pin as the
# hosts so `nixos-install --flake .#chromeN` needs no extra fetches for the
# base system.
#
# Build:  nix build .#nixosConfigurations.chrome-installer.config.system.build.isoImage
# Write:  sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  networking.hostName = "chrome-installer";

  # Reachable with no console: sshd up at boot, key-only root + nixos login.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = lib.mkForce "prohibit-password";
      PasswordAuthentication = false;
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID+HZIIpyKjtjEgGktsmicRO0qpyCiPnD2YGhBgZAUXj spencer@spray"
  ];
  users.users.nixos.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID+HZIIpyKjtjEgGktsmicRO0qpyCiPnD2YGhBgZAUXj spencer@spray"
  ];

  # DHCP on whatever wired NIC appears (RTL8111 on the CB1).
  networking.useDHCP = lib.mkForce true;
  networking.wireless.enable = lib.mkForce false;

  # Advertise via mDNS so the installer is findable as chrome-installer.local
  # even if the DHCP lease is unknown.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  # Don't hang at the boot menu waiting for a keypress that never comes.
  boot.loader.timeout = lib.mkForce 3;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = with pkgs; [
    git
    efibootmgr
    gptfdisk
    parted
    smartmontools
    pciutils
    dmidecode
    rsync
  ];
}
