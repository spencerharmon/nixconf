{ pkgs, lib, ... }: {
  sound.enable = true;
  hardware.pulseaudio.enable = true;

  services.xserver.enable = true;
  services.xserver.windowManager.session = lib.singleton {
    name = "exwm";
    start = ''
      xhost +SI:localuser:$USER
      exec emacs
    '';
  };
  services.xserver.displayManager.lightdm.enable  = true;
  services.xserver.displayManager.lightdm.greeters.tiny.enable = true;
  services.xserver.displayManager.defaultSession = "none+exwm";
  environment = {
    systemPackages = with pkgs; [
      firefox-bin
      emacs
      pkgs.xorg.xhost
    ];
  };
}
