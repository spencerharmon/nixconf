# AGENTS.md

NixOS flake managing 4 hosts. `chrome*` deploy via `deploy-rs`; `yoga` applies locally.

## Layout

- `flake.nix` — `nixosConfigurations` + `deploy.nodes`. `inputs` is passed to modules via `specialArgs = { inherit inputs; }` (required for `home-manager.nixosModules.home-manager`).
- `systems/<host>/` — per-host hardware/network/hostname only.
- `profiles/` — reusable role modules. Notable:
  - `common.nix` — openssh, flakes, timezone, allowUnfree, **GC policy** (`nix.gc.automatic`, `min-free`/`max-free`, `auto-optimise-store`).
  - `laptop.nix` — X + lightdm autologin → EXWM, pipewire, firefox, emacs GUI.
  - `wifi-yoga.nix` — yoga wifi via wpa_supplicant + agenix.
  - `spencer-home.nix` — wires home-manager into the system; consumes `home/spencer.nix`.
  - `coding-agents.nix` — `claude-code` (note CPU constraints below).
  - `yoga-minimal.nix` — stripped profile used **only for nixpkgs version-jump hops** on yoga's tiny root partition (see "Yoga upgrade dance").
- `clusters/chrome-kube.nix` — shared k8s cluster settings.
- `home/spencer.nix` + `home/spencer/<file>` — home-manager config + flat files (`.emacs` etc.).
- `secrets/secrets.nix` + `secrets/*.age` — agenix. Recipients: `spencer` (admin user) + per-host SSH host keys.
- `users.nix` — `spencer` user + authorized SSH ed25519 key. Applied to every host.

Hosts: `chrome1` (k8s master+node), `chrome2`/`chrome3` (k8s workers, `chromeN.lan`), `yoga` (laptop).

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

Yoga (no deploy-rs entry, apply locally on yoga):
```
sudo nixos-rebuild switch --flake .#yoga
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

- **15 GB root partition (`/dev/mmcblk1p1`)**. A full desktop closure (~6.5 GB) does not fit alongside a running generation. Major nixpkgs version jumps require a "shrink hop":
  1. Use `profiles/yoga-minimal.nix` to build a closure with no desktop (~3 GB).
  2. `nixos-rebuild boot` minimal, reboot.
  3. `sudo nix-collect-garbage -d` frees ~8 GB (drops the old gen's closure).
  4. Rebuild full config — now fits.
- `nix.gc.automatic` + `min-free`/`max-free` in `common.nix` make day-to-day updates self-managing, but a major rebase (e.g. annual release jump) still needs the shrink hop.
- **External USB as scratch store** for big builds:
  ```
  sudo mount /dev/sdX1 /mnt/build
  cd ~/git-repos/nixconf && nix --store /mnt/build build .#nixosConfigurations.yoga.config.system.build.toplevel
  ```
  Then `nixos-rebuild boot` with `--option extra-substituters "local?root=/mnt/build"`. **The final installed system must have zero references to the USB device** — confirm with `nix-store --query --requisites $(readlink /run/current-system) | grep /mnt/build` (should be empty) before unplugging.
- **CPU is Intel Celeron N3150 (Braswell, no AVX2)**. Bun-based tools (`pkgs.opencode`, `pkgs.bun`) SIGILL on first JIT. Use `pkgs.claude-code` (embedded Node SEA) or `pkgs.codex` (Rust binary) instead. Documented in `profiles/coding-agents.nix`.
- IPv6 broken on the local network — `networking.enableIPv6 = false` in `systems/yoga/configuration.nix`.

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
