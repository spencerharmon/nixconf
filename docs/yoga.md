# yoga

Lenovo Yoga laptop. Primary use: emacs + EXWM workstation, ssh into other hosts for heavier work.

## Hardware

| | |
|---|---|
| CPU | Intel Celeron N3150 (Braswell, 2015) — 4 threads @ 1.6 GHz |
| ISA features | SSE4.2, AES-NI. **No AVX, no AVX2, no AVX512.** |
| Storage | 15 GB eMMC (`/dev/mmcblk1`) = encrypted `underyoga` recovery/dispatcher. Internal SD (`/dev/mmcblk0` when booted on Yoga) = encrypted `yoga-sd-0` workstation root. |
| Display | 1366×768 Intel HD (Braswell IGP) |
| Wifi | `wlp2s0` (Realtek) |
| Boot | Legacy BIOS + GRUB. Normal path: eMMC GRUB (`underyoga`) → `search --label yoga-sd-boot` → SD GRUB (`yoga-sd-0`). |

## Current software/storage state (2026-06-17)

- Active workstation: `yoga-sd-0`, encrypted LUKS root on internal SD, hostname `yoga`.
- Recovery/dispatcher: `underyoga`, encrypted LUKS root on eMMC, hostname `underyoga`.
- Flake targets: `underyoga` and `yoga-sd-0` only. Removed transitional `yoga`, `yoga-sd-0-plain`, and `yoga-on-sda` targets.
- Boot flow: SeaBIOS → eMMC GRUB (`underyoga`) → first menuentry searches label `yoga-sd-boot` and `configfile`s into SD GRUB → boot `yoga-sd-0`.
- `yoga-sd-0` has `boot.loader.grub.device = "nodev"`; normal rebuilds update `/boot/grub/grub.cfg` and kernels, while provisioning scripts run one-time `grub-install` against the current installer-visible device.
- SD root health policy: zram, no disk swap, `/tmp` tmpfs, root ext4 `noatime,commit=60`, `/boot` `noatime`, weekly fstrim, journald capped at 100M.

Operational implications:
- **No AVX2** → Bun-based tools (`pkgs.opencode`, `pkgs.bun`) SIGILL on first JIT.
- **15 GB eMMC is no longer the desktop root** → full workstation lives on SD, so the old shrink-hop dance is retired for normal Yoga work. eMMC now only needs the small `underyoga` closure.
- **Slow CPU + flash storage** → emacs cold-start with our `.emacs` is 5–15s; full local rebuilds are 10–30 min wall-clock.
- **Slow IGP wake** → DPMS unblanking the panel takes several seconds; can be mistaken for a hang.

## Known issues

### Open

#### F-1: kernel/userspace freeze, power-button-unresponsive (severity: high)
- **Symptoms**: System becomes completely unresponsive. SSH banner-exchange timeout. Console unresponsive. **Power button does not initiate shutdown** (had to hold to force-off).
- **Observed**: once, ~2026-05-23 mid-day, during/after a multi-hour idle period that included a nixos-rebuild attempt. Conversation context (see git history around commit `ace147e`).
- **Diagnostics available**: none. The persistent journal across the boot shows no panic, no OOM, no shutdown — just abrupt absence of log entries followed by a normal-looking boot at next power-on.
- **Root cause**: unknown. Candidates:
  - Kernel hang (no oops captured because no crash-logging mechanism is configured).
  - Hardware thermal trip (no thermal logging enabled).
  - eMMC controller hang (Braswell + cheap eMMC is known-flaky in some configurations).
  - Suspend/resume bug interacting with X DPMS.
- **Workaround**: none currently. If it recurs, force-off and reboot.
- **Fix prerequisite**: see I-1 (enable crash logging) before it recurs.

#### F-2: SSH banner-exchange timeout during heavy CPU load (severity: low)
- **Symptoms**: `ssh: Connection timed out during banner exchange` while `nixos-rebuild` is running locally. TCP connects, but no banner sent.
- **Cause**: sshd starved of CPU during single-threaded eval / large copy phases on N3150.
- **Workaround**: run long commands with `nohup … &` so they survive client-side timeout. Documented in `AGENTS.md`.
- **Status**: cosmetic — not actually breaking anything.

#### F-3: Panel blanks via DPMS, won't wake from input events (severity: medium)
- **Symptoms**: After 10 min idle, panel goes black. Mouse/keyboard input does NOT wake it. System is otherwise fully responsive (SSH works, processes run, X reports `Monitor is On` and `DPMS Enabled`).
- **Cause**: i915 driver on Braswell appears to issue the DPMS-on signal but the panel doesn't physically respond to it. Backlight reports full brightness, DRM connector reports enabled+connected+On. The panel is in a state the driver can't kick out of via the normal modeset.
- **Recovery from SSH** (confirmed working 2026-05-23): `sudo DISPLAY=:0 XAUTHORITY=/run/lightdm/root/:0 xset dpms force off && sleep 2 && sudo DISPLAY=:0 XAUTHORITY=/run/lightdm/root/:0 xset dpms force on`. Panel wakes within ~1 second.
- **Open question**: whether F-3 and F-1 are related. F-1 was total system unresponsiveness (no SSH, no power button). F-3 is panel-only with system fully responsive. Different bugs, possibly correlated cause (both potentially i915 / power-management interactions).
- **Fix**: disable X DPMS entirely — never blank the screen. Cost: power usage and burn-in (minimal on LCD). Set in `profiles/laptop.nix`:
  ```nix
  services.xserver.serverFlagsSection = ''
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
  '';
  ```
  Pending application — see I-4.

#### F-4: SD-card I/O errors after heavy writes / seating issue (severity: high)
- **Symptoms**: `I/O error, dev mmcblk0`, ext4 journal abort on `dm-0`, root remounted `emergency_ro` / read-only.
- **Observed**: during first encrypted `yoga-sd-0` bring-up after heavy install/restore writes. Reseating the SD and fsck from `underyoga` produced clean second-pass fsck and no new current-boot I/O errors.
- **Root cause**: likely marginal SD seating/contact or SD-reader/card path under sustained writes. Card is high-endurance, but rootfs workloads stress random writes and metadata.
- **Mitigations applied**: zram swap, no disk swap, `/tmp` tmpfs, `/` `noatime,commit=60`, `/boot` `noatime`, weekly fstrim, journald cap 100M. If I/O errors recur, stop writing, boot `underyoga`, fsck SD, and consider replacing card or abandoning SD-as-root.
- **Write throttling (`profiles/yoga-sd-io-throttle.nix`, 2026-07-24)**: the corruption trigger is *sustained write bursts*, not build scratch (build scratch already lives in tmpfs `/tmp` and never touches the SD). Measured card sustained write = **26 MB/s** (`dd 256 MiB oflag=direct`). Stock `vm.dirty_ratio=20` on 3.8 GiB RAM let ~760 MB of dirty pages accumulate, then dump as a ~30 s avalanche at the card ceiling. Two-layer fix: (1) global `vm.dirty_bytes=48 MiB` / `dirty_background_bytes=16 MiB` so writeback is a steady trickle of small flushes -- the only lever that also bounds the un-cgroupable ext4 journal (`jbd2/dm-0`) and root-cgroup writeback kworkers; (2) `IOWriteBandwidthMax=/dev/mmcblk0 13M` (half the sustained rate) on **both** `system.slice` and `user.slice` (the kernel rejects `io.max` at the cgroup root, so there is no single system-wide knob). Not a guarantee -- a hardware layer dropping an accepted write can't be prevented in software -- but keeps every burst small and slow; `metadata_csum` still detects anything that slips through. Re-benchmark and adjust `writeBpsMax` if the card is replaced.
- **Deferred idea — underyoga eMMC as build scratch (Mode A chroot store)**: NOT implemented; scratch relocation solves a problem yoga doesn't have (builds already unpack into tmpfs `/tmp`, 1.9 GiB, off-SD). Kept here in case a single derivation's build tree ever exceeds tmpfs AND must be isolated from the SD. eMMC is more durable and internal; corrupting it is an accepted risk (fallbacks exist on both roots). Workflow, all facts verified 2026-07-24:
  - Container `/dev/mmcblk1p2` (PARTUUID `c71b60b7-02`), inner ext4 label `underyoga-root`, slot-1 keyfile `/run/agenix/cross-sd-key` (tested: opens). Mapper name `underyoga-scratch`, mountpoint `/underyoga` (both free).
  - **Mount**: `cryptsetup open --key-file /run/agenix/cross-sd-key /dev/mmcblk1p2 underyoga-scratch` → `mkdir -p /underyoga` → `mount /dev/mapper/underyoga-scratch /underyoga` → `mkdir -p /underyoga/nixscratch/{store,tmp}` → `df -h /underyoga` (check headroom first).
  - **Build (scratch+output both on eMMC)**: `sudo env TMPDIR=/underyoga/nixscratch/tmp nix build --store /underyoga/nixscratch/store <ref> --print-out-paths`. Note: setting `TMPDIR` in your shell alone does nothing — the `nix-daemon` runs the build with its own `TMPDIR`; the chroot `--store` is what actually redirects build IO off the SD.
  - **Bring result to SD (only unavoidable SD write, and it's throttled)**: `nix copy --no-check-sigs --from /underyoga/nixscratch/store --to /nix/store <out-path>`.
  - **Cleanup/unmount**: `rm -rf /underyoga/nixscratch` → `umount /underyoga` → `cryptsetup close underyoga-scratch`.
  - **Decision rule** for whether a rebuild even needs this: `nix build --dry-run .#nixosConfigurations.yoga-sd-0.config.system.build.toplevel 2>&1 | grep -iE 'will be built|will be fetched'`. All `unit-*` / `*-env` / `home-manager-*` / `activation` / system-drv entries = config-only, tmpfs handles it. A real compiler/big-source unpack (`*-gcc`, `linux-*`, `webkitgtk`, `*-chromium`, `*-rust*`) = candidate for Mode A. Dry-run shows *what* builds, not per-drv scratch size — judge heavy packages by name. The throttle above makes even a misjudged heavy build survivable on the SD, so the guess need not be perfect.
  - **Caveat**: do not run this while booted *into* underyoga.

### Closed

| | Issue | Fix |
|---|---|---|
| C-1 | `pkgs.opencode` SIGILL on N3150 | Replaced with `pkgs.claude-code` (embedded Node SEA, no AVX2). `profiles/coding-agents.nix`. |
| C-2 | `wpa_supplicant-wlp2s0` "EXT PW FILE: Permission denied" reading agenix secret | `age.secrets.wifi-yoga.group = "wpa_supplicant"; mode = "0440"`. `profiles/wifi-yoga.nix`. |
| C-3 | wpa_supplicant auto-detect mode flaky, `wpa_cli` couldn't connect | `networking.wireless.interfaces = [ "wlp2s0" ]` forces per-interface unit generation. |
| C-4 | wpa_supplicant started before agenix secret was decrypted | `systemd.services."wpa_supplicant-wlp2s0" = { after = [ "agenix.service" ]; wants = [ "agenix.service" ]; }`. |
| C-5 | IPv6 default route blackholes outbound IPv4 on the local network | `networking.enableIPv6 = false` in `systems/yoga/configuration.nix`. |
| C-6 | nixpkgs 22.11 → 26.05 upgrade exceeded 15 GB eMMC root | Solved by storage redesign: eMMC now runs small `underyoga`; full desktop root + Nix store live on encrypted SD (`yoga-sd-0`). |
| C-7 | Old user-key (RSA `spencer@home-one`) no longer accessible after key rotation | Replaced with ed25519 `spencer@spray` in `users.nix`. |
| C-8 | dhcpcd shutdown hangs ~30s sending DHCP RELEASE | `release no` + `TimeoutStopSec=5s`. `systems/yoga/configuration.nix`. |
| C-9 | `.emacs` crash on missing package killed EXWM session | Defensive `condition-case` wrappers + `(require '<pkg> nil 'noerror)`. EXWM block runs in its own `condition-case`. |
| C-10 | straight.el bootstrap requires network at every emacs start | Removed (no actual `straight-use-package` callers remained after gptel/copilot/opencode removal). |
| C-11 | LUKS prompt black-screened during encrypted-root boot | Forced scripted initrd, `console=tty0`, and `i915` in initrd for `underyoga` + `yoga-sd` profiles. Password prompt now visible on underyoga and expected on SD. |
| C-12 | (obsolete, caveman-code removed in C-16) Home Manager activation failed when caveman-code GitHub/npm unavailable | Made caveman-code activation best-effort/non-fatal so managed symlinks (`.emacs`, themes) still update. |
| C-13 | `slock` failed with `crypt: Invalid argument` | Added declarative yescrypt password hash via agenix (`profiles/spencer-password.nix`); `users.mutableUsers = false` on Yoga-family systems. |
| C-14 | wg0 tunnel had zero peers after boot; spray services on server LAN unreachable | Two causes. (a) Peer unit failed at boot with `Name or service not known: wireguard.polyfam.studio` — DNS not ready when the peer `wg set` ran. Fixed with `dynamicEndpointRefreshSeconds = 60` so the endpoint re-resolves and self-heals. (b) The profile excluded `192.168.1.0/24` from `allowedIPs` entirely (post-2026-07-13 brick), so even a live peer couldn't crypto-route spray. Re-added the LAN to `allowedIPs` and made the kernel route collision-safe: `allowedIPsAsRoutes = false` + a `postSetup` that installs `192.168.1.0/24 dev wg0` ONLY when yoga is not physically on `192.168.1.x`. `profiles/wireguard-yoga.nix`. |
| C-15 | Home-Manager activation re-ran `npm ci` (~670 MB write storm) every rebuild, the dominant F-4 `emergency_ro` trigger | The build stamp compares against `HEAD-dirty`, and the caveman-code checkout is permanently dirty (`models.generated.ts` regenerated), so the guard fired on every rebuild. `npm ci` wipes+reinstalls all of `node_modules`. Fix: reserve `npm ci` for a missing `node_modules`; otherwise incremental `npm install --prefer-offline`. Pre-writing the stamp defuses the pending run. `home/spencer.nix`. |
| C-16 | cavemacs + caveman-code (Bun-free but unpackaged, activation-time npm build) | Removed (flake input, overlay, activation clone, wrappers, `~/.cave`). Replaced by `pi-coding-agent` + `pi-acp` + emacs `agent-shell` (`profiles/ai-tools.nix`); skills now under `~/.pi/agent/skills`. |
| C-17 | wg0 never handshakes at home (sent handshakes, 0 received; key/peer were fine) | Home router has no NAT hairpin: endpoint resolves to the public IP. Verified by pointing the endpoint at the server LAN address, which handshook at once. wg0 is now started by `wg-yoga-guard.service` (route watcher) only off the home LAN (`profiles/wireguard-yoga.nix`). (A first attempt used a dhcpcd exit hook; it never worked because the dhcpcd unit is sandboxed, see C-19.) |
| C-18 | No way to get a network from an Android phone | `M-x android-tether` (adb `svc usb setFunctions rndis`), dhcpcd allows `enx*`/`enp*u*`/`usb*` (`profiles/android-tether.nix`). |
| C-19 | USB tether gave a lease but no internet (phone's DUN bearer is IPv6-only with stuck CLAT and forwards nothing); dhcpcd hooks could not start units | Route through a SOCKS5 app on the phone instead (Socks Tether, normal data path) with `tun2socks` on yoga: `phone-socks@<iface>.service`, started by a udev `SYSTEMD_WANTS` rule (match non-`remove` events: the usb0->enpNuM rename is a `move` that replaces the udev db entry). dhcpcd `nogateway` on USB NICs; fallback metric 4000 < wifi; reverse-path filter set to loose. |

## Architectural constraints

- **Two-root Yoga layout** is now canonical:
  - `underyoga` on internal eMMC (`/dev/mmcblk1`): encrypted minimal recovery/dispatcher, no desktop.
  - `yoga-sd-0` on internal SD (`/dev/mmcblk0` when booted on Yoga): encrypted workstation root, hostname `yoga`.
- **SD root wear/health** is the dominant operational risk. Watch `journalctl -k -b` for `mmcblk0`, `I/O error`, `EXT4-fs`, and `emergency_ro`. Use `underyoga` to fsck the SD when needed.
- **No AVX2** rules out a growing fraction of modern prebuilt JS tooling (Bun, some Node native modules).
- **No AC**'97/HDA quirks**: pipewire works fine; pulseaudio is explicitly disabled in `profiles/laptop.nix`.

## Planned improvements

Prioritized roughly by impact / effort ratio. Pick from this list when working on yoga.

### I-1: Enable kernel crash logging (priority: high)
**Why**: F-1 is undiagnosable without it. Next freeze must leave evidence.
**Plan**:
- Enable `pstore` so panics survive across reboots: kernel cmdline `efi_pstore.pstore_disable=0` (n/a on BIOS yoga; use `ramoops` instead).
- Configure `ramoops` via a reserved memory region — declarative in NixOS as `boot.kernelParams = [ "ramoops.mem_address=0x..." "ramoops.mem_size=0x100000" ]` after picking a safe address.
- Or simpler: `netconsole` over wifi to spray. Works only if wifi was up at time of hang.
- Add a `systemd-coredump` policy so userspace crashes are at least captured.
- Enable lid/thermal event logging (`acpid` + verbose `systemd-logind`).

### I-2: Boot-time baseline (status: captured 2026-05-23, see `docs/boot-baseline.txt`)
- **Total: 40.4s** to graphical.target (1.6s kernel + 11.3s initrd + 27.5s userspace).
- **Single dominant blocker**: `dhcpcd.service` takes **22.4s**. Everything after dhcpcd is sub-3s.
- **eMMC device enumeration**: ~14s of the initrd. Hardware-bound, not fixable in software.
- Other notable services: `home-manager-spencer` 2.6s, `accounts-daemon` 1.2s, everything else sub-1s.
- Critical chain: `graphical → multi-user → dhcpcd → resolvconf → basic → dbus-broker → ...`. dhcpcd gates everything user-facing.

### I-3: Boot time reduction (priority: medium)
Baseline (I-2) shows **dhcpcd is the entire game** — 22 of 40 seconds. Everything else is rounding error.

1. **Stop blocking `multi-user.target` on dhcpcd lease acquisition.** Either:
   - Pass dhcpcd `-b` (background immediately, don't wait for lease) via `networking.dhcpcd.extraConfig` or `wait` settings. Lose: services that strictly need network at startup will see no IP for ~20s after boot. Win: graphical.target reaches in ~18s instead of 40s.
   - Or switch to **systemd-networkd** with `networking.useNetworkd = true; systemd.network.wait-online.enable = false;`. Networkd is more aggressive about parallel async startup.
2. **Drop lightdm**, use `services.xserver.displayManager.startx` + a 3-line `~/.xinitrc` that execs `emacs --fullscreen`. Saves the 477ms lightdm cost + the autologin PAM dance (a few hundred ms more). Modest gain; main reason to do it is reduced surface area.
3. **Pre-start emacs as a daemon** via `systemd.user.services.emacs`. Moves emacs init off the critical path for the first session.
4. **Trim unused services** if any are pulled in by `profiles/laptop.nix` defaults (e.g., bluetooth, cups, avahi). Audit with `systemd-analyze blame`.
5. **Kernel cmdline tweaks**: `quiet loglevel=3` to skip slow console scrollback. Cosmetic.
6. **GRUB "not a correct xfs inode" warnings at boot**. GRUB probes attached block devices during menu generation; the residual xfs signature on a previously-used USB scratch drive (or any other attached block device) triggers a noisy "press enter to continue" prompt that pauses boot indefinitely until acknowledged. Mitigations:
   - Always `wipefs -a /dev/sdX1` on USB scratch drives after the build before unplugging.
   - Set `boot.loader.grub.extraConfig = "set timeout=1";` so the menu doesn't sit waiting on the user.
   - Investigate `boot.loader.grub.useOSProber = false` (default in current NixOS but worth confirming) — os-prober is the most common source of foreign-fs probes during grub-mkconfig.

**Realistic target**: ~15s to graphical.target if I-3.1 is applied; below that, gains are <2s each and probably not worth the complexity.

### I-4: Power management investigation (priority: medium)
Coupled to F-1 / F-3. **Do not change** until I-1 is in place — changing power settings before we can capture freeze data risks burying the symptom.
- Once I-1 is live: declare `services.logind.lidSwitch = "ignore"` etc. and observe whether F-1 recurs.
- Decide whether DPMS is doing more harm than good.

### I-5: Migrate emacs packages fully to Nix (priority: low)
Already most of the way there (`programs.emacs.extraPackages` in `home/spencer.nix`). Outstanding:
- `per-buffer-theme` (marked broken in nixpkgs; package or override).
- Anything else currently bootstrapped via `(package-install ...)` in `.emacs` should move to Nix.
- Eventual goal: remove the MELPA bootstrap block from `.emacs` entirely → emacs starts offline-safe.

### I-6: Migrate to NetworkManager (priority: low)
- Better captive-portal / roaming / multi-network UX for a laptop.
- agenix integration via `networkmanager.ensureProfiles.environmentFiles` is straightforward.
- Cost: rewrite `wifi-yoga.nix` and accept NM is a bigger surface than wpa_supplicant.
- Deferred until wpa_supplicant proves materially insufficient (currently it works fine post-C-2).

## Out of scope / explicitly declined

- **USB drive bind-mounted at /nix or /nix/store**: ruled out by user. Yoga must boot and function with no USB attached.
- **Reinstall on bigger storage**: future, not now.
- **Bun**: hardware-incompatible.
- **NetworkManager migration**: deferred per I-6.

## Diagnostic quick-reference

```
# Which Yoga root am I on?
hostname; findmnt -no SOURCE,OPTIONS /; readlink /run/current-system

# Disk pressure
df -h / /boot; du -sh /nix/store

# GC eligibility
sudo nix-store --gc --print-roots | grep -v ^/proc | head

# Boot time breakdown
systemd-analyze blame --no-pager
systemd-analyze critical-chain --no-pager

# SD-card health (run on yoga-sd-0)
sudo journalctl -k -b --no-pager | grep -E 'mmcblk0|I/O error|EXT4-fs|Buffer I/O|emergency_ro'
findmnt -no SOURCE,OPTIONS /

# Fsck SD from underyoga
sudo cryptsetup open --key-file /run/agenix/cross-sd-key /dev/mmcblk0p2 yoga-sd-root
sudo e2fsck -f -y /dev/mapper/yoga-sd-root
sudo e2fsck -f -y /dev/mmcblk0p1
sudo cryptsetup close yoga-sd-root

# Wifi state
sudo systemctl status wpa_supplicant-wlp2s0
sudo journalctl -u wpa_supplicant-wlp2s0 -b --no-pager | tail -30

# Decrypted secrets present and readable?
sudo ls -la /run/agenix/

# Force-restart wifi after secret change
sudo systemctl restart wpa_supplicant-wlp2s0
```
