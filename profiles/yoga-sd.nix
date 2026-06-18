# yoga-sd profile: SD-card-resident encrypted yoga.
#
# Each physical SD card has its own NixOS system target (yoga-sd-0,
# yoga-sd-1, ...). All of them import this profile for the shared
# boot/LUKS/wifi/grub plumbing, and supply per-SD identity (PARTUUIDs,
# labels, host SSH keys) via a small per-card config under
# systems/yoga-sd-<n>/.
#
# Layout assumed on each SD (created at install time):
#   MBR (msdos) partition table
#   sdX1 = /boot, ext4, label=yoga-sd-boot,  ~1 GiB, boot flag set
#          UNENCRYPTED. Holds grub stage2 cfg + kernels. GRUB on
#          legacy BIOS cannot read LUKS2; /boot must be cleartext.
#   sdX2 = LUKS2 container, rest of device
#          PARTUUID = unique per SD
#          └─ ext4 inside, label per SD (e.g. yoga-sd-0-root)
#             Mounted at /. Holds /nix, /var, /home, /etc, /root.
#
# Boot path: SeaBIOS POST -> SD MBR -> grub stage1 -> stage1.5 in
# post-MBR gap -> stage2 reads /boot/grub/grub.cfg via grub's ext4
# driver -> selects generation -> loads kernel + initrd from
# /boot/kernels/ -> kernel boots, scripted initrd initializes i915
# early, prompts on tty0 for LUKS password -> unlocks SD root ->
# mounts at /sysroot -> pivot.
#
# Device-name enumeration order at boot time is irrelevant: every
# reference inside the system uses by-label or by-partuuid, and grub
# stage1.5 reads stage2 via its own fs driver, not via kernel device
# nodes.
#
# Network: each SD's host key is added to secrets/secrets.nix and the
# wifi-yoga.age secret is re-encrypted to include it, so the existing
# wifi-yoga.nix profile works unchanged.
#
# Multi-SD cross-mount (when one SD's system wants to mount another
# SD's data or underyoga): handled via a keyfile in slot 1 of each
# LUKS container. Keyfile lives at /etc/keys/cross-sd.key on each
# mounted SD root and is referenced by name from cryptsetup when
# opening other LUKS volumes post-boot. Initrd never uses the
# keyfile; it always password-prompts for the SD root being booted.
#
# Per-card module MUST set:
#   _module.args.yogaSd = {
#     bootPartUuid = "<sdX1 partuuid>";
#     luksPartUuid = "<sdX2 partuuid>";
#     rootLabel    = "yoga-sd-<n>-root";
#   };
#
# The current block device path (/dev/sdb, /dev/sdc, etc.) is NOT part
# of this NixOS configuration. It is an install-script concern only.
#
# The per-card module is also where any card-specific extras live
# (different package sets per workload, etc).
{ config, lib, pkgs, ... }:
let
  yogaSd = config.yogaSd or (throw
    "yoga-sd profile: per-card module must set config.yogaSd { bootPartUuid, luksPartUuid, rootLabel }");
in {
  options.yogaSd = lib.mkOption {
    type = lib.types.submodule {
      options = {
        bootPartUuid = lib.mkOption {
          type = lib.types.str;
          description = "PARTUUID of the /boot partition on this SD.";
        };
        luksPartUuid = lib.mkOption {
          type = lib.types.str;
          description = "PARTUUID of the LUKS container partition on this SD.";
        };
        rootLabel = lib.mkOption {
          type = lib.types.str;
          description = "ext4 label of the unlocked root filesystem inside the LUKS container.";
        };
        luksMapperName = lib.mkOption {
          type = lib.types.str;
          default = "yoga-sd-root";
          description = "dm-crypt mapper name for the unlocked root.";
        };
      };
    };
    description = "Per-SD identity (PARTUUIDs, labels) supplied by the per-card module.";
  };

  config = {
    # Hostname matches the canonical "yoga" so the existing
    # wifi-yoga.age agenix secret is decryptable from any SD that has
    # its host key added to secrets/secrets.nix as a recipient.
    networking.hostName = lib.mkForce "yoga";

    # /boot on the SD, ext4, unencrypted.
    fileSystems."/boot" = lib.mkForce {
      device = "/dev/disk/by-partuuid/${yogaSd.bootPartUuid}";
      fsType = "ext4";
      # Avoid metadata writes from reads. Do not use commit=60 on /boot:
      # losing a minute of kernel/grub writes during rebuild could leave
      # the SD harder to recover.
      options = [ "noatime" ];
    };

    # / on the unlocked LUKS mapper. by-label is unique per SD, so even
    # if multiple SDs are inserted, this mounts the *correct* unlocked
    # mapper (which was opened with the per-SD luksPartUuid above).
    fileSystems."/" = lib.mkForce {
      device = "/dev/disk/by-label/${yogaSd.rootLabel}";
      fsType = "ext4";
      # SD-card wear reduction: no read-time metadata writes, and batch
      # ext4 journal commits up to 60s. Tradeoff: crash/power-loss can
      # lose up to ~60s of recent writes; acceptable for this high-
      # endurance SD root after fsck validated clean.
      options = [ "noatime" "commit=60" ];
    };

    # No swap on SD (flash wear).
    swapDevices = lib.mkForce [ ];

    # Initrd unlocks the SD root by prompting for the password.
    # PARTUUID is unique per SD, so even with multiple LUKS devices
    # present, only this one is opened by this system.
    boot.initrd.luks.devices.${yogaSd.luksMapperName} = {
      device = "/dev/disk/by-partuuid/${yogaSd.luksPartUuid}";
      # No keyFile here: prompt at boot. Slot 1's keyfile is for
      # post-boot cross-SD mounts, not for initrd unlock of self.
      preLVM = true;
      # Help SD endurance by letting TRIM/discard propagate to flash
      # erase blocks.
      allowDiscards = true;
    };

    # Modules initrd needs for SD enumeration + LUKS. Most are already
    # in systems/yoga/hardware-configuration.nix; this is defensive.
    boot.initrd.availableKernelModules = lib.mkAfter [
      # SD readers seen on yoga:
      "sdhci_acpi" "mmc_block"             # internal SD slot enumerates here
      "usb_storage" "uas" "sd_mod"         # USB card reader path
      # LUKS. Use generic module names that exist across kernel
      # versions: `aes` pulls aesni-intel on x86_64 with AES-NI; xts
      # / sha256 / sha512 are crypto API modules; dm_crypt is the
      # device-mapper target. NixOS auto-pulls everything needed by
      # boot.initrd.luks.devices, but listing them explicitly here
      # documents the dependency and survives unrelated kernel
      # config changes.
      "dm_crypt" "aes" "xts" "sha256" "sha512"
    ];

    # Force the legacy scripted initrd for LUKS unlock.
    # systems/yoga/hardware-configuration.nix enables systemd-initrd
    # (boot.initrd.systemd.enable = true) as a boot-time optimisation
    # on the unencrypted-eMMC layout. On the LUKS-on-SD layout it
    # appears to interact badly with Braswell's slow i915 modeset:
    # systemd-cryptsetup's password agent writes the prompt to a tty
    # that isn't renderable yet, so the user sees a black screen
    # with no prompt and no kernel output. The scripted initrd uses
    # the still-functional VGA text console for the prompt, which
    # works regardless of KMS state.
    #
    # Confirmed 2026-06-14: a no-LUKS install on the same SD boots
    # fine with systemd-initrd; adding LUKS reproduces the black
    # screen. See chat log + docs/yoga-storage-redesign.md.
    boot.initrd.systemd.enable = lib.mkForce false;

    # Match the display fix proven on underyoga: tty0 follows the
    # active console, and i915 in initrd modesets the Braswell panel
    # before the scripted initrd asks for the LUKS passphrase. Without
    # this, the prompt is invisible even though typed input works.
    boot.kernelParams = lib.mkForce [ "console=tty0" ];
    boot.initrd.kernelModules = lib.mkAfter [ "i915" ];

    # GRUB on legacy BIOS. The NixOS configuration is intentionally
    # device-independent: the current installer-visible block path
    # (/dev/sdb, /dev/sdc, ...) is not stable and must not be baked
    # into the closure. `nodev` makes NixOS generate grub.cfg/kernels
    # but skip MBR installation; deploy scripts run grub-install
    # manually against the current DEVICE.
    boot.loader.grub.enable = true;
    boot.loader.grub.device = lib.mkForce "nodev";
    boot.loader.grub.fsIdentifier = lib.mkForce "label";

    # Keep ~20 generations: ~60 MB each, fits comfortably in 1 GiB /boot.
    boot.loader.grub.configurationLimit = 20;

    # Recovery time at boot — pick generation, drop to grub prompt if
    # something is wrong. Base yoga config sets this to 1; override.
    boot.loader.timeout = lib.mkForce 10;

    # SD-card write reduction. /tmp goes to RAM+zram instead of flash;
    # fstrim lets the SD controller reclaim erased blocks (if supported).
    boot.tmp.useTmpfs = true;
    boot.tmp.tmpfsSize = "50%";
    services.fstrim.enable = true;

    # Keep persistent logs for debugging, but cap churn lower than the
    # base yoga profile (200M). Full volatile journald would reduce
    # writes further but would also erase useful crash/freeze evidence.
    services.journald.extraConfig = lib.mkForce ''
      SystemMaxUse=100M
      SystemMaxFileSize=10M
    '';

    # Cross-SD LUKS keyfile. Same content across every yoga-sd and
    # underyoga; lives in slot 1 of every LUKS container in the
    # fleet. agenix-decrypted at activation time so it's available
    # post-boot for `cryptsetup open --key-file` of sibling SDs and
    # of underyoga. Initrd does NOT use this keyfile (initrd opens
    # the booting SD's container via slot 0, the typed password).
    age.secrets.cross-sd-key = {
      file = ../secrets/cross-sd-key.age;
      mode = "0400";
      owner = "root";
    };
  };
}
