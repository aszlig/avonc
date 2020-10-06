testFun:

{ system ? builtins.currentSystem
, nixpkgs ? <nixpkgs>
, mainModule ? ../modules/nextcloud.nix
, pkgs ? import nixpkgs { inherit system; config = {}; }
, lib ? pkgs.lib
, coverage ? false
, ...
} @ args:

let
  inherit (import "${nixpkgs}/nixos/lib/testing.nix" {
    inherit system pkgs;
  }) makeTest;

  # The original test attributes we need to override.
  testAttrs = if builtins.isFunction testFun then testFun (args // {
    inherit pkgs lib;
  }) else testFun;

  nodesOrig = testAttrs.nodes or (if testAttrs ? machine then {
    inherit (testAttrs) machine;
  } else {});

in makeTest (removeAttrs testAttrs [ "machine" ] // {
  nodes = lib.mapAttrs (name: nodeCfg: {
    imports = [ nodeCfg mainModule ../postgresql.nix ];
    networking.firewall.enable = false;
    nextcloud.enable = let
      hasOnlyOneNode = lib.length (lib.attrNames nodesOrig) == 1;
    in lib.mkDefault hasOnlyOneNode;
  }) nodesOrig;
})
