{ pkgs, ... }: {
  sound.enable = true;
  hardware.pulseaudio.enable = true;

  services.xserver.enable = true;
  services.xserver.windowManager.exwm.enable = true;
  services.xserver.displayManager.lightdm.enable  = true;
  services.xserver.displayManager.lightdm.greeters.tiny.enable = true;
  services.xserver.displayManager.defaultSession = "none+exwm";
  environment = {
    systemPackages = with pkgs; [
      firefox
      emacs
    ];
  };
}
