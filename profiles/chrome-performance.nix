{ ... }:
# Throughput tuning for the chrome fleet: HP Chromebox CB1, Celeron 2955U
# (Haswell-ULT, 2C/2T @ 1.4 GHz fixed, no turbo, no AVX/AES-NI), 4-8 GiB RAM.
# These are single-tenant LAN servers running only our own workloads, so the
# speculative-execution mitigations are traded away for throughput.
{
  boot.kernelParams = [
    # All CPU vulnerability mitigations off: PTI (Meltdown, the largest cost
    # on Haswell for syscall-heavy k3s/etcd/containerd), retpolines/IBPB
    # (Spectre v2), MDS/L1TF buffer clearing, SSBD, SRBDS, VMSCAPE.
    # RISK: a malicious workload could read other pods'/kernel memory. Do not
    # run untrusted code on these nodes.
    "mitigations=off"
    # No soft/hard-lockup watchdog: periodic NMIs/hrtimers for a headless box
    # that has nobody to report to.
    "nowatchdog"
    "nmi_watchdog=0"
  ];

  # Clock is capped at 1.4 GHz with no turbo; don't drop to 800 MHz between
  # bursts.
  powerManagement.cpuFreqGovernor = "performance";

  # Compressed RAM swap (no disk swap): cheap headroom on 4-8 GiB nodes
  # before the OOM killer. k3s's kubelet is told to tolerate swap
  # (profiles/k3s/k3s-common.nix); pods themselves don't swap (NoSwap).
  zramSwap = {
    enable = true;
    memoryPercent = 50;
    algorithm = "zstd";
  };
  boot.kernel.sysctl = {
    # zram is far cheaper than disk: swap anonymous memory before evicting
    # page cache, and don't read ahead from a RAM device.
    "vm.swappiness" = 100;
    "vm.page-cluster" = 0;
  };

  # Unused CB1 hardware: Atheros AR9462 Wi-Fi/Bluetooth, HD audio.
  boot.blacklistedKernelModules = [
    "ath9k"
    "ath3k"
    "btusb"
    "snd_hda_intel"
    "snd_hda_codec_hdmi"
  ];
}
