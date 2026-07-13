# nixpkgs build-test results (target rev)

Build-tested every host's toplevel on the target `nixpkgs` rev
`e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3` (`nixos-unstable` head as of 2026-07-11, picked in
`nixpkgs-pick-target-rev`) BEFORE any switch, via:

```
nix build --override-input nixpkgs github:nixos/nixpkgs/e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3 \
  --no-write-lock-file --no-link .#nixosConfigurations.<h>.config.system.build.toplevel
```

No `flake.lock` mutation was committed here — that lands in `nixpkgs-bump-drop-overlay`, gated on
this task and the grub acceptance test.

## Results (after fix below)

| host       | result |
|------------|--------|
| chrome1    | PASS (`EXIT=0`) |
| chrome2    | PASS (`EXIT=0`) |
| chrome3    | PASS (`EXIT=0`) |
| underyoga  | PASS (`EXIT=0`) |
| yoga-sd-0  | PASS (`EXIT=0`) |

## Fix required: `pkgs.flannel` fixed-output-hash mismatch

At the target rev, `chrome{1,2,3}` (the k3s hosts, via `profiles/kubernetes`) failed to build with:

```
error: hash mismatch in fixed-output derivation '.../flannel-0.28.6-go-modules.drv'
```

nixpkgs' `pkgs.flannel` (0.28.6) pins its GitHub tarball source `src` with a fixed-output hash that
no longer matches the bytes GitHub currently serves for that tag (GitHub periodically regenerates
release-archive tarballs, so the sha256 drifts out from under an old nixpkgs pin — not caused by
this repo, and not something further bumping nixpkgs necessarily avoids, since the same drift can
recur on any later pin whose nixpkgs snapshot predates GitHub's regeneration). Fixed by overriding
`flannel.src` to the hash GitHub actually serves today, in `profiles/kubernetes/kubernetes-common.nix`:

```nix
nixpkgs.overlays = [
  (final: prev: {
    flannel = prev.flannel.overrideAttrs (old: {
      src = prev.fetchFromGitHub {
        owner = "flannel-io";
        repo = "flannel";
        rev = "v${prev.flannel.version}";
        sha256 = "sha256-sqpsUAKBza96AMQMUCG94KOht5ExnHRLR7eGna3m3Xg=";
      };
    });
  })
];
```

Drop this overlay once nixpkgs itself carries a matching hash for the flannel version in use (check
at bump time in `nixpkgs-bump-drop-overlay`).

`underyoga` and `yoga-sd-0` built clean with no fix needed beyond the pre-existing
`profiles/libxml2-grub-fix.nix` overlay (still in place; not exercised/removed by this task — that's
`nixpkgs-grub-acceptance-test` / `nixpkgs-bump-drop-overlay`).

## For `nixpkgs-bump-drop-overlay`

- Fold the `pkgs.flannel` `src` override above into the tree alongside the `flake.lock` bump (already
  committed on this task's branch at `profiles/kubernetes/kubernetes-common.nix`).
- No other per-host config changes were needed — `chrome{1,2,3}`, `underyoga`, `yoga-sd-0` all
  build-verify at the target rev with just the flannel fix.
