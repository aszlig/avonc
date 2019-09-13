{ pkgs ? import <nixpkgs> {}, lib ? pkgs.lib, php ? pkgs.php }:

pkgs.python3Packages.buildPythonApplication {
  name = "avonc-updater";

  src = lib.cleanSourceWith {
    filter = path: type: let
      relPath = lib.removePrefix (toString ./. + "/") path;
      toplevelIncludes = [
        { type = "directory"; name = "updater"; }
        { type = "directory"; name = "stubs"; }
        { type = "regular"; name = "setup.py"; }
        { type = "regular"; name = "setup.cfg"; }
      ];
      isMatching = { type, name }: type == type && relPath == name;
      isToplevelInclude = lib.any isMatching toplevelIncludes;
    in builtins.match "[^/]+" relPath != null -> isToplevelInclude;
    src = lib.cleanSource ./.;
  };

  propagatedBuildInputs = [
    pkgs.python3Packages.defusedxml
    pkgs.python3Packages.pyopenssl
    pkgs.python3Packages.requests
    pkgs.python3Packages.semantic-version
    pkgs.python3Packages.tqdm
    pkgs.php
  ];

  checkInputs = [
    pkgs.python3Packages.mypy
    pkgs.python3Packages.pytest
    pkgs.python3Packages.pytest-mypy
    pkgs.python3Packages.pytest-flake8
    pkgs.python3Packages.pytestrunner
  ];
}
