{ config, ... }:
{
  age.secrets.wifi-yoga = {
    file = ../secrets/wifi-yoga.age;
    group = "wpa_supplicant";
    mode = "0440";
  };

  networking.wireless.interfaces = [ "wlp2s0" ];
  # Let wpa_cli (and the M-x wifi picker in home/spencer/.emacs) add
  # ad-hoc networks at runtime alongside the declarative
  # Compound-5G entry. Imperative networks persist to wpa_supplicant's
  # imperative config file, which survives reboots.
  networking.wireless.allowAuxiliaryImperativeNetworks = true;
  # Expose the wpa_supplicant control socket at /run/wpa_supplicant/
  # for users in the wpa_supplicant group. spencer is added to that
  # group in users.nix. Required for wpa_cli (used by the M-x wifi
  # picker) to talk to the supplicant without sudo. Without this,
  # NixOS doesn't emit any ctrl_interface= line and wpa_cli fails
  # with "No such file or directory".
  networking.wireless.userControlled = true;
  networking.wireless.secretsFile = config.age.secrets.wifi-yoga.path;
  # Compound-5G is a WPA2/WPA3 transition AP ([WPA2-PSK+SAE-CCMP]). The NixOS
  # wpa_supplicant module's default authProtocols includes SAE + FT-SAE, which
  # makes it emit a SECOND, higher-priority (priority=1) SAE network block
  # (see mkWPA3/mkWPA2Fallback in nixos/modules/services/networking/wpa_supplicant.nix).
  # wpa_supplicant tries that SAE block FIRST every boot, but SAE derives its key
  # from the plaintext passphrase (sae_password), not from a raw PSK -- and we only
  # supply pskRaw. So SAE auth fails (CTRL-EVENT-AUTH-REJECT status_code=15), and
  # because both blocks share the SSID the temp-disable backoff knocks out the good
  # WPA2 block too, flapping the link for minutes on cold boot. Restarting the unit
  # only clears the backoff and races onto WPA2. Pinning authProtocols to the WPA2
  # set drops the SAE block entirely -> single block, clean association at boot.
  networking.wireless.networks."Compound-5G" = {
    pskRaw = "ext:COMPOUND_5G_PSK";
    authProtocols = [ "WPA-PSK" "WPA-EAP" "FT-PSK" "FT-EAP" ];
  };

  # Ensure wpa_supplicant doesn't start until its secrets are available.
  systemd.services."wpa_supplicant-wlp2s0" = {
    after = [ "agenix.service" ];
    wants = [ "agenix.service" ];
  };
}

