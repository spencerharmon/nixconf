# nixpkgs target rev selection

Investigation only — no flake edit here. Picks the concrete `nixpkgs` rev the bump
should target and classifies the risk. All package versions below were VERIFIED by
reading the pkg definitions at each rev (not assumed).

## Current state (as pinned)

- `flake.lock` nixpkgs `rev` = `bd3bac8bfb542dbde7ffffb6987a1a1f9d41699f`
  (committed 2025-03-26, `lib/.version` = `25.05` → 25.05-pre, rolling
  `nixos-unstable` channel).
  - libxml2 = **2.13.6**
  - perlPackages.XMLLibXML (XML::LibXML) = **2.0210**
- `flake.nix` input URL already references
  `github:nixos/nixpkgs/d233902339c02a9c334e7e593de68855ad26c4cb`
  (committed 2026-05-15, `lib/.version` = `26.05` → 26.05-pre) but `flake.lock`
  was NOT regenerated, so the effective/locked rev is still `bd3bac8…`.
  - At `d2339…`: libxml2 = **2.15.1**, XML::LibXML = **2.0210** — both BELOW the
    required floors, so `d2339…` is NOT an acceptable target and re-locking to it
    would not satisfy the goal.

## Required floors

- libxml2 >= **2.15.3**
- XML::LibXML (perlPackages.XMLLibXML) >= **2.0213**

Landing points in nixpkgs (master):
- libxml2 `2.15.2 -> 2.15.3`: commit `cbe92c8091a5f79e9da03b9502bb93cd66f1f181`
  (2026-06-05).
- perlPackages.XMLLibXML `2.0210 -> 2.0213` (fixes CVE-2026-817…): commit
  `5fb740257c36a83351b79b1dc15d8056a1533976` (2026-06-26).

The XML::LibXML bump is the later of the two, so any acceptable target must be a
`nixos-unstable` rev dated on/after 2026-06-26.

## Picked target rev

**`e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3`** — `nixos-unstable` channel head as
of 2026-07-11 (`lib/.version` = `26.11` → 26.11-pre).

Verified at this rev:
- libxml2 = **2.15.3**  ✓ (>= 2.15.3)
- perlPackages.XMLLibXML = **2.0213**  ✓ (>= 2.0213)

`nixos-unstable` (rather than a bare `nixpkgs-unstable` or master tip) is chosen
because that channel ref only advances after the NixOS test/Hydra gate passes, so
the rev is a known-good rolling point.

## Risk classification

**Higher risk — release-jump-equivalent** (not a low-risk same-release-branch
advance).

The flake pins nixpkgs by bare rev on the rolling `nixos-unstable` channel (no
`release-XX.YY` branch is tracked). Strictly it is the same lineage
(`nixos-unstable`), but the effective locked rev is 25.05-pre (2025-03-26) and the
target is 26.11-pre (2026-07-11): ~16 months and multiple release cycles
(25.05 → 25.11 → 26.05 → 26.11) of churn. That breadth of change (stdenv, glibc,
compiler, module renames/removals) puts it firmly in the higher-risk bucket and
justifies the downstream enumerate-breaking-changes / build-test / grub-acceptance
tasks before it is deployed.
