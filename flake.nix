{
  description = "workstation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    antigravity-nix = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Keep claude-code on its own nixpkgs lock so hashes match claude-code.cachix.org
    claude-code = {
      url = "github:sadjow/claude-code-nix";
    };
  };

  nixConfig = {
    extra-substituters = [
      "https://mirrors.ustc.edu.cn/nix-channels/store?priority=10"
      "https://mirror.iscas.ac.cn/nix-channels/store?priority=20"
      "https://mirror.sjtu.edu.cn/nix-channels/store?priority=25"
      "https://cache.nixos.org?priority=30"
      "https://nix-community.cachix.org?priority=40"
      "https://claude-code.cachix.org?priority=41"
    ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      antigravity-nix,
      zen-browser,
      claude-code,
      ...
    }:
    {
      nixosConfigurations.workstation = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          {
            nixpkgs.overlays = [ claude-code.overlays.default ];
          }
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.extraSpecialArgs = {
              inherit antigravity-nix zen-browser claude-code;
            };
            home-manager.users.sid = ./home.nix;
          }
        ];
      };
    };
}
