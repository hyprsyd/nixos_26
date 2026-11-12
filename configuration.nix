{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
  ];

  system.stateVersion = "26.05";

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
        Experimental = true; # Enables enhanced A2DP codecs (AAC/SBC-XQ) and battery status
        FastConnectable = true;
      };
    };
  };
  nixpkgs.config.allowUnfree = true;
  nix.settings = {
    max-jobs = "auto";
    cores = 0;
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    http-connections = 50;
    max-substitution-jobs = 32;
    download-buffer-size = 67108864;
    connect-timeout = 5;
    substituters = [
      "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
      "https://cache.nixos.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    kernelPackages = pkgs.linuxPackages; # Default LTS kernel (always supported by OpenZFS)
    kernelParams = [ "btusb.enable_autosuspend=0" ];
    supportedFilesystems = [ "zfs" ];
    zfs = {
      forceImportRoot = false;
      devNodes = "/dev/disk/by-partuuid"; # Ensures reliable boot import across identical SATA SSDs
    };
  };

  networking = {
    hostName = "workstation";
    hostId = "8425e349"; # Required by ZFS to identify this machine's pool
    networkmanager.enable = true;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };

  time.timeZone = "Asia/Calcutta";

  users = {
    defaultUserShell = pkgs.zsh;
    users.sid = {
      isNormalUser = true;
      extraGroups = [
        "networkmanager"
        "docker"
        "wheel"
        "video"
      ];
      shell = pkgs.zsh;
    };
  };

  programs = {
    appimage = {
      enable = true;
      binfmt = true;
      package = pkgs.appimage-run.override {
        extraPkgs = pkgs: [
          pkgs.freetype
        ];
      };
    };
    hyprland.enable = true;
    hyprlock.enable = true;
    seahorse.enable = true;
    nix-ld = {
      enable = true;
      libraries = with pkgs; [ stdenv.cc.cc ];
    };
    # Login shell only. Prompt, aliases, and plugins live in home.nix.
    zsh.enable = true;
    mtr.enable = true;
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
      pinentryPackage = pkgs.pinentry-gnome3;
      settings = {
        default-cache-ttl = 1800;
        max-cache-ttl = 7200;
        allow-loopback-pinentry = "";
      };
    };
  };

  environment = {
    sessionVariables.NIXOS_OZONE_WL = "1";
    systemPackages = with pkgs; [
      openssl
      gtk3
      gtkmm3
      gsettings-qt
      glib
      polkit_gnome
      tailscale
      gnupg
      pinentry-gnome3
      gcr_4
      libsecret
      gnome-keyring
      zsh
      rtkit
    ];
  };

  fonts.packages = with pkgs; [ meslo-lgs-nf ];
  virtualisation.docker.enable = true;

  security = {
    rtkit.enable = true; # Required for PipeWire audio threads to get realtime priority
    polkit.enable = true;
    pam.services = {
      ly.enableGnomeKeyring = true;
      login.enableGnomeKeyring = true;
    };
    sudo.wheelNeedsPassword = false;
  };
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 16 * 1024; # 16 GiB
    }
  ];

  boot.zswap = {
    enable = true;
    compressor = "zstd";
    maxPoolPercent = 25;
  };

  services = {
    zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };
    blueman.enable = true;
    postgresql = {
      enable = true;
      ensureDatabases = [ "mydatabase" ];
      authentication = pkgs.lib.mkOverride 10 ''
        #type database  DBuser  auth-method
        local all       all     trust
      '';
    };
    dbus.packages = [
      pkgs.gcr_4
      pkgs.gnome-keyring
    ];
    tailscale.enable = true;
    printing.enable = true;
    openssh.enable = true;
    gnome.gnome-keyring.enable = true;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      wireplumber.enable = true; # Manages Bluetooth SPA endpoints and codec switching
    };
    displayManager.ly = {
      enable = true;
      x11Support = false;
      settings = {
        animation = "matrix";
        clock = "%a %d %b %H:%M";
        default_input = "login";
        load = true;
        save = true;
        clear_password = true;
      };
    };
    xserver.xkb = {
      layout = "us";
      options = "eurosign:e,caps:escape";
    };
  };
}
