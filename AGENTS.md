# AGENTS.md

NixOS flake managing chrome hosts plus Yoga's two-part layout: `underyoga` on internal eMMC and `yoga-sd-0` on encrypted SD. `chrome*` deploy via `deploy-rs`; Yoga applies locally with `nixos-rebuild`.

## Layout

- `flake.nix` — `nixosConfigurations` + `deploy.nodes`. `inputs` is passed to modules via `specialArgs = { inherit inputs; }` (required for `home-manager.nixosModules.home-manager`).
- `systems/<host>/` — per-host hardware/network/identity. `systems/yoga/` is shared Yoga hardware/base config, not a standalone flake target.
- `profiles/` — reusable role modules. Notable:
  - `common.nix` — openssh, flakes, timezone, allowUnfree, **GC policy** (`nix.gc.automatic`, `min-free`/`max-free`, `auto-optimise-store`).
  - `laptop.nix` — X + lightdm autologin → EXWM, pipewire, firefox, emacs GUI.
  - `wifi-yoga.nix` — yoga wifi via wpa_supplicant + agenix.
  - `spencer-home.nix` — wires home-manager into the system; consumes `home/spencer.nix`.
  - `coding-agents.nix` — `claude-code` (note CPU constraints below).
  - `underyoga.nix` — minimal encrypted eMMC recovery/dispatcher system.
  - `yoga-sd.nix` — encrypted SD-root Yoga workstation profile.
  - `zram.nix` + `spencer-password.nix` — shared Yoga-family zram + declarative password hash.
- `clusters/chrome-kube.nix` — shared k8s cluster settings.
- `home/spencer.nix` + `home/spencer/<file>` — home-manager config + flat files (`.emacs` etc.).
- `secrets/secrets.nix` + `secrets/*.age` — agenix. Recipients: `spencer` (admin user) + per-host SSH host keys.
- `users.nix` — `spencer` user + authorized SSH ed25519 key. Applied to every host.

Hosts: `chrome1` (k8s master+node), `chrome2`/`chrome3` (k8s workers, `chromeN.lan`), `underyoga` (minimal eMMC recovery/dispatcher on Yoga), `yoga-sd-0` (primary encrypted-SD Yoga workstation, hostname `yoga`).

## Module wiring quirks

- `profiles/common.nix` is **not** imported by host `configuration.nix`. It comes in transitively (e.g. via `kubernetes/kubernetes-common.nix` or `laptop.nix`). A new host must import a profile that pulls it in, or import it explicitly in `flake.nix`.
- Inputs order matters. **`nixpkgs` should be declared before `agenix`** in `flake.nix` `inputs`, and `agenix.inputs.nixpkgs.follows = "nixpkgs"` must be set — otherwise agenix's vendored `nixos-25.05` nixpkgs gets promoted to top-level and our pin is silently ignored. Symptom: options like `networking.wireless.secretsFile` "don't exist" even though the URL pin is correct.
- `home-manager.inputs.nixpkgs.follows = "nixpkgs"` likewise.

## Commands

Build a host without deploying:
```
nix build .#nixosConfigurations.<host>.config.system.build.toplevel
```

Deploy chrome*:
```
nix run github:serokell/deploy-rs -- .#<host>
```

Yoga workstation (booted from encrypted SD, hostname `yoga`):
```
sudo nixos-rebuild switch --flake .#yoga-sd-0
```

Underyoga recovery/dispatcher (booted from internal eMMC):
```
sudo nixos-rebuild switch --flake .#underyoga
```

Edit a secret (run on a host with `~/.ssh/id_ed25519` that's a registered recipient):
```
cd secrets && nix run github:ryantm/agenix -- -e <name>.age
```

## Conventions

- `system.stateVersion` is per-host; never change on an existing system.
- K8s firewall ports → `profiles/kubernetes/controller-worker.nix` (and `worker.nix`).
- Cluster-wide k8s → `clusters/`. Role → `profiles/kubernetes/`. Hardware/network → `systems/<host>/`.
- Wifi credentials: never hard-code. Use agenix + `networking.wireless.secretsFile` with `pskRaw = "ext:VARNAME"`. Bound the wpa_supplicant unit to agenix: `systemd.services."wpa_supplicant-<iface>" = { after = [ "agenix.service" ]; wants = [ "agenix.service" ]; }`.
- Always set `networking.wireless.interfaces = [ "<iface>" ]` so per-interface units are generated (the auto-detect mode is flaky and resists `wpa_cli`).

## Yoga gotchas

For full hardware notes, known issues, and planned improvements, see [`docs/yoga.md`](docs/yoga.md). Highlights:

- **Current Yoga storage state**: internal eMMC (`/dev/mmcblk1`) runs encrypted `underyoga` recovery/dispatcher; internal SD slot (`/dev/mmcblk0` when booted on Yoga) runs encrypted `yoga-sd-0` workstation.
- `underyoga` GRUB default entry searches for `yoga-sd-boot` and `configfile`s into the SD's own GRUB config. If no SD is present, choose the `underyoga` menu entry manually.
- `yoga-sd-0` uses `boot.loader.grub.device = "nodev"`; normal `nixos-rebuild switch --flake .#yoga-sd-0` updates `/boot/grub/grub.cfg` and kernels but does **not** reinstall MBR. Install scripts run `grub-install --boot-directory=/mnt/boot /dev/<current-device>` once at provisioning time.
- SD wear mitigations on Yoga SD roots: zram swap, no disk swap, `/tmp` tmpfs, `/` ext4 `noatime,commit=60`, `/boot` `noatime`, weekly fstrim, journald capped at 100M.
- If Yoga SD shows `mmcblk0` I/O errors or root remounts `emergency_ro`, boot `underyoga` and run fsck on `/dev/mmcblk0p1` and `/dev/mapper/yoga-sd-root` before booting the SD again.
- **CPU is Intel Celeron N3150 (Braswell, no AVX2)**. Bun-based tools (`pkgs.opencode`, `pkgs.bun`) SIGILL on first JIT. Use `pkgs.claude-code` (embedded Node SEA) or `pkgs.codex` (Rust binary) instead. Documented in `profiles/coding-agents.nix`.
- IPv6 broken on the local network — `networking.enableIPv6 = false` in `systems/yoga/configuration.nix` (shared by both Yoga targets).

## Bootstrap from a stuck Nix

Yoga's Nix daemon was once too old to evaluate current nixpkgs. To upgrade Nix without a working `nixos-rebuild`:
```
nix-env -iA nix -f https://github.com/NixOS/nixpkgs/archive/nixos-23.11.tar.gz
export PATH=$HOME/.nix-profile/bin:$PATH
```
This installs a newer `nix` into the user profile. Then rebuild using that nix; the rebuild brings the system's nix forward.

Major version jumps may also require an intermediate hop (e.g. 22.11 → 23.11 → 26.05) if the target nixpkgs requires Nix features absent from the running daemon. Symptoms: "requires nixVersion >= X.Y" eval errors, or `/setup: No such file or directory` from the builder.

## Emacs deployment

`.emacs` is managed via home-manager (`home.file.".emacs".source`). Existing files on first activation get renamed to `*.hm-bak` (`home-manager.backupFileExtension`).

Packages are declared in `home/spencer.nix` under `programs.emacs.extraPackages` (Nix-managed, no MELPA fetch at runtime). The `.emacs` is **defensive** — missing packages and EXWM init failures log warnings rather than crashing, because emacs is the window manager on yoga and a crash means no session.

EXWM-only blocks are gated by `(when (string= (system-name) "yoga") ...)`.
