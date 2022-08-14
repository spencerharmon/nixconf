{ pkgs, ... }: {
  imports = [
    ../common.nix
  ];
  environment = {
    systemPackages = with pkgs; [
      kubectl
      cni
      cni-plugins
      cni-plugin-flannel
    ];
  };
}
