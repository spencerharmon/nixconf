{ config, ... }:
{
  services.kubernetes.masterAddress = "chrome-kube.i.spencerharmon.net";
  services.certmgr.defaultRemote = "chrome-kube.i.spencerharmon.net:8888";
}
