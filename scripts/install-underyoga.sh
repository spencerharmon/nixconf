#!/usr/bin/env bash
# Build underyoga on spray, push closure to yoga, run nixos-install
# against the LUKS+ext4 root mounted at /mnt on yoga.
#
# Assumes scripts/reformat-emmc-underyoga.sh has been run; eMMC is
# partitioned + LUKS-formatted + /mnt and /mnt/boot are mounted; PARTUUIDs
# have been pasted into systems/underyoga/configuration.nix.
#
# Drops the cleartext yoga host private key into /mnt/etc/ssh/
# (decrypted on spray from yoga-host-key.age) so first boot has a
# working SSH host key that matches the public key in secrets.nix.
set -euo pipefail

YOGA_HOST="${YOGA_HOST:-192.168.1.154}"
NIXCONF=/home/spencer/git-repos/spencerharmon/nixconf
FLAKE_TARGET=underyoga
BOOTSTRAP_DIR=/tmp/yoga-bootstrap
HOST_KEY_TMP=$BOOTSTRAP_DIR/ssh_host_ed25519_key
NIXOS_INSTALL=/nix/store/xvwjsjhpnmdia48sja46j902g724bki6-nixos-install-tools-26.05pre-git/bin/nixos-install

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*"; }

# 1. nixos-install present
if [[ ! -x $NIXOS_INSTALL ]]; then
    die "nixos-install at $NIXOS_INSTALL is gone (gc'd?). Rebuild with:
  nix build --no-warn-dirty --no-link --print-out-paths --impure --expr \\
    '(builtins.getFlake (toString $NIXCONF)).inputs.nixpkgs.legacyPackages.x86_64-linux.nixos-install-tools'
and update NIXOS_INSTALL at the top of this script."
fi

# 2. Confirm /mnt is mounted on yoga and PARTUUIDs are filled in
log "Sanity: /mnt and /mnt/boot mounted on yoga"
ssh "spencer@$YOGA_HOST" 'findmnt /mnt; findmnt /mnt/boot' \
    || die "/mnt or /mnt/boot not mounted on yoga. Run scripts/reformat-emmc-underyoga.sh first."

log "Sanity: PARTUUIDs populated in systems/underyoga/configuration.nix"
if grep -q 'throw "underyoga' "$NIXCONF/systems/underyoga/configuration.nix"; then
    die "systems/underyoga/configuration.nix still has throw stubs. Paste the PARTUUIDs printed by reformat-emmc-underyoga.sh."
fi

# 3. Build underyoga closure on spray
log "Building underyoga closure"
cd "$NIXCONF"
CLOSURE=$(nix build --no-warn-dirty --no-link --print-out-paths ".#nixosConfigurations.$FLAKE_TARGET.config.system.build.toplevel")
[[ -n $CLOSURE ]] || die "Build produced empty closure path."
echo "Closure: $CLOSURE"
echo "Size: $(nix path-info -Sh "$CLOSURE" | awk '{print $2}')"

# 4. Copy closure to yoga
log "Copying closure to yoga (this is the bulk of the work)"
nix copy --no-warn-dirty --to "ssh-ng://spencer@$YOGA_HOST" "$CLOSURE"

# 5. Decrypt host SSH key from agenix, sanity-check, push to yoga, pre-place
log "Decrypting yoga host SSH key from agenix"
mkdir -p "$BOOTSTRAP_DIR"
chmod 700 "$BOOTSTRAP_DIR"
( cd "$NIXCONF/secrets" && nix run --no-warn-dirty github:ryantm/agenix -- -d yoga-host-key.age ) > "$HOST_KEY_TMP"
chmod 600 "$HOST_KEY_TMP"
DERIVED_PUB=$(ssh-keygen -y -f "$HOST_KEY_TMP" | awk '{print $2}')
EXPECTED_PUB=$(grep -oE 'AAAA[A-Za-z0-9+/]+=*' "$NIXCONF/secrets/secrets.nix" | tail -1)
[[ $DERIVED_PUB == "$EXPECTED_PUB" ]] || die "Decrypted host key does NOT match secrets.nix pubkey."
echo "host key round-trip OK"

log "Pre-placing SSH host key into /mnt/etc/ssh on yoga"
scp "$HOST_KEY_TMP" "spencer@$YOGA_HOST:/tmp/ssh_host_ed25519_key" >/dev/null
ssh "spencer@$YOGA_HOST" '
sudo mkdir -p /mnt/etc/ssh
sudo install -m 600 -o root -g root /tmp/ssh_host_ed25519_key /mnt/etc/ssh/ssh_host_ed25519_key
sudo bash -c "ssh-keygen -y -f /mnt/etc/ssh/ssh_host_ed25519_key > /mnt/etc/ssh/ssh_host_ed25519_key.pub"
sudo chmod 644 /mnt/etc/ssh/ssh_host_ed25519_key.pub
sudo shred -u /tmp/ssh_host_ed25519_key
sudo ls -la /mnt/etc/ssh/
'
shred -u "$HOST_KEY_TMP"

# 6. Run nixos-install on yoga, using our version-matched tools that
#    are guaranteed to also be in the underyoga closure.
log "Running nixos-install on yoga (registers profile, installs grub, activates)"

# Build the same nixos-install-tools against THIS flake's nixpkgs pin
# locally first, then push to yoga so the chroot's store has every
# util-linux path the installer references.
NIXOS_TOOLS=$(nix build --no-warn-dirty --no-link --print-out-paths \
    --impure --expr \
    '(builtins.getFlake (toString '$NIXCONF')).inputs.nixpkgs.legacyPackages.x86_64-linux.nixos-install-tools')
echo "installer tools: $NIXOS_TOOLS"
nix copy --no-warn-dirty --to "ssh-ng://spencer@$YOGA_HOST" "$NIXOS_TOOLS"

ssh -t "spencer@$YOGA_HOST" "
  cd /tmp
  sudo $NIXOS_TOOLS/bin/nixos-install \
      --root /mnt \
      --system $CLOSURE \
      --no-root-passwd \
      --no-channel-copy
"
# 7. Unmount + close LUKS
log "Unmounting + closing LUKS on yoga"
ssh "spencer@$YOGA_HOST" '
sync
sudo umount /mnt/boot || true
sudo umount /mnt || true
sudo cryptsetup close underyoga-root || true
'

log "DONE."
echo
echo "Reboot yoga to test:"
echo "  1. With SD inserted: SeaBIOS picks eMMC. underyoga grub menu appears."
echo "     Top entry = 'Boot SD card (yoga-sd-*)' = dispatcher. Press Enter."
echo "     Should chain into the SD's grub.cfg, present its generations."
echo "     Pick one, boot yoga-sd-0 normally."
echo "  2. With SD removed: same eMMC boot. Dispatcher entry's search will"
echo "     fail (no yoga-sd-boot label found). Arrow-down to underyoga"
echo "     entries, pick latest. Boot underyoga; LUKS password prompt;"
echo "     console login."
echo
echo "If neither boots, drop to grub prompt (c) and inspect."
