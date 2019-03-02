{ pkgs ? import <nixpkgs> { inherit system; }
, system ? builtins.currentSystem
}:

let
  inherit (pkgs) lib;

  overrides = {
    grunt-mocha = drv: {
      buildInputs = (drv.buildInputs or []) ++ [ pkgs.phantomjs2 ];
    };
    grunt-contrib-imagemin = drv: {
      preRebuild = (drv.preRebuild or "") + ''
        find -type f -exec sed -i -e '/new BinWrapper()/ {
          n
          /jpegtran/ {
            :l1; n; s!\.dest(.*)!.dest("'"${pkgs.libjpeg.bin}"'/bin")!; Tl1
          }
          /optipng/ {
            :l2; n; s!\.dest(.*)!.dest("'"${pkgs.optipng}"'/bin")!; Tl2
          }
          /gifsicle/ {
            :l3; n; s!\.dest(.*)!.dest("'"${pkgs.gifsicle}"'/bin")!; Tl3
          }
        }' {} +
      '';
    };
  };

  mkNode = path: let
    nodePkgs = lib.attrValues (import path { inherit pkgs system; });
    applyOverrides = pkg: let
      inherit (pkg) packageName;
      overridden = pkg.overrideAttrs overrides.${packageName};
    in if overrides ? ${packageName} then overridden else pkg;
  in rec {
    pkgsList = map applyOverrides nodePkgs;
    env = pkgs.buildEnv {
      name = "node-packages-combined";
      paths = pkgsList;
      pathsToLink = [ "/lib/node_modules" ];
    };
    copyEnv = pkgs.runCommand "node-packages-copy-combined" {
      paths = map (pkg: "${pkg}/lib/node_modules") pkgsList;
    } ''
      mkdir -p "$out/lib/node_modules"
      find $paths -mindepth 1 -maxdepth 1 \
        -exec cp --no-preserve=mode -rt "$out/lib/node_modules" {} +
      find "$out/lib/node_modules" -path '*/.bin/*' -exec chmod +x {} +
    '';
  };

in {
  sdkjs = mkNode ./sdkjs;
  webapps = mkNode ./webapps;

  server = mkNode ./server;
  server-common = mkNode ./server-common;
  server-docservice = mkNode ./server-docservice;
  server-fileconverter = mkNode ./server-fileconverter;
  server-metrics = mkNode ./server-metrics;
  server-spellchecker = mkNode ./server-spellchecker;
}
