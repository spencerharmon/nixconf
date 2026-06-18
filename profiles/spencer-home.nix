{ config, lib, pkgs, inputs, ... }:
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "hm-bak";

  home-manager.extraSpecialArgs = { inherit inputs; };
  home-manager.users.spencer = import ../home/spencer.nix;

  # Don't gate user-sessions (login screen) on HM activation; it adds ~5s
  # to boot on yoga and isn't required for login.
  systemd.services.home-manager-spencer.unitConfig.Before = lib.mkForce "";
}
