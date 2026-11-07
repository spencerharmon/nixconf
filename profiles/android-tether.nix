# Internet from an Android phone over USB, WITHOUT Android's tethering path.
#
# Why not just use the tether: on this phone's carrier the system tethering
# bearer carries no traffic (separate IPv6-only DUN bearer, no IPv4
# translation). Traffic originating from an ordinary phone app uses the normal
# data connection, so the phone runs the Socks Tether app
# (https://github.com/spencerharmon/socks-tether, a SOCKS5 server that only
# serves the USB-tether subnet) and yoga routes through it with tun2socks.
#
# Flow:
#   M-x android-tether        -> phone enters USB tethering (adb)   [home/spencer/.emacs]
#   udev: USB net device added -> starts phone-socks@<iface>.service
#   phone-socks@<iface>        -> waits for dhcpcd's lease, starts the app over
#                                 adb, runs tun2socks, adds a default route via
#                                 tun device phone0
#   unplug                     -> the device unit disappears; BindsTo stops the
#                                 service (route and tun go away)
# (A dhcpcd exit hook can NOT do this: the NixOS dhcpcd unit is sandboxed -
# User=dhcpcd, ProtectSystem=strict, NoNewPrivileges - so a hook can log but
# cannot start units or write under /run.)
#
# Nothing here depends on WireGuard. The phone link is a FALLBACK path: its
# default route has a worse metric than wifi (3002), so it only carries traffic
# when wifi is down or absent.
#
# adb itself comes from android-tools (profiles/laptop.nix); device access for
# the logged-in seat user is covered by systemd's built-in uaccess rules.
{ config, lib, pkgs, ... }:
let
  app = "com.spencerharmon.sockstether";
  proxyPort = "1080";
  tunDev = "phone0";
  tunMetric = "4000";
  envFile = "/run/phone-socks/env";
  user = "spencer";

  # adb talks to the user's adb server (keys + device authorisation live in
  # the user's ~/.android), so run it as the user even though the unit is root.
  adb = "${pkgs.util-linux}/bin/runuser -u ${user} -- ${pkgs.coreutils}/bin/env HOME=/home/${user} ${pkgs.android-tools}/bin/adb";

  startApp = pkgs.writeShellScript "phone-socks-start-app" ''
    set -eu
    # The phone is the DHCP "router" of the USB link (dhcpcd is told not to
    # install that route, see nogateway below, but still records the option).
    ip=""
    for i in $(seq 1 90); do
      ip=$(${pkgs.dhcpcd}/sbin/dhcpcd -U "$PHONE_IFACE" 2>/dev/null | ${pkgs.gnused}/bin/sed -n "s/^routers=//p" | ${pkgs.coreutils}/bin/head -1 | ${pkgs.coreutils}/bin/tr -d "'\"" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      [ -n "$ip" ] && break
      sleep 1
    done
    [ -n "$ip" ] || { echo "phone-socks: no DHCP lease on $PHONE_IFACE" >&2; exit 1; }
    printf 'PHONE_IFACE=%s\nPHONE_IP=%s\n' "$PHONE_IFACE" "$ip" > ${envFile}
    . ${envFile}
    # Start the proxy foreground service on the phone, then wait until it is
    # actually accepting connections over the USB link.
    for i in $(seq 1 10); do
      ${adb} shell am start-foreground-service -n ${app}/.ProxyService >/dev/null 2>&1 && break
      sleep 1
    done
    for i in $(seq 1 20); do
      if (exec 3<>/dev/tcp/$PHONE_IP/${proxyPort}) 2>/dev/null; then exit 0; fi
      sleep 1
    done
    echo "phone-socks: proxy on $PHONE_IP:${proxyPort} never came up (is ${app} installed?)" >&2
    exit 1
  '';

  up = pkgs.writeShellScript "phone-socks-up" ''
    set -eu
    for i in $(seq 1 20); do
      ${pkgs.iproute2}/bin/ip link show ${tunDev} >/dev/null 2>&1 && break
      sleep 0.5
    done
    ${pkgs.iproute2}/bin/ip addr replace 198.18.0.1/15 dev ${tunDev}
    ${pkgs.iproute2}/bin/ip link set ${tunDev} up
    ${pkgs.iproute2}/bin/ip route replace default dev ${tunDev} metric ${tunMetric}
  '';

  run = pkgs.writeShellScript "phone-socks-run" ''
    . ${envFile}
    exec ${pkgs.tun2socks}/bin/tun2socks \
      -device tun://${tunDev} \
      -proxy socks5://$PHONE_IP:${proxyPort} \
      -interface "$PHONE_IFACE" \
      -loglevel warn
  '';

  stopApp = pkgs.writeShellScript "phone-socks-stop-app" ''
    ${pkgs.iproute2}/bin/ip route del default dev ${tunDev} metric ${tunMetric} 2>/dev/null || true
    ${adb} shell am start-foreground-service -n ${app}/.ProxyService -a ${app}.STOP >/dev/null 2>&1 || true
  '';
in
{
  # yoga sets networking.useDHCP = false and runs dhcpcd with an allowinterfaces
  # list holding just the wifi NIC, so a freshly appeared USB interface would
  # never get an address. Allow the names a USB RNDIS/CDC link takes
  # (enx<mac> or enp*u* path names, or legacy usb0).
  networking.dhcpcd.allowInterfaces = [ "enx*" "enp*u*" "usb*" ];

  # The phone offers itself as default gateway, but its tether bearer is the
  # blocked one: never install that route. (mkAfter: these `interface` blocks
  # must come after the global directives in systems/yoga, or its `noarp` /
  # `release no` would attach to the last block instead of being global.)
  networking.dhcpcd.extraConfig = lib.mkAfter ''
    interface enx*
    nogateway
    interface enp*u*
    nogateway
    interface usb*
    nogateway
  '';

  environment.systemPackages = [ pkgs.tun2socks ];

  # Replies reach phone0 with a public source address while the route back to
  # it may point at wifi (metric 3002 < 4000): strict reverse-path filtering
  # would drop them. Loose mode still rejects unroutable sources.
  networking.firewall.checkReversePath = "loose";

  # Start a proxy session whenever a USB ethernet-style device appears.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", DRIVERS=="rndis_host|cdc_ether|cdc_ncm", TAG+="systemd", ENV{SYSTEMD_WANTS}+="phone-socks@$name.service"
  '';

  systemd.services."phone-socks@" = {
    description = "Route via the phone's SOCKS5 proxy (Socks Tether over USB)";
    wants = [ "network.target" ];
    bindsTo = [ "sys-subsystem-net-devices-%i.device" ];
    after = [ "sys-subsystem-net-devices-%i.device" "dhcpcd.service" ];
    environment.PHONE_IFACE = "%i";
    unitConfig = {
      StartLimitIntervalSec = 300;
      StartLimitBurst = 5;
    };
    serviceConfig = {
      Type = "simple";
      RuntimeDirectory = "phone-socks";
      ExecStartPre = startApp;
      ExecStart = run;
      ExecStartPost = up;
      ExecStopPost = "-${stopApp}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
