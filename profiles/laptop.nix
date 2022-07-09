{ pkgs, lib, ... }: {
  imports = [
    ./common.nix
  ];
  sound.enable = true;
  hardware.pulseaudio.enable = true;

  hardware.trackpoint.enable = lib.mkDefault true;
  hardware.trackpoint.emulateWheel = lib.mkDefault config.hardware.trackpoint.enable;
  services = {
    xserver = {
      enable = true;
      windowManager.session = lib.singleton {
        name = "exwm";
        start = ''
          xhost +SI:localuser:$USER
          exec emacs --fullscreen
        '';
      };
      displayManager = {
        defaultSession = "none+exwm";
        lightdm = {
          enable  = true;
          greeter.enable = false;
          autoLogin = {
            enable = true;
            user = "spencer";
          };
        };
      };
    };
  };
  environment = {
    systemPackages = with pkgs; [
      firefox-bin
      emacs
      pkgs.xorg.xhost
    ];
  };
}
