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
  networking.wireless.networks."Compound-5G".pskRaw = "ext:COMPOUND_5G_PSK";

  # Ensure wpa_supplicant doesn't start until its secrets are available.
  systemd.services."wpa_supplicant-wlp2s0" = {
    after = [ "agenix.service" ];
    wants = [ "agenix.service" ];
  };
}

