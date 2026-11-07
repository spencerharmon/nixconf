# USB tethering from an Android device (see M-x android-tether in
# home/spencer/.emacs). adb itself comes from android-tools in
# profiles/laptop.nix; device access for the logged-in seat user is covered by
# systemd's built-in uaccess rules, so no extra udev package is needed.
#
# The only system piece needed is DHCP: yoga sets networking.useDHCP = false
# and runs dhcpcd with an allowinterfaces list holding just the wifi NIC, so a
# freshly appeared USB tether interface would never get an address. Allow the
# names a USB RNDIS/CDC link takes (enx<mac> or enp*u* path names, or legacy
# usb0).
{ ... }:
{
  networking.dhcpcd.allowInterfaces = [ "enx*" "enp*u*" "usb*" ];
}
