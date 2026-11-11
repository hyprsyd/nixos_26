{ pkgs, ... }:

{
  networking.hostId = "0741db13";

  boot = {
    supportedFilesystems = [ "zfs" ];
    zfs = {
      forceImportRoot = false;
      extraPools = [ "backup" ];
      devNodes = "/dev/disk/by-id";
      # package = pkgs.zfs_2_4;
      # package = pkgs.zfs_unstable;
    };

    # Safest for ZFS: drop _latest and use the NixOS default LTS kernel.
    # Comment this out only if you have confirmed latest + boot.zfs.package builds.
    # kernelPackages = pkgs.linuxPackages;
  };

  fileSystems."/backup" = {
    device = "backup/db";
    fsType = "zfs";
  };

  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";
    pools = [ "backup" ];
  };

  services.smartd.enable = true;

  environment.systemPackages = with pkgs; [
    zfs
    smartmontools
  ];
}
