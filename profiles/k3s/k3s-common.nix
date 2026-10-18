{ pkgs, ... }:
# Shared k3s settings for the chrome fleet. Every chrome node is a k3s
# SERVER (control plane + etcd member + workload node): an HA embedded-etcd
# cluster. Exactly one node bootstraps the cluster (server-init.nix); the
# others join it (server-join.nix).
#
# Cluster identity (join token, join URL) is NOT in this public repo: it
# comes from an agenix-encrypted EnvironmentFile (K3S_TOKEN / K3S_URL) that
# the role profiles wire in.
{
  imports = [
    ../common.nix
  ];

  services.k3s = {
    enable = true;
    role = "server";
  };

  networking.firewall = {
    allowedTCPPorts = [
      6443 # k3s supervisor + kube-apiserver
      2379 # etcd client
      2380 # etcd peer
      10250 # kubelet metrics
    ];
    allowedTCPPortRanges = [
      { from = 30000; to = 32767; } # NodePort services
    ];
    allowedUDPPorts = [
      8472 # flannel VXLAN
    ];
    trustedInterfaces = [ "cni0" "flannel.1" ];
  };

  # Stable (non-privacy) IPv6 source addresses: these are servers, and the
  # per-host DDNS AAAA record (profiles/cloudflare-ddns.nix) must not chase
  # a rotating temporary address.
  networking.tempAddresses = "disabled";

  environment.systemPackages = with pkgs; [
    kubectl
  ];
}
