# nixpkgs breaking-changes enumeration (25.05-pre -> 26.11-pre bump)

Investigation only — no flake mutation here. Enumerates breaking changes / renames / deprecations
between the currently-locked `nixpkgs` rev and the `nixpkgs-pick-target-rev` pick, per host, based on
the official NixOS release notes for 25.11, 26.05, and 26.11 (the releases this bump crosses) plus a
read of this repo's actual host configs.

## Rev range

- Locked today (`flake.lock`): `bd3bac8bfb542dbde7ffffb6987a1a1f9d41699f`, 2025-03-26,
  `lib/.version` = 25.05-pre (rolling `nixos-unstable`, pre-25.05 branch-off).
- Target (`docs/nixpkgs-pick-target-rev.md`): `e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3`, 2026-07-11,
  `lib/.version` = 26.11-pre.
- Crosses the 25.05, 25.11, and 26.05 stable branch points; the target is itself pre-26.11 unstable.
  This is a release-jump-equivalent bump (already classified as higher risk in the pick-target-rev
  doc) — the notes below cover the 25.11 / 26.05 / 26.11 release-notes sections, the only ones between
  the two revs.

## What's actually in this repo (scope check)

Read `flake.nix` + `systems/*` + `profiles/*` directly rather than assuming from the ROI wording:

- `chrome{1,2,3}`: stub `configuration.nix` (systemd-boot, DHCP, `stateVersion = "22.05"`, no services
  configured in the host file itself) wired via `flake.nix` to
  `profiles/kubernetes/{controller-worker,worker}.nix` + `clusters/chrome-kube.nix`. These import
  **NixOS's built-in `services.kubernetes` module** (opens 2379/2380/6443/10250/10259/10257, sets
  `roles`, `flannel.backend.Type = "host-gw"`) — **not** `services.k3s`/`services.rke2` despite the ROI
  prose saying "k3s". There is no Postgres, gitea, or zuul module anywhere in this repo (verified via
  `grep -rli postgres|gitea|zuul --include='*.nix'` — zero hits): those must be deployed out-of-band
  (containers/other tooling), not through nixconf, so this repo's nixpkgs bump cannot itself trigger a
  Postgres-major or gitea/zuul migration — flag that as a cross-system dependency to verify
  out-of-repo, not a nixconf-code risk.
- `underyoga` + `yoga-sd-0`: both explicitly set `boot.initrd.systemd.enable = lib.mkForce false;` in
  `profiles/underyoga.nix` / `profiles/yoga-sd.nix` — i.e. they deliberately opt OUT of the systemd
  stage-1 default and rely on the legacy **scripted initrd** (documented inline: "scripted initrd
  initializes i915 early, prompts on tty0 for LUKS password"). Both use `boot.loader.grub` (BIOS/MBR,
  not systemd-boot) with LUKS2 root.

## Per-host breaking changes

### chrome1 / chrome2 / chrome3 (`services.kubernetes`, currently unbuilt/prospective — ROI: chrome/k3s
bringup is still pending, ports 6443/2379/2380/10250/10259/10257 only, no data written yet)

- **26.05**: `services.kubernetes.addons.dns.coredns` renamed to
  `services.kubernetes.addons.dns.corednsImage` and now expects a *package* instead of an attrset;
  default source flips from pulling the upstream CoreDNS image off Docker Hub to building it locally
  via `nixpkgs.coredns` + `dockerTools.buildImage`. `clusters/chrome-kube.nix` /
  `profiles/kubernetes/*.nix` never set this option, so the new default silently applies — a
  behavior/build-time change (extra build to produce the image), not a stateful-data migration, since
  no cluster has ever run here yet. Not cheaply reversible only in the trivial sense that you'd pin the
  old attrset shape back explicitly; otherwise low risk.
- **26.05**: `services.kubernetes.kubelet.clusterDns` changed from a single string to a list of DNS
  resolvers, and `featureGates` changed from `listOf str` to `attrsOf bool`. Neither option is set in
  this repo today, so no rewrite needed on today's config, but any future config value in that shape
  will need updating.
- **No** `services.kubernetes` module removal in any release note between 25.05 and 26.11 — the module
  survives all three intervening releases (it's still documented with active option changes in 26.05),
  so continuing to use it is not itself an obsolescence risk on this rev, despite it being NixOS's
  historically under-maintained k8s module.
- **etcd**: embedded via `services.kubernetes` (ports 2379/2380 opened directly in
  `profiles/kubernetes/controller-worker.nix`); no etcd major-version-jump backward-incompatibility is
  called out in the 25.11/26.05/26.11 release notes (the only etcd note in nixpkgs history, the 3.4→3.5
  bump, predates the current lock). **Because no chrome host has been built/deployed yet** (ROI:
  "chrome/k3s bringup" is still pending, `stateVersion` is still the generated-template default
  `22.05`), there is **no existing etcd/k3s cluster state to migrate** on this bump — the "stateful
  migration" risk the ROI flags is real for whenever a cluster eventually runs here, but is not
  triggered by this nixpkgs bump itself since it would be a fresh bring-up on the new rev, not an
  in-place upgrade of a running cluster. Flag this explicitly for the operator: if a chrome cluster gets
  built BEFORE this bump lands, doing the nixpkgs bump afterward becomes a real etcd-version, in-place
  cluster upgrade and should be re-evaluated at that time (not cheaply reversible once cluster data
  exists).
- **Postgres behind gitea/zuul**: NOT present in this repo (see scope check above). If/when gitea/zuul
  are deployed to the chrome fleet, whatever Postgres they use will be whatever container image or
  external module manages it — track that migration in whichever repo owns it, not here.
- **Container runtime**: `profiles/kubernetes/*.nix` do not set `services.kubernetes.kubelet.containerManager`
  or configure a runtime explicitly; NixOS's Kubernetes module default runtime is containerd (has been
  since containerd became the default years before this rev range — see historical note “Kubernetes has
  deprecated docker as container runtime… enables containerd by default”, already true at both ends of
  this bump). No new container-runtime breaking change surfaced in 25.11/26.05/26.11 notes. Low risk,
  reversible (config-only, no runtime state predates this bump on these hosts).

### underyoga / yoga-sd-0 (**highest risk in this enumeration**)

- **26.05 highlight**: "Stage 1 (initrd) is now based on systemd by default, and the old scripted
  implementation is deprecated and scheduled for removal in 26.11." Both `profiles/underyoga.nix` and
  `profiles/yoga-sd.nix` explicitly force `boot.initrd.systemd.enable = false` — i.e. they are pinned to
  exactly the implementation being removed, and the target rev (`e7a3ca8`, 2026-07-11, `26.11-pre`) is
  dated to fall *inside* the 26.11 development window where that removal is scheduled to land. **This
  is a real risk that the scripted stage-1 modules may already be gone or non-functional at the picked
  rev** — the pick-target-rev doc verified libxml2/XML::LibXML versions but did not check
  `boot.initrd.systemd.enable = false` availability. This must be checked explicitly (grep
  `nixos/modules/system/boot/stage-1.nix` or equivalent at the target rev, or just try building) as
  part of `nixpkgs-build-test-hosts` / `nixpgs-grub-acceptance-test` before this bump lands — **not
  cheaply reversible**: the scripted stage-1 behavior these hosts depend on (early i915 modeset before
  the LUKS prompt, tty0 interactive password prompt, cryptsetup-askpass semantics) has a documented,
  materially different replacement path under systemd stage-1 (see below), and rolling back after
  switching an on-device system would mean re-doing the boot/initrd plumbing again.
- If scripted initrd is in fact gone/removed at the target rev, both hosts MUST migrate to systemd
  stage-1, which (per 26.05 release notes) changes multiple things relevant to this exact LUKS+i915+
  BIOS/grub setup:
  - LUKS device path convention: `fileSystems."/".device` should be the `/dev/mapper/<name>` matching
    `boot.initrd.luks.devices.<name>`, or `x-systemd.device-timeout=infinity` added to avoid a device
    timeout while systemd waits for the passphrase prompt. Both profiles currently set
    `boot.initrd.luks.devices.${luksMapperName}.device = /dev/disk/by-partuuid/...` (the LUKS *source*
    device, which is fine either way) — the root filesystem mount itself needs checking against this
    rule once the module is read.
  - `cryptsetup-askpass` is gone under systemd stage-1; the interactive password path becomes
    `systemctl default` prompting instead. The inline design comment in `yoga-sd.nix` ("prompts on tty0
    for LUKS password") describes exactly the scripted-stage-1 UX that changes here.
  - Many kernel command-line parameters get replaced with systemd-native equivalents — `underyoga.nix`
    injects `boot.loader.grub.extraEntries`/kernel params for its dispatcher-to-yoga-sd chainload; those
    need re-auditing against the systemd stage-1 parameter set if scripted initrd is dropped.
  - The early `i915` modeset (both profiles append `boot.initrd.kernelModules = [ "i915" ]` and rely on
    it initializing "early" per the design comment) is a scripted-stage-1-era ordering assumption;
    systemd stage-1 orders modules/services differently (unit-based, not linear script), so the same
    "prompt appears on the right display before password entry" behavior needs to be reverified, not
    assumed to carry over unchanged.
  - Both hosts use **grub** (`boot.loader.grub.enable = true`, BIOS/MBR — not `systemd-boot`), so the
    unrelated 26.11 systemd-boot "Automatic Boot Assessment" / entry-naming change (`nixos-generation-
    <n>.conf` → content-hash names) does not apply to them; no additional grub-entry-naming migration
    needed here specifically for these two hosts. (`chrome{1,2,3}` DO use `boot.loader.systemd-boot`,
    but since they have no installed generations yet, the boot-entry-naming migration note is moot for
    them too — it only matters for **existing** ESP entries, and there are none yet on unbuilt hosts.)
  - Separately (already handled by a sibling task, noted here only for completeness): the grub
    `install-grub.pl`/XML::LibXML SIGSEGV that motivates this whole bump is unrelated to the stage-1
    question — it is a grub-install-time issue (libxml2/XML::LibXML pair), not an initrd-runtime one.
- **Multi-SD cross-mount keyfile mechanism** (`yoga-sd.nix`'s documented `/etc/keys/cross-sd.key`
  cross-SD unlock feature): scripted-vs-systemd stage-1 changes how/when a keyfile-based auto-unlock
  could be added later post-boot; not currently wired into initrd (per the doc it's post-boot only), so
  no immediate compatibility question, but worth re-noting if that feature is built out on the systemd
  stage-1 side later.
- Nothing in the 25.11/26.05/26.11 notes indicates a Postgres/etcd/container-runtime concern for these
  two hosts — they run no such services (laptop/console profiles only).

## Not-cheaply-reversible migrations, summarized

1. **`underyoga` + `yoga-sd-0` scripted-initrd removal** (26.11) — highest priority to verify before
   landing the bump; if the scripted stage-1 modules are gone at the target rev, both hosts need a real
   boot-path redesign (LUKS prompt mechanism, kernel param set, i915-timing assumption), not a
   config-flag flip. Concretely gate this in `nixpkgs-grub-acceptance-test` / `nixpkgs-build-test-hosts`
   by actually building/booting with `boot.initrd.systemd.enable = false` at the target rev and see
   whether the assertion/module even evaluates.
2. **chrome fleet + `services.kubernetes`/etcd, IF a cluster gets built before this bump lands** — not a
   risk *today* (no chrome host is built), but becomes a real in-place etcd/data migration the moment a
   cluster exists; operator should be aware bump-after-bringup changes the risk profile of this
   specific task's "no stateful migration found" conclusion.
3. Everything else identified (CoreDNS image-source default, kubelet DNS/featureGates option shape) is
   config-only and cheaply reversible — no existing state depends on the old shape on unbuilt/stub
   hosts.

## Not found in this bump range

No Postgres, gitea, zuul, k3s, or rke2 configuration exists anywhere in this nixconf repo today
(verified by direct grep across `*.nix`), so none of the Postgres-major/gitea/zuul/k3s/etcd release-note
items that *do* exist for other NixOS release-note sections (e.g. `services.k3s`/`services.rke2` code
merge in 25.11 highlights) apply to any host tracked here. If those services are added to this repo
later (or already run outside nixconf against these hosts), re-run this enumeration against whatever
their actual NixOS/container module turns out to be.
