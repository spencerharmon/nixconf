# yoga-sd-io-throttle: bound write pressure on the SD root to avoid the
# F-4 emergency_ro corruption mode (docs/yoga.md).
#
# Root cause of F-4 is a marginal SD reader/contact under *sustained* write
# bursts. The card sustains ~26 MB/s (measured: dd 256 MiB oflag=direct).
# With the stock vm.dirty_ratio=20 on 3.8 GiB RAM, up to ~760 MB of dirty
# pages accumulate before the kernel forces writeback, then dump as one
# ~30 s burst at the card's ceiling -- exactly the condition that bricks a
# flaky card. The 673 MB `npm ci` churn and post-build `nix copy` into
# /nix/store are the workloads that hit this.
#
# Two layers, because cgroup io.max alone cannot cover everything:
#
#   1. vm.dirty_* (GLOBAL, primary). Caps how much dirty data can pile up
#      system-wide, so writeback is a steady trickle of small flushes rather
#      than one avalanche. This is the only lever that also bounds the
#      un-cgroupable traffic -- the ext4 journal daemon (jbd2/dm-0) and the
#      root-cgroup writeback kworkers run outside system.slice/user.slice and
#      are NOT reachable by io.max.
#
#   2. IOWriteBandwidthMax (per top-level slice, secondary). A hard bytes/sec
#      ceiling on the SD physical device for the two slices that produce the
#      bulk writes: system.slice (nix-daemon, HM system activation) and
#      user.slice (npm, emacs, interactive). Capped well under the card's
#      sustained rate. There is no single "whole system" io.max knob -- the
#      kernel rejects io.max at the root cgroup -- so it is applied to both
#      top-level slices.
#
# NOT a guarantee: a hardware layer that drops a write it claimed to accept
# cannot be prevented in software. This lowers the probability by keeping
# every burst small and slow. metadata_csum on the fs still DETECTS any
# corruption that slips through (fsck from underyoga remains the recovery).
#
# Tuning knobs live here; re-benchmark with
#   sudo dd if=/dev/zero of=/root/.wrbench bs=1M count=256 oflag=direct; rm /root/.wrbench
# if the card is replaced, and adjust the cap below.
{ ... }:
let
  # SD physical device. Throttle the card itself, not the dm-crypt mapper.
  sdDevice = "/dev/mmcblk0";
  # Hard write ceiling: 13 MB/s, half the measured 26 MB/s sustained rate.
  # Leaves ample headroom so bursts never approach the card's limit.
  writeBpsMax = "13M";
in
{
  # Layer 1: global dirty-page bounds. Small absolute byte limits (not
  # ratios) so behaviour is independent of RAM size. 16 MiB background
  # (writeback starts early) / 48 MiB hard (writers throttle) means at most
  # ~2 s of card-rate writes can be queued before the kernel pushes back.
  boot.kernel.sysctl = {
    "vm.dirty_background_bytes" = 16 * 1024 * 1024;
    "vm.dirty_bytes" = 48 * 1024 * 1024;
    # Flush aged dirty data sooner so it does not batch into a burst.
    "vm.dirty_expire_centisecs" = 1500; # 15 s (was 30 s)
    "vm.dirty_writeback_centisecs" = 500; # 5 s (default; explicit for clarity)
  };

  # Layer 2: hard per-slice write-bandwidth ceiling on the SD device.
  # Applied to both top-level slices; the kernel disallows io.max at the
  # cgroup root, so there is no single system-wide target.
  systemd.slices.system.sliceConfig.IOWriteBandwidthMax = "${sdDevice} ${writeBpsMax}";
  systemd.slices.user.sliceConfig.IOWriteBandwidthMax = "${sdDevice} ${writeBpsMax}";
}
