{
  description = "Aszlig's Very Opinionated Nextcloud Configuration";

  inputs.nixpkgs-old = {
    url = "nixpkgs/f7165b2ad610a3b19dee81ae8b431873ffd4d702";
    flake = false;
  };

  inputs.nixpkgs.url = "nixpkgs/nixos-20.03";
  inputs.nixpkgs-webdriver.url = "nixpkgs/nixos-20.09";

  outputs = { self, nixpkgs-old, nixpkgs, nixpkgs-webdriver }: let
    inherit (nixpkgs) lib;
    systems = [ "x86_64-linux" ];
  in {
    overlay = final: prev: {
      libreoffice-online = import libreoffice-online/package.nix {
        pkgs = import nixpkgs-old { inherit (final) system; };
        inherit lib;
      };
    };

    packages = lib.genAttrs systems (system: {
      manual = import ./manual.nix {
        inherit nixpkgs;
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (lib.nixosSystem {
          inherit system;
          modules = [ self.nixosModules.nextcloud ];
          check = false;
        }) options;
      };
    });

    nixosModules.nextcloud = {
      imports = [
        modules/nextcloud.nix
        modules/redis.nix

        ./libreoffice-online
        ./gpx
        ./talk
        ./osrm
      ];

      nixpkgs.overlays = [ self.overlay ];
    };

    checks = lib.genAttrs systems (system: let
      callTest = fn: args: import fn ({
        inherit system nixpkgs lib;
        mainModule = self.nixosModules.nextcloud;
      } // args);
    in {
      talk = callTest tests/talk {
        inherit (nixpkgs-webdriver.legacyPackages.${system})
          geckodriver firefox-unwrapped;
      };
      urls = callTest tests/urls.nix {};
      upgrade = callTest tests/upgrade.nix {};
    });

    hydraJobs = {
      tests = self.checks.x86_64-linux;
      manual = self.packages.x86_64-linux.manual;
    };
  };
}
