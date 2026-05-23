{ config, pkgs, inputs, ... }:
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "hm-bak";

  home-manager.users.spencer = import ../home/spencer.nix;
}
