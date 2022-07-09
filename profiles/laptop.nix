{ pkgs, lib, ... }: {
  imports = [
    ./common.nix
  ];
  sound.enable = true;
  hardware.pulseaudio.enable = true;

  services = {
    xserver = {
      enable = true;
      windowManager.session = lib.singleton {
        name = "exwm";
        start = ''
          xhost +SI:localuser:$USER
          exec emacs
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
