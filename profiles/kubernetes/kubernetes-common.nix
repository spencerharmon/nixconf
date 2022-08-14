{ pkgs, ... }: {
  imports = [
    ../common.nix
  ];
  environment = {
    systemPackages = with pkgs; [
      kubectl
      kubeadm
    ];
  };
}
