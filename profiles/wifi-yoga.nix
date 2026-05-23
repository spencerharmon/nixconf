{ config, ... }:
{
  age.secrets.wifi-yoga.file = ../secrets/wifi-yoga.age;

  networking.wireless.interfaces = [ "wlp2s0" ];
  networking.wireless.secretsFile = config.age.secrets.wifi-yoga.path;
  networking.wireless.networks."Compound-5G".pskRaw = "ext:COMPOUND_5G_PSK";

  # Ensure wpa_supplicant doesn't start until its secrets are available.
  systemd.services."wpa_supplicant-wlp2s0" = {
    after = [ "agenix.service" ];
    wants = [ "agenix.service" ];
  };
}

