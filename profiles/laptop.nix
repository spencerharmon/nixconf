{ config, pkgs, lib, ... }: {
  imports = [
    ./common.nix
  ];
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    pulse.enable = true;
    alsa.enable = true;
  };

  boot.kernelParams = [ "psmouse.elantech_smbus=0" ];

  # libinput for touchpad. naturalScrolling matches yoga's previous
  # behaviour (set in the lost yoga-local nixconf checkout).
  services.libinput = {
    enable = true;
    touchpad.naturalScrolling = true;
  };
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
      displayManager.lightdm = {
        enable  = true;
        greeter.enable = false;
      };
    };
    displayManager = {
      defaultSession = "none+exwm";
      autoLogin = {
        enable = true;
        user = "spencer";
      };
    };
  };
  programs.slock.enable = true;
  environment = {
    systemPackages = with pkgs; [
      unzip
      python3
      python3Packages.autopep8
      firefox-bin
      emacs
      pkgs.xhost
      aspell
      aspellDicts.en
      yamllint
      noto-fonts-color-emoji
      gnumake
      gcc
      pkg-config
      android-tools
    ];
  };
}
