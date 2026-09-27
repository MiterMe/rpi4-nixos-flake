{
  description = "NixOS configuration for Raspberry Pi 4";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = { self, nixpkgs, nixos-hardware, ... }:
    let
      # Machine configuration shared by image build and deployed system
      machineModules = [
        nixos-hardware.nixosModules.raspberry-pi-4
        ./configuration.nix
        ./base-cleanup.nix
      ];

      # Embed the config files into /etc/nixos so the Pi can rebuild itself
      embedConfigModule = { lib, ... }: {
        nix.settings.experimental-features = [ "nix-command" "flakes" ];

        environment.etc = {
          "nixos/flake.nix" = {
            source = ./flake.nix;
            mode = "0644";
          };
          "nixos/flake.lock" = {
            source = ./flake.lock;
            mode = "0644";
          };
          "nixos/configuration.nix" = {
            source = ./configuration.nix;
            mode = "0644";
          };
          "nixos/base-cleanup.nix" = {
            source = ./base-cleanup.nix;
            mode = "0644";
          };
          "nixos/sd-image.nix" = lib.mkIf (builtins.pathExists ./sd-image.nix) {
            source = ./sd-image.nix;
            mode = "0644";
          };
        };
      };
    in
    {
      nixosConfigurations = {
        # Configuration for building the SD image
        rpi4-sdimage = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = machineModules ++ [
            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
            ./sd-image.nix
            embedConfigModule
          ];
        };

        # Configuration for deploying to a running system
        rpi4 = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = machineModules ++ [
            embedConfigModule
          ];
        };
      };

      packages.aarch64-linux = rec {
        sdImage = self.nixosConfigurations.rpi4-sdimage.config.system.build.sdImage;
        default = sdImage;
      };
    };
}
