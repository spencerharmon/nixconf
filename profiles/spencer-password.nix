{ config, ... }:
{
  # Yoga-family systems own /etc/passwd and /etc/shadow declaratively.
  # Needed for slock: slock validates against the user's Unix password
  # hash, and a locked shadow entry (`!`) makes slock fail with
  # "crypt: Invalid argument".
  users.mutableUsers = false;

  age.secrets.spencer-password-hash = {
    file = ../secrets/spencer-password-hash.age;
    mode = "0400";
    owner = "root";
  };

  users.users.spencer.hashedPasswordFile =
    config.age.secrets.spencer-password-hash.path;
}
