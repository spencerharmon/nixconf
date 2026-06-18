# yoga storage redesign: encrypted SD-card root, eMMC underyoga

## Status

Implemented. Current Yoga state:

- `underyoga` lives on internal eMMC (`/dev/mmcblk1`): encrypted
  minimal recovery/dispatcher system, no desktop.
- `yoga-sd-0` lives on the internal SD card (`/dev/mmcblk0` when
  booted on Yoga): encrypted full workstation, hostname `yoga`.
- `underyoga` GRUB default entry searches for the shared
  `yoga-sd-boot` label and `configfile`s into the inserted SD's
  own GRUB config.
- Old transitional targets (`yoga`, `yoga-sd-0-plain`,
  `yoga-on-sda`) have been removed from `flake.nix`.

## Motivation

Yoga's 15 GB internal eMMC drives every storage decision in the
repo:

- `docs/yoga.md` C-6: the nixpkgs 22.11 → 26.05 jump did not fit.
  Required a "shrink hop" via `profiles/yoga-minimal.nix` to free
  enough space mid-upgrade.
- `AGENTS.md` "Yoga gotchas": every major nixpkgs version rebase
  has the same dance baked into the workflow.
- All `nix.gc.automatic` / `auto-optimise-store` / `min-free` /
  `max-free` tuning in `profiles/common.nix` exists to keep the
  eMMC from filling.
- An entire scratch-USB workflow in `AGENTS.md` ("External USB as
  scratch store for big builds") exists because individual builds
  don't fit on internal storage.

Moving the Nix store off the eMMC lifts all of that. With the store
on a 256 GB SD card, full desktop closures, multiple generations,
and large transient builds become routine.

Encryption is a baseline requirement for any persistent data on a
laptop that leaves the house.

## Layout

```
/dev/mmcblk1  internal eMMC, 15 GB  (underyoga)
├─ p1  /boot, ext4, label=underyoga-boot, ~512 MiB, boot flag
│      UNENCRYPTED. grub stage2 + kernels + initrds for
│      underyoga's own generations.
└─ p2  LUKS2 container, rest (~14 GiB)
       └─ ext4 inside, label=underyoga-root
          Minimal NixOS: sshd, wpa_supplicant, cryptsetup, parted,
          tmux, vim, git. No desktop. grub.cfg has a static
          dispatcher menuentry that searches for the shared
          yoga-sd-boot label and chains to whichever SD is
          inserted.

MBR (not GPT) on the eMMC: no separate bios_grub partition needed;
grub stage1.5 lands in the post-MBR sector gap. Matches the SD-card
layout for symmetry.

/dev/<sd-card>  removable, 256 GB+, MBR (msdos) partition table
├─ p1  /boot, ext4, label=yoga-sd-boot, ~1 GiB, boot flag set
│      UNENCRYPTED. Holds grub stage2 cfg + kernels + initrds.
│      SAME label on every SD -- one SD inserted at a time, by user
│      discipline. Boot-time discovery in underyoga's grub uses this
│      label.
└─ p2  LUKS2 container, rest of device
       PARTUUID = unique per SD (by parted construction)
       └─ ext4 inside, label=yoga-sd-<n>-root (unique per SD)
          Mounted at `/`. /nix, /var, /home, /etc, /root.
```

**Why MBR on both eMMC and SD**: MBR's post-MBR sector gap holds
GRUB stage1.5, so no separate `bios_grub` partition is needed.
This keeps both eMMC and SD layouts symmetric and simple for
legacy-BIOS SeaBIOS booting. The SD is also self-contained:
SeaBIOS → SD MBR → SD grub → SD kernel works even without eMMC,
though normal Yoga boot uses eMMC's underyoga dispatcher first.

**Why same `/boot` label across all SDs**: enables a single static
grub-dispatcher entry on underyoga (`search --label yoga-sd-boot
--set=root; configfile ($root)/grub/grub.cfg`) that resolves to
whichever SD is currently inserted. No per-SD grub edits on
underyoga. Cost: only one SD may be inserted at boot time.

**Why per-SD root label + per-SD PARTUUIDs**: inside each SD's
running system, every fileSystems / luks reference is by-partuuid
or per-SD label, so mounting a *second* SD post-boot (data
migration) is unambiguous.

## Boot sequence (standalone SD, no underyoga)

1. SeaBIOS POST.
2. SeaBIOS reads the SD's MBR, executes GRUB stage1.
3. stage1 loads stage1.5 from the post-MBR gap on the SD.
4. stage1.5 reads `/boot/grub/grub.cfg` from the SD's p1 via GRUB's
   own ext4 driver.
5. User picks a generation. GRUB loads kernel + initrd from
   `/boot/kernels/` on the SD's p1.
6. Kernel boots; scripted initrd takes over. `profiles/yoga-sd.nix`
   forces `boot.initrd.systemd.enable = false` because systemd-initrd
   accepted LUKS input but rendered a black screen on Braswell.
7. initrd loads SD modules (`sdhci_acpi`, `mmc_block`,
   `usb_storage`/`uas`), `i915` for early panel modeset, and LUKS
   modules (`dm_crypt`, `aes`, `xts`, `sha256`, `sha512`).
8. initrd prompts on `tty0` for the LUKS passphrase, opens the SD
   container (PARTUUID-pinned, so the *correct* container is opened
   even if multiple SDs are inserted), mounts the ext4 inside at
   `/sysroot`.
9. Pivot. systemd in the real root takes over.

## Boot sequence (via underyoga)

1-3. SeaBIOS → eMMC → grub stage1 → stage1.5 in the post-MBR sector
   gap → stage2 reads underyoga's `/boot/grub/grub.cfg` from
   the cleartext ext4 boot partition (p1).
4. underyoga's grub.cfg has a static dispatcher entry:
   `search --no-floppy --label yoga-sd-boot --set=root; configfile ($root)/grub/grub.cfg`.
   It's listed first via `boot.loader.grub.extraEntriesBeforeNixOS`.
5. With an SD inserted: search resolves to the SD's `/boot`, configfile
   sources the SD's grub.cfg into the running grub session, the SD's
   generations menu appears. Pick one. Kernel + initrd loaded from
   the SD. Initrd unlocks the SD's LUKS root with the user-typed
   password. Continue boot into yoga-sd-N.
6. With no SD inserted: search fails. The dispatcher's configfile
   line errors out. User arrow-downs to the underyoga generations
   menu and selects underyoga. Kernel + initrd loaded from eMMC's
   `/boot`. Initrd unlocks underyoga's LUKS root with the user-typed
   password. Continue boot into the underyoga recovery shell.

## Why `/boot` unencrypted

GRUB on legacy BIOS reads LUKS1 containers with the right modules
loaded, but **not LUKS2 with argon2id** (upstream GRUB has only
limited LUKS2 support as of nixpkgs 26.05; argon2id specifically
is unsupported). LUKS1 is deprecated and forces a weaker KDF
(PBKDF2). Leaving `/boot` cleartext is the standard pattern.

Threat-model cost: a one-time physical-access attacker can replace
the kernel / initrd / grub binaries on the cleartext `/boot` and
either log the LUKS passphrase or backdoor the system. Mitigation
is Secure Boot + signed initrd, which yoga's BIOS firmware does
not support. The LUKS root still protects against the realistic
threats (disk lost, laptop stolen powered-off, opportunistic
snooping by anyone who gets just the SD card).

## Multi-SD cross-mount: dual-key LUKS

Each SD's LUKS container has two keyslots:

- **Slot 0**: password-protected. Used by initrd at boot to unlock
  the *currently-booting* SD's root.
- **Slot 1**: keyfile-protected. Keyfile lives at
  `/etc/keys/cross-sd.key` on each SD's mounted root, agenix-backed
  for disaster recovery. Used post-boot to unlock *other* LUKS
  containers (a second SD, underyoga) without re-prompting.

User types the LUKS password exactly once per boot. Mounting
`/underyoga` after boot, or mounting yoga-sd-1's data from a
running yoga-sd-0, both use slot 1 transparently via cryptsetup
`--key-file`.

Slot 1 setup after `luksFormat`:

```
sudo dd if=/dev/urandom of=/etc/keys/cross-sd.key bs=64 count=1
sudo chmod 0400 /etc/keys/cross-sd.key
sudo cryptsetup luksAddKey --key-slot 1 \
    /dev/<sd>2 /etc/keys/cross-sd.key
```

The cross-SD keyfile is one shared secret across the whole yoga-SD
fleet plus underyoga. Compromise of the keyfile compromises every
container — acceptable because the attacker also needs physical
possession of the SD, at which point slot 0's password is the real
defence and slot 1 is convenience.

## Why no unencrypted scratch first?

Considered: install an unencrypted yoga onto the SD first as a
recovery / staging system, then re-install the encrypted final
layout on top.

Rejected because:

- The scratch install would have to be **reformatted away** before
  the final install (different partition table, /boot label
  conflict, LUKS container needs to occupy what was the scratch
  root). It's not a true stepping-stone; it's parallel work.
- LUKS failure modes on yoga's hardware are bounded:
  - Initrd module list: auto-pulled by NixOS when
    `boot.initrd.luks.devices` is declared. Not a manual concern.
  - Passphrase prompt UX: handled by systemd-initrd, well-trodden
    code path.
  - Argon2id tuning: `cryptsetup benchmark` post-first-boot
    validates throughput; if unlock is too slow, lower
    `--iter-time` on a re-key.
  - SD readiness vs. cryptsetup timeout: configurable in
    `boot.initrd.luks.devices.<n>.preLVM` ordering plus systemd
    device wait.
- Recovery channel if the encrypted install fails to boot: a NixOS
  installer USB. SeaBIOS POST sees USB at boot time. (Yoga's
  earlier failure to see USB was at the *eMMC-grub prompt*, which
  is a grub-module-missing issue — different code path from
  SeaBIOS USB enumeration.)

If the encrypted install boots on first try, an install cycle is
saved. If it fails, the recovery options are the same as they would
have been after a scratch install (mount the SD from elsewhere,
inspect, fix, retry).

## Other implications (not blockers)

- **`/var/log/journal` is on the SD.** Pulling the SD on a frozen
  system means losing the most recent logs. See `docs/yoga.md` F-1
  — the freeze-without-trace bug is harder to diagnose when logs
  live on a removable device. Mitigation: enable `pstore`/`ramoops`
  per `docs/yoga.md` I-1 so kernel panics survive across reboots
  in RAM-backed storage rather than on the SD.
- **Shared Yoga host identity.** All Yoga-family systems share the
  agenix-managed `root@yoga` SSH host key (`yoga-host-key.age`) and
  hostname `yoga` for SD workstation systems. This lets `wifi-yoga.age`,
  `cross-sd-key.age`, and `spencer-password-hash.age` decrypt across
  Yoga SDs and underyoga without per-SD secret re-encryption. Tradeoff:
  compromising one Yoga SD compromises the shared Yoga host identity.
- **Per-SD `/home`.** Switching SDs switches the home directory. If
  shared `/home` across SDs becomes desirable later, that's a
  separate, additional partition (likely on underyoga, mounted from
  each SD post-boot using the slot-1 cross-key).
- **AES-NI on N3150.** `cryptsetup benchmark` should be run on yoga
  first thing after first boot to confirm throughput is acceptable.
  Braswell has AES-NI; expected throughput is in the hundreds of
  MB/s, well above SD-card sequential I/O, so the cipher is not the
  bottleneck.

## Migration steps for the next SD (yoga-sd-1, etc.)

1. Partition the new SD identically to `systems/yoga-sd-0/`
   instructions (same boot label, new root label, new PARTUUIDs).
2. Create `systems/yoga-sd-N/configuration.nix` with the new
   PARTUUIDs + label. Do **not** add `/dev/sdX`; `profiles/yoga-sd.nix`
   uses `boot.loader.grub.device = "nodev"` so closures are
   device-independent.
3. Add a `yoga-sd-N` target to `flake.nix` that imports
   `profiles/yoga-sd.nix` + the per-card module.
4. Format LUKS, add the shared `cross-sd-key.age` keyfile to slot 1,
   mount at `/mnt`, and drop the shared `yoga-host-key.age` private
   key into `/mnt/etc/ssh/ssh_host_ed25519_key` before activation.
5. `nixos-install --root /mnt --flake .#yoga-sd-N` generates grub.cfg
   and kernels. Because GRUB device is `nodev`, run
   `grub-install --target=i386-pc --boot-directory=/mnt/boot /dev/<current-sd-disk>`
   once from the provisioning host.
6. Boot through underyoga dispatcher, verify LUKS prompt + root rw,
   restore data if desired.

No underyoga rebuild is needed — the dispatcher entry is label-
driven and finds the new SD automatically.
