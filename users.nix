{ pkgs, ...}:
{
  security.sudo.wheelNeedsPassword = false;
  users.users.spencer = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
    openssh.authorizedKeys.keys = ["ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCn9OKV7IFctsv6pSeUXt1/UnQV/WEXqOAwRSW+NLpvXCR2LNRU+G5lNaEf5jNOUxwhI1q65DqGjLOFzdjUmRgtw6OOEjIw4ttUOJY1xNBBBXgeQF8NHlZaszZITb9uIGnL8hyLxPl+mt2p0DpCDA8QF6q20WLM0ulrcyR88w/K6r5bqXCdBE+6hVMDHkFOLj0oekOSscYEGI+JiaJzgKYVRw5nClK5tnk4o0ujwqkKrN24KMg4AFclXrMmrQwDXfBcbBcqQi6vt8EV47bz4oTh913Rpokqhg3D2y8Ua9brqK/xUJJh6sMf6cwJmY+eGF3aI1tuhvZiReKueCQE2bJ7 spencer@home-one"];    
  };
}
