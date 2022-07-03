{ pkgs, ... }: {
  imports = [
    ./common.nix
  ];
  environment = {
    systemPackages = with pkgs; [
      kubeadm
      containerd
    ];
  };
}
