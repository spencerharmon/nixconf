{ config, pkgs, ... }:
{
  environment.systemPackages = [ pkgs.claude-code ];
  nixpkgs.config.allowUnfree = true;
}
