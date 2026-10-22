{ config, lib, pkgs, ... }:
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
    ../chrome-performance.nix
  ];

  services.k3s = {
    enable = true;
    role = "server";
    # Pin the advertised node IP to this host's primary IPv4 address.
    # Without it k3s auto-detects per boot and can flip to the IPv6 address,
    # after which it no longer matches its own etcd member URL and never
    # becomes ready. The address is derived at start (below), not hardcoded.
    extraFlags = [
      "--node-ip=\${K3S_NODE_IP}"
      # zram swap is on (profiles/chrome-performance.nix); kubelet refuses
      # to start with swap present unless told otherwise.
      "--kubelet-arg=fail-swap-on=false"
    ];
  };

  systemd.services.k3s.serviceConfig = {
    ExecStartPre = [
      "${pkgs.writeShellScript "k3s-node-ip" ''
        set -euo pipefail
        ip4=$(${pkgs.iproute2}/bin/ip -4 -o route get 1.1.1.1 \
          | ${pkgs.gnused}/bin/sed -n 's/.* src \([0-9.]*\).*/\1/p')
        [ -n "$ip4" ] || { echo "k3s-node-ip: no IPv4 default-route source" >&2; exit 1; }
        echo "K3S_NODE_IP=$ip4" > /run/k3s-node-ip.env
      ''}"
    ];
    # The agenix env file (token/URL) plus the per-boot node-ip file written
    # by ExecStartPre (systemd re-reads EnvironmentFile per spawned command).
    EnvironmentFile = lib.mkForce [
      config.services.k3s.environmentFile
      "-/run/k3s-node-ip.env"
    ];
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
