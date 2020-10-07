let
  rev = "94cf59784c73ecec461eaa291918eff0bfb538ac";
  url = "https://github.com/edolstra/flake-compat/archive/${rev}.tar.gz";
  flake = import (fetchTarball url) { src = ./.; };
  inNixShell = builtins.getEnv "IN_NIX_SHELL" != "";
in if inNixShell then flake.shellNix else flake.defaultNix
