{ config, lib, pkgs, ... }:
# Per-host Cloudflare dynamic DNS (favonia/cloudflare-ddns — the same
# client the spray cluster runs as a Deployment). Each host keeps the A/AAAA
# record `<networking.hostName>.<DDNS_ZONE>` pointed at its own public
# addresses.
#
# The zone and API token are NOT in this public repo. They come from the
# agenix secret `cloudflare-ddns.env.age`, an env file with:
#   CLOUDFLARE_API_TOKEN=<token with Zone:DNS:Edit on the zone>
#   DDNS_ZONE=<zone apex>
# The wrapper derives DOMAINS=<hostname>.<DDNS_ZONE> at runtime.
let
  hostName = config.networking.hostName;
  wrapper = pkgs.writeShellScript "cloudflare-ddns-wrapper" ''
    set -euo pipefail
    set -a
    . "$CREDENTIALS_DIRECTORY/env"
    set +a
    : "''${CLOUDFLARE_API_TOKEN:?missing in cloudflare-ddns env}"
    : "''${DDNS_ZONE:?missing in cloudflare-ddns env}"
    export DOMAINS="${hostName}.$DDNS_ZONE"
    unset DDNS_ZONE
    exec ${lib.getExe pkgs.cloudflare-ddns}
  '';
in
{
  age.secrets.cloudflare-ddns-env = {
    file = ../secrets/cloudflare-ddns.env.age;
    mode = "0400";
  };

  systemd.services.cloudflare-ddns = {
    description = "Cloudflare dynamic DNS for ${hostName} (favonia)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    restartTriggers = [ config.age.secrets.cloudflare-ddns-env.file ];

    environment = {
      IP4_PROVIDER = "cloudflare.trace";
      IP6_PROVIDER = "cloudflare.trace";
      UPDATE_CRON = "@every 5m";
      UPDATE_ON_START = "true";
      DELETE_ON_STOP = "false";
      PROXIED = "false";
      TTL = "1";
      RECORD_COMMENT = "cloudflare-ddns (${hostName})";
    };

    serviceConfig = {
      ExecStart = wrapper;
      DynamicUser = true;
      LoadCredential = "env:${config.age.secrets.cloudflare-ddns-env.path}";
      Restart = "on-failure";
      RestartSec = "30s";

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" ];
    };
  };
}
