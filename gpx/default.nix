{ config, pkgs, lib, ... }:

let
  gpxpy = pkgs.python3Packages.buildPythonPackage {
    pname = "gpxpy";
    version = "1.3.4";

    src = pkgs.fetchFromGitHub {
      owner = "tkrajina";
      repo = "gpxpy";
      rev = "6dfc6f567aa42e3d31d463f284b743582594964d";
      sha256 = "1770611vvqwc77cdq53bb4v0cmwizcfj4rhafimp425jhcdlpa25";
    };
  };

  srtm = pkgs.python3Packages.buildPythonPackage {
    pname = "srtm";
    version = "0.3.4";

    src = pkgs.fetchFromGitHub {
      owner = "tkrajina";
      repo = "srtm.py";
      rev = "37fb8a6f52c8ca25565772e59e867ac26181f829";
      sha256 = "093czbkd8wmqa1qcb71kbfkfrv1frrv0xjszci32gbbxdlq1f25l";
    };

    propagatedBuildInputs = [ pkgs.python3Packages.requests gpxpy ];
    doCheck = false; # Tests need network access.
  };

in {
  config = lib.mkIf config.nextcloud.apps.gpxpod.enable {
    nextcloud.extraPostPatch = ''
      sed -i \
        -e 's!\<bash\>!${pkgs.stdenv.shell}!' \
        -e 's!getProgramPath('\'''gpxelevations'\''')!${
          "'\\''${srtm}/bin/gpxelevations'\\''"
        }!' apps/gpxpod/controller/pagecontroller.php
    '';
  };
}
