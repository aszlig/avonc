testFun:

{ system ? builtins.currentSystem
, pkgs ? import <nixpkgs> { inherit system; config = {}; }
, lib ? pkgs.lib
, coverage ? false
, ...
} @ args:

let
  inherit (import "${toString pkgs.path}/nixos/lib/testing.nix" {
    inherit system pkgs;
  }) makeTest;

  # The original test attributes we need to override.
  testAttrs = if builtins.isFunction testFun then testFun (args // {
    inherit pkgs lib;
  }) else testFun;

  nodesOrig = testAttrs.nodes or (if testAttrs ? machine then {
    inherit (testAttrs) machine;
  } else {});

  baseConfig = {
  };

in makeTest (removeAttrs testAttrs [ "machine" ] // {
  nodes = lib.mapAttrs (name: nodeCfg: {
    imports = [ nodeCfg ../. ../postgresql.nix ];
    networking.firewall.enable = false;
  }) nodesOrig;
})
