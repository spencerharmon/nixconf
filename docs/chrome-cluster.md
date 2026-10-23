# chrome cluster — hardware & firmware

The `chrome1`–`chrome3` hosts: three identical, headless (no console) mini PCs
running an HA k3s cluster. Deployment-specific facts (addresses, DNS names, GitOps
repo) live in the private infrastructure repos, not here.

## Hardware (per node)

| | |
|---|---|
| Model | HP Chromebox CB1 — board **"Zako"**, family `Google_Beltino` |
| CPU | Intel **Celeron 2955U**, Haswell-ULT, 2 cores / 2 threads, **1.4 GHz fixed** (no turbo), 2 MiB L3, 15 W |
| Chipset | Intel 8 Series (Lynx Point-LP), on-package |
| RAM | **one** DDR3L SO-DIMM slot (second slot is unpopulated solder pads) → **8 GB max**. Use DDR3L 1.35 V, 1600/1333 MT/s. Firmware reports a bogus "3200 MT/s". |
| Storage | **M.2 2242 SATA** (B+M key). Not NVMe, not 2280. Factory: 16 GB LITEON; now 128 GB. NVMe-only USB enclosures (e.g. JMicron JMS583) can't read these drives. |
| NIC | Realtek RTL8111/8168 gigabit (`enp1s0`, `r8169`) |
| Unused | Atheros AR9462 Wi-Fi/BT, HD audio (blacklisted, see `profiles/chrome-performance.nix`) |

### CPU feature limits — check every workload against these

Has: SSE4.2, SSSE3, POPCNT, MOVBE, PCLMULQDQ, RDRAND, VT-x + EPT, PCID/INVPCID.
**Lacks: AVX, AVX2, FMA, BMI1/2, F16C, AES-NI, TSX, Hyper-Threading.**
→ x86-64-v2 only. Anything built for x86-64-v3 or requiring AVX dies with SIGILL
(MongoDB >= 5, RHEL/Alma 10 based images, Bun, many ML/vector libraries).
No AES-NI: AES is slow in software — Go TLS between Go peers picks ChaCha20 (fine);
avoid AES disk encryption (use Adiantum if ever needed).

## Firmware

**MrChromebox UEFI Full ROM** (coreboot 4.16 + edk2) replaces ChromeOS firmware on all
three. UEFI only, no Secure Boot, NVRAM is writable from Linux (`efibootmgr` works;
NixOS registers its own "Linux Boot Manager" entry via `canTouchEfiVariables`).

Boot-order conventions (set with `efibootmgr -o`):

```
Linux Boot Manager (internal SSD) , SATA: <ssd> (auto) , chrome-usb , USB: <stick> (auto) , UEFI Shell , UiApp
```

**Quirk — the reason for the order:** when the FIRST boot entry fails (e.g. its ESP
left with a swapped-out disk) MrChromebox does **not** fall through; it stops at
`Booting ... failed ... Press any key to continue`, which needs a keyboard. `UiApp`
(firmware setup) must always be last, or a failed boot lands in an interactive menu.

## Headless (re)install: the `chrome-usb` stick

`installers/chrome-usb.nix` → `nix build .#chrome-usb-image` → `dd` the raw image to a
USB stick (sequential write; file-by-file installs onto cheap USB 2.0 sticks crawl at
~170 KiB/s). It is a normal installed NixOS (systemd-boot, ext4, dhcpcd, sshd with the
admin key, persistent journal on the stick for post-mortems), NOT a live ISO — the live
ISO hung on this hardware with no way to see why.

Drive-swap / reinstall procedure (no console, verified on all three nodes):

1. With the stick plugged in, on the running host: back up the identity
   (`/etc/ssh/ssh_host_*`, `/etc/machine-id` — the ed25519 host key is the agenix
   recipient), then register the stick and put it **first**:
   `efibootmgr -C -d /dev/sdX -p 1 -L chrome-usb -l '\EFI\BOOT\BOOTX64.EFI'` and
   `efibootmgr -o <chrome-usb>,<rest…>,<UiApp last>`. Reboot once to prove it boots
   from the normal order, then power off from the stick system.
2. Swap the drive, power on: the firmware boots the stick (DHCP keeps the node's
   address — same NIC MAC).
3. Over SSH as root on the stick: partition GPT `NIXBOOT` (512 MiB vfat) + `NIXROOT`
   (rest, xfs) — matches `systems/chromeN/hardware-configuration.nix`; mount at `/mnt`;
   restore the identity into `/mnt/etc`.
4. From the build host, copy the system closure **straight into the target store**
   (bypasses the slow stick):
   `nix copy --to 'ssh-ng://root@<node>?remote-store=local%3Froot%3D%2Fmnt' <toplevel>`,
   then on the stick `nixos-install --root /mnt --system <toplevel> --no-root-passwd --no-channel-copy`.
5. Delete the stale "Linux Boot Manager" entry (old disk), order the new one first,
   stick after it, `UiApp` last; reboot. agenix decrypts on first boot because the host
   key was restored.

## NixOS configuration map

- `flake.nix`: chrome hosts use their own `nixpkgs-chrome` input (stable release
  branch) so the Yoga pin is independent.
- `profiles/k3s/`: every node a k3s server; one `server-init.nix` (`--cluster-init`),
  the rest `server-join.nix`. Token/join URL in agenix env files. `--node-ip` is derived
  at start from the IPv4 default route (auto-detection flipped to IPv6 once and broke
  etcd membership). Public DNS resolvers: the LAN router rebind-filters answers that
  point at private addresses.
- `profiles/chrome-performance.nix`: `mitigations=off` (single-tenant; no untrusted
  code), no lockup watchdogs, `performance` governor, zstd zram swap (kubelet
  `fail-swap-on=false`), unused Wi-Fi/BT/audio modules blacklisted.
- `profiles/cloudflare-ddns.nix`: per-host `<hostname>.<zone>` A record = LAN IPv4.
- `secrets/secrets.nix`: chrome host keys (`chromeAll`, `chromeJoiners`); adding a node
  = add its key + rekey before deploying.

## Operational notes

- Deploy: `nix run github:serokell/deploy-rs -- .#chromeN --hostname <ip>` (the
  `deploy.nodes` hostnames don't resolve everywhere).
- etcd needs 2 of 3 nodes: take at most one node down at a time; a joining node also
  needs quorum.
- Big NixOS jumps (e.g. 22.11 → 26.05) leave the old `systemd-logind` running, so
  `switch` fails user activation until reboot — use `switch-to-configuration boot` plus a
  one-shot `bootctl set-oneshot` reboot instead.
