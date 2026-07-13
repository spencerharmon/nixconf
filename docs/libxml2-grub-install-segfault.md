# libxml2 2.15 / XML::LibXML segfault in the GRUB bootloader installer

## Status

Fixed (worked around) for `yoga-sd-0` via `profiles/libxml2-grub-fix.nix`.
Root cause is a broken toolchain pair in the pinned nixpkgs; the durable
fleet-wide fix is the nixpkgs input bump tracked in the nixconf ROI
("fleet nixpkgs upgrade"). This profile is the interim, scoped
workaround and should be **deleted** once the fleet moves to a nixpkgs
that already carries the fixed versions.

## Symptom

`nixos-install` (and any on-device `nixos-rebuild switch`/`boot` that
touches the bootloader) fails at the bootloader step:

```
/nix/store/…-install-grub.sh: line 4: <PID> Segmentation fault (core dumped)
    perl …/install-grub.pl …/grub-config.xml $@
Failed to install bootloader
```

Deterministic: same crash every run. Kernels and initrd get copied to
`/boot/kernels/`, but `grub.cfg` is never written (the crash happens
mid config-generation).

`dmesg` shows the fault is inside libxml2, at the same address both
times:

```
perl[…]: segfault at 6d ip … sp … error 6
    in libxml2.so.16.1.1[…+0x4c7a0]
```

`error 6` = user-mode **write** protection fault; the faulting address
`0x6d` is a near-null pointer write. Resolving offset `0x4c7a0` against
the libxml2 `.so` (`nm -D` / `addr2line`) lands in the `xmlCheckVersion`
region.

## Root cause

The pinned nixpkgs (`flake.nix` input rev `d233902`, a 26.05 tree dated
2026-05-15) ships a **mismatched pair**:

- **libxml2 2.15.1**
- **XML::LibXML 2.0210** (the perl XML module, released Jan 2024 —
  predates libxml2 2.15 entirely)

NixOS's GRUB installer, `install-grub.pl`, drives XML::LibXML XPath
(`findvalue` / `findnodes`) many times while generating `grub.cfg`.
With this pair it deterministically SIGSEGVs **inside libxml2 2.15.1**.
libxml2 is the executing code, not merely a corruption victim — two
coredumps at the identical offset prove a specific bad state reached in
libxml2, not random heap smash (which would crash at varying sites).

Note it is **not** universally reproducible from an isolated script: a
bare parse, and even an isolated loop of the same XPath queries against
the real `grub-config.xml`, do **not** crash. Only the full
`install-grub.pl` run reaches the state that trips it. So it cannot be
worked around at the script level — the toolchain has to be fixed.

nixpkgs-unstable resolves this by shipping the known-good pair
**libxml2 2.15.3 + XML::LibXML 2.0213**, which build and run cleanly
together. (The three CVE-2026-098x/099x patches carried on 2.15.1 are
folded into 2.15.3 upstream, so 2.15.3 needs no patches.)

## Why it only surfaced now

Two facts combine:

1. **Building the closure never runs `install-grub.pl`.**
   `nix build …system.build.toplevel` compiles everything and emits an
   inert `install-grub.sh` store artifact, but never *executes* it.
   The script only runs at **install/activation** time (`nixos-install`,
   `nixos-rebuild switch`/`boot`). So every earlier `nix build` of this
   closure succeeded — the crashing code path was never exercised. This
   SD deploy is the first real end-to-end install, i.e. the first time
   `install-grub.pl` actually ran.

2. **The pin changed into the broken pair.** Commit `ace147e`
   (2026-05-23, "nixpkgs 22.11 → 26.05") is what pulled in libxml2
   2.15.1 + XML::LibXML 2.0210. On the previous **22.11** pin, libxml2
   was ~2.10.x with an older XML::LibXML — a combination that predates
   the 2.15 breakage and worked.

So the toolchain became broken in late May, but nothing done afterwards
(building closures, iterating config) surfaced it, because none of it
ran the bootloader installer. The first `nixos-install` onto the SD hit
it immediately.

## The fix (scoped to the perl toolchain)

`profiles/libxml2-grub-fix.nix` (imported by `yoga-sd-0` in `flake.nix`)
pins the known-good **2.15.3 / 2.0213** pair — but **only inside the
perl package set** that builds the bootloader installer, not
system-wide.

Rationale: the crash is reached exclusively through `install-grub.pl`'s
XML::LibXML → libxml2 path; nothing else in the system triggers it.
Overriding libxml2 globally invalidates the cache for the entire
X/desktop closure that links libxml2 and forces a multi-hour local
world-rebuild for no benefit. The overlay therefore threads a
**perl-private** libxml2 2.15.3 through `Alien::Libxml2` (how
XML::LibXML's XS locates and links libxml2 at build time) and rebuilds
XML::LibXML 2.0213 against that Alien, leaving system-wide
`pkgs.libxml2` at 2.15.1.

Verified in-config for `yoga-sd-0`:

- `pkgs.libxml2` = `libxml2-2.15.1` (unchanged, cache-hit)
- `perl.pkgs.XMLLibXML` `$VERSION` = `2.0213`, and its `LibXML.so`
  links `libxml2.so.16` from the `libxml2-2.15.3` store path
- the `install-grub` closure references **both** `libxml2-2.15.1`
  (system/GRUB) and `libxml2-2.15.3` (the installer's perl)
- `nix build --dry-run` of the toplevel rebuilds only a handful of
  derivations (perl-private libxml2 + Alien::Libxml2 + XML::LibXML +
  the system generation), not the world.

Because the fix lives in the committed config, it also covers on-device
`nixos-rebuild switch` (which re-runs `install-grub.pl`), not just the
one-shot install.

### Removal condition

Delete `profiles/libxml2-grub-fix.nix` and drop its `flake.nix` import
once the `nixpkgs` input is bumped to a tree that already carries
libxml2 ≥ 2.15.3 and XML::LibXML ≥ 2.0213. Acceptance test: build the
yoga-sd-0 `installBootLoader` (or do an install run) on the new pin
**without** the overlay and confirm the GRUB step completes. See the
nixconf ROI "fleet nixpkgs upgrade" intent.

## Deploy-script lesson (separate but related)

The fix recurred once after it was committed, because the deploy script
(`scripts/deploy-yoga-sd-0-encrypted.sh`) builds from a **standalone
nixconf clone** (`$NIXCONF = ~/git-repos/spencerharmon/nixconf`) that is
a *different checkout* from the beehive-managed tree where fixes are
authored — both share `origin/main`, but the standalone was stale, so
the build silently used the pre-fix config. The script now
`fetch`es + fast-forwards `$NIXCONF` to `origin/main` before building
(`sync_nixconf`, fast-forward-only; `--no-sync` to opt out), so an
upstream fix is always picked up. If you build nixconf from a clone by
hand, make sure it is current before trusting the result.

## Evidence / reference (pinned store paths, for future spelunking)

- installer wrapper: `…-install-grub.sh` → runs `perl …-install-grub.pl`
- config XML: `…-grub-config.xml`
- broken libxml2: `…-libxml2-2.15.1` (`.so.16.1.1`, fault at `+0x4c7a0`
  = `xmlCheckVersion` region)
- fixed pair: `libxml2-2.15.3` + XML::LibXML 2.0213 (from
  nixpkgs-unstable; XML-LibXML-2.0213 tarball
  `mirror://cpan/.../T/TO/TODDR/XML-LibXML-2.0213.tar.gz`)
- to re-resolve a fault offset to a libxml2 symbol without a coredump:
  `nm -D --defined-only <libxml2.so.16> | sort` and find the symbol
  whose address brackets the offset, or `addr2line -f -e <so> <offset>`.
