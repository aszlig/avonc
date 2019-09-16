{ nixpkgs ? <nixpkgs>
, pkgs ? import nixpkgs { inherit system; }
, system ? builtins.currentSystem
, lib ? pkgs.lib
}:

{
  manual = import ./manual.nix { inherit pkgs lib; };
  tests = let
    callTest = fn: args: import fn ({
      inherit system pkgs lib;
    } // args);
  in {
    urls = callTest tests/urls.nix {};
    upgrade = callTest tests/upgrade.nix {};
  };
}
