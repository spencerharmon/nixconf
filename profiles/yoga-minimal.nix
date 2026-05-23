{ config, pkgs, lib, ... }:
# Intentionally-minimal yoga config for performing nixpkgs version jumps
# on yoga's 15G root. Drops desktop bits (X, lightdm, emacs-gui, firefox,
# pipewire, python) so the closure fits alongside the running system.
# Switch back to ./laptop.nix after the upgrade.
{
  imports = [ ./common.nix ];

  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # Force-disable heavy desktop stack pulled in by host config.
  services.xserver.enable = lib.mkForce false;
}

