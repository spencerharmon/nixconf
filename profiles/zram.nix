{ lib, ... }:
{
  # Compressed RAM swap. Yoga has ~4 GiB RAM and slow flash-backed
  # storage; zram absorbs memory spikes without writing swap traffic
  # to eMMC/SD. Kernel zstd is the NixOS default and gives better
  # effective capacity than lz4; CPU has AES-NI but no AVX2, still
  # fast enough for swap pressure compared to eMMC I/O.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    # 50% of 3.8 GiB RAM => ~1.9 GiB zram device. Actual physical RAM
    # consumed is compressed pages only, allocated on demand.
    memoryPercent = 50;
    # Prefer zram over any disk swap if one exists by accident.
    priority = 100;
  };

  # Yoga-family systems should not use flash-backed swapfiles. This
  # overrides systems/yoga/hardware-configuration.nix's old /var/swapfile
  # definition when this profile is imported.
  swapDevices = lib.mkForce [ ];
}
