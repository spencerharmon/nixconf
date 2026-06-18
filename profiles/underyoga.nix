# underyoga profile.
#
# Minimal NixOS lives on the internal eMMC. Three roles:
#
# 1. eMMC-resident grub entry point. Its grub.cfg includes a
#    dispatcher menuentry that searches for an SD with the shared
#    "yoga-sd-boot" label and chains into that SD's grub.cfg
#    (configfile, not chainloader; legacy BIOS grub can source a
#    sibling grub.cfg into the running session). This is how SD-based
#    yoga-sd-N installs boot at all on yoga from the SeaBIOS boot
#    order: SeaBIOS picks the eMMC, underyoga's grub takes over,
#    the dispatcher resolves the SD label, the SD's grub.cfg shows
#    its own generations.
#
# 2. Recovery shell. Bootable on its own when no SD is inserted.
#    Has wifi (wpa_supplicant + agenix-wifi-yoga.age) + sshd + a
#    minimal set of disk-recovery tools (cryptsetup, parted,
#    e2fsprogs, rsync, git, tmux).
#
# 3. Cross-SD mount target. Other yoga-sd's can post-boot mount
#    /underyoga from this eMMC via the slot-1 cross-sd-key (so you
#    can rebuild underyoga while booted into yoga-sd-N).
#
# Layout on /dev/mmcblk1:
#   p1  /boot, ext4, label=underyoga-boot, ~512 MiB, boot flag set
#       UNENCRYPTED. grub stage2 + kernels. legacy-BIOS grub can't
#       read LUKS2 with argon2id, so /boot must be cleartext.
#   p2  LUKS2 container, rest (~14 GB)
#       └─ ext4 inside, label=underyoga-root. /nix, /var, /home, /root.
#
# MBR (not GPT) partition table: no separate bios_grub partition
# needed; grub stage1.5 lands in the post-MBR sector gap. Matches
# the SD-card layout for symmetry.
#
# SSH host identity: the canonical agenix-encrypted yoga host key
# (secrets/yoga-host-key.age). Same key as every yoga-sd. Means
# every wifi-yoga.age and cross-sd-key.age secret is decryptable on
# underyoga with zero extra agenix wiring. Hostname differs
# (underyoga vs yoga) so ssh known_hosts can disambiguate.
#
# Per-card module MUST set:
#   config.underyoga = {
#     bootPartUuid = "<mmcblk1p2 partuuid>";
#     luksPartUuid = "<mmcblk1p3 partuuid>";
#     installDevice = "/dev/mmcblk1";  # install-time path on installer
#   };
{ config, lib, pkgs, ... }:
let
  uy = config.underyoga or (throw
    "underyoga profile: per-card module must set config.underyoga { bootPartUuid, luksPartUuid, installDevice }");
in {
  options.underyoga = lib.mkOption {
    type = lib.types.submodule {
      options = {
        bootPartUuid = lib.mkOption {
          type = lib.types.str;
          description = "PARTUUID of the /boot partition on eMMC.";
        };
        luksPartUuid = lib.mkOption {
          type = lib.types.str;
          description = "PARTUUID of the LUKS container partition on eMMC.";
        };
        installDevice = lib.mkOption {
          type = lib.types.str;
          description =
            "Block device path of the eMMC on the INSTALLING host. Yoga's eMMC is /dev/mmcblk1.";
        };
        luksMapperName = lib.mkOption {
          type = lib.types.str;
          default = "underyoga-root";
          description = "dm-crypt mapper name for the unlocked root.";
        };
        rootLabel = lib.mkOption {
          type = lib.types.str;
          default = "underyoga-root";
          description = "ext4 label of the unlocked root.";
        };
      };
    };
    description = "Per-eMMC identity (PARTUUIDs) supplied by the system module.";
  };

  config = {
    # Distinct hostname so SSH known_hosts and login prompts make
    # clear which system is which. Reuses the canonical "yoga" SSH
    # host key (placed at install time, agenix-recoverable).
    networking.hostName = lib.mkForce "underyoga";
    # Controls GRUB menu labels ("underyoga" instead of "NixOS")
    # and early-boot/stage-1 banner text. boot.loader.grub.configurationName
    # alone only writes /run/current-system/configuration-name; the
    # GRUB generator uses system.nixos.distroName for menuentry names.
    system.nixos.distroName = lib.mkForce "underyoga";

    # sshd is essential for the recovery-shell role -- if the console
    # is unreachable for any reason (display dead, keyboard dead),
    # network access is the only way in. Also: agenix derives its
    # identity paths from openssh's host-key paths, so enabling sshd
    # satisfies age.identityPaths automatically.
    services.openssh.enable = true;

    # /boot on the eMMC, ext4, unencrypted.
    fileSystems."/boot" = lib.mkForce {
      device = "/dev/disk/by-partuuid/${uy.bootPartUuid}";
      fsType = "ext4";
    };

    # / inside the LUKS container. by-label since the unlocked
    # mapper name is unique to underyoga.
    fileSystems."/" = lib.mkForce {
      device = "/dev/disk/by-label/${uy.rootLabel}";
      fsType = "ext4";
    };

    # No swap. eMMC wear; not needed for a recovery shell.
    swapDevices = lib.mkForce [ ];

    # Initrd unlocks LUKS via password prompt (slot 0). Slot 1's
    # keyfile is for post-boot cross-mounts FROM other systems INTO
    # underyoga (when a yoga-sd wants to mount /underyoga), not used
    # by underyoga's own initrd.
    boot.initrd.luks.devices.${uy.luksMapperName} = {
      device = "/dev/disk/by-partuuid/${uy.luksPartUuid}";
      preLVM = true;
      allowDiscards = true;
    };

    # Initrd modules needed to enumerate eMMC + decrypt LUKS.
    # systems/yoga/hardware-configuration.nix already has the mmc
    # modules; this is defensive.
    boot.initrd.availableKernelModules = lib.mkAfter [
      "sdhci_acpi" "mmc_block"
      "dm_crypt" "aes" "xts" "sha256" "sha512"
    ];

    # Scripted initrd, not systemd-initrd, on the same reasoning as
    # profiles/yoga-sd.nix: systemd-cryptsetup's prompt UX black-
    # screens on yoga's Braswell IGP because the password prompt
    # writes to a tty that isn't renderable yet. Scripted initrd
    # uses the always-available VGA text console.
    boot.initrd.systemd.enable = lib.mkForce false;

    # GRUB on legacy BIOS, installed to the eMMC MBR. Name the
    # autogenerated NixOS entries "underyoga" instead of generic
    # "NixOS" so the fallback/recovery entry is obvious in the menu.
    boot.loader.grub.enable = true;
    boot.loader.grub.device = lib.mkForce uy.installDevice;
    boot.loader.grub.fsIdentifier = lib.mkForce "label";
    boot.loader.grub.configurationName = "underyoga";
    boot.loader.grub.configurationLimit = 20;

    # The base yoga config uses console=tty1. On underyoga that left
    # the initrd LUKS prompt invisible: the system accepted the typed
    # password and booted, but the screen was black until later in
    # boot. tty0 follows the active virtual console and works with
    # early VGA/fb console handoff.
    boot.kernelParams = lib.mkForce [ "console=tty0" ];

    # Load i915 in initrd so the panel is modeset before the scripted
    # initrd prompts for the LUKS passphrase. Without this, Braswell
    # leaves the display black during the unlock prompt even though
    # keyboard input is accepted.
    boot.initrd.kernelModules = lib.mkAfter [ "i915" ];

    # Dispatcher menuentry: search for a yoga-sd-boot partition on
    # any attached drive. If present, source its grub.cfg into this
    # grub session, which then presents the SD's own generations
    # menu. If absent (no SD inserted), this entry's "configfile"
    # errors out and the user arrows down to pick underyoga itself.
    #
    # extraEntriesBeforeNixOS = true puts this above NixOS's own
    # autogenerated underyoga generation entries, so it's the default.
    boot.loader.grub.extraEntriesBeforeNixOS = true;
    boot.loader.grub.extraEntries = ''
      menuentry "Boot SD card (yoga-sd-*)" {
        insmod part_msdos
        insmod ext2
        search --no-floppy --label yoga-sd-boot --set=root
        configfile ($root)/grub/grub.cfg
      }
    '';

    # Longer timeout — this is a menu the user actively interacts
    # with (pick SD or pick underyoga), not a fast path.
    boot.loader.timeout = lib.mkForce 10;

    # Cross-SD keyfile available post-boot for opening sibling
    # yoga-sd's. agenix-decrypted from cross-sd-key.age using the
    # shared yoga host key.
    age.secrets.cross-sd-key = {
      file = ../secrets/cross-sd-key.age;
      mode = "0400";
      owner = "root";
    };

    # Recovery toolset. Keep this list tight — every package eats
    # eMMC space, which is the whole reason underyoga exists.
    environment.systemPackages = with pkgs; [
      # Disk recovery
      cryptsetup
      parted
      e2fsprogs
      dosfstools
      gptfdisk
      util-linux
      # Data movement
      rsync
      zstd
      git
      # Session continuity over flaky network
      tmux
      # Text editing
      vim
      # Network diagnostics (sshd, ping, ip already in base)
      iproute2
      iputils
      # Useful for inspecting old journals from rescued data
      systemd  # journalctl is in here, also already in base
    ];

    # Recovery shell is intentionally minimal: no desktop, no X,
    # no display-manager. Console-only. Boots fast even on slow eMMC.
    # systems/yoga/configuration.nix enables xserver as a side effect
    # of being the canonical yoga hardware config; override here so
    # underyoga doesn't pull X/lightdm/EXWM/firefox into its closure.
    services.xserver.enable = lib.mkForce false;
  };
}
