{ pkgs, ... }: {
  imports = [
    ./kubernetes-common.nix
  ];
  services.kubernetes = {
    roles = [ "master" "node" ];
  };
}
