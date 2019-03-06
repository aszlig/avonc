{ pkgs ? import <nixpkgs> {}, lib ? pkgs.lib }:

let
  upstreamInfo = lib.importJSON ./upstream.json;

  rebarPlugins = lib.makeExtensible (self: {
    pc = pkgs.beamPackages.buildRebar3 rec {
      name = "pc";
      version = "1.10.1";

      src = pkgs.fetchFromGitHub {
        owner = "blt";
        repo = "port_compiler";
        rev = "v${version}";
        sha256 = "0bs3h3aw87kmxsxxkc42jig6n2q6p41xrmiw04ly24w8rakcn5ch";
      };
    };
    provider_asn1 = pkgs.beamPackages.buildRebar3 {
      name = "provider_asn1";
      version = "0.2.0";

      src = pkgs.fetchFromGitHub {
        owner = "knusbaum";
        repo = "provider_asn1";
        rev = "29f78502dabd6f037af298579adbc60a079b6384";
        sha256 = "1xl2k40pzfx73kwd7ddwg8ljzwh74vb0ssbwp11v8rdmycdz5a1z";
      };

      buildPlugins = [ self.rebar3_hex ];
    };
    rebar_erl_vsn = pkgs.beamPackages.buildHex {
      name = "rebar_erl_vsn";
      version = "0.2.2";
      sha256 = "167fy44gn4z2rw6ry8llpyvdg586f9sy702pfpr29jqk1farai7s";
    };
    rebar3_elixir = pkgs.beamPackages.buildHex {
      name = "rebar3_elixir";
      version = "0.2.4";
      sha256 = "0n1zq355pfamy3l6sd0aynd1pqcb4qaiqjhzf5dfjajfamp833pb";
      buildPlugins = [ self.rebar3_hex ];
    };
    rebar3_hex = pkgs.beamPackages.buildHex {
      name = "rebar3_hex";
      version = "6.4.0";
      sha256 = "1rv1af5hn0zcw7fcmnlbns86w05jsj4ikknrj6qrngpr6lwkfs8z";
    };
    rebar3_proper = pkgs.beamPackages.buildHex {
      name = "rebar3_proper";
      version = "0.11.1";
      sha256 = "1xyc39gg5d842kzyn6bif6lkc7i4nn81mih8r8l57cijm85y5nxf";
    };
  });

  jailbreakSource = { name, src }: pkgs.stdenvNoCC.mkDerivation {
    name = "${name}-src-jailbroken";
    inherit src;
    phases = [ "unpackPhase" "patchPhase" "installPhase" ];
    prePatch = ''
      ${pkgs.erlang}/bin/escript ${tools/jailbreak.erl}
      rm -f rebar.lock
    '';
    installPhase = "cp -r . \"$out\"";
  };

  buildDep = self: name: attrs: let
    inherit (attrs.src) fetchtype;
    inherit (attrs) version;

    src = jailbreakSource {
      name = "${name}-${version}";
      src = if fetchtype == "github" then pkgs.fetchFromGitHub {
        inherit (attrs.src) repo owner rev;
        inherit (attrs) sha256;
      } else if fetchtype == "hex" then pkgs.beamPackages.fetchHex {
        pkg = attrs.src.name;
        inherit (attrs) version sha256;
      } else throw "Unknown fetchtype '${fetchtype}' for package '${name}'.";
    };

  in pkgs.beamPackages.buildRebar3 {
    inherit name version src;

    buildPlugins = lib.filter lib.isDerivation (lib.attrValues rebarPlugins);
    beamDeps = map (name: self.${name}) attrs.subdeps;
    inherit (attrs) level;

    postConfigure = ''
      ${pkgs.erlang}/bin/escript ${tools/fix-registry.erl}
    '';
  };

  depsBase = let
    mkRoot = self: lib.mapAttrs (buildDep self) upstreamInfo.dependencies;
  in lib.makeExtensible mkRoot;

  # Dependencies with various overrides.
  deps = depsBase.extend (self: super: {
    eodbc = super.eodbc.overrideAttrs (drv: {
      buildInputs = (drv.buildInputs or []) ++ [ pkgs.unixODBC ];
    });
    riakc = super.riakc.overrideAttrs (drv: {
      postPatch = (drv.postPatch or "") + ''
        sed -i -e 's/warnings_as_errors,//' rebar.config
      '';
    });
    re2 = super.re2.overrideAttrs (drv: {
      buildInputs = (drv.buildInputs or []) ++ [ pkgs.re2 ];
      SYSTEM_RE2 = true;
      postPatch = (drv.postPatch or "") + ''
        sed -i -e 's!/usr/include!${pkgs.re2}/include!' \
               -e 's!/usr/lib!${pkgs.re2}/lib!' \
               rebar.config.script
      '';
    });
  });

  isTopLevel = attrs: attrs.level or 1 == 0;
  topLevelDeps = lib.filterAttrs (lib.const isTopLevel) deps;

  # Relx doesn't like it if the source directories are from store paths, where
  # files have a mode of 0444. So we patch it here, so a chmod -R +w is made
  # before attempting to modify some of these files.
  patchedRebar3 = pkgs.rebar3.overrideDerivation (drv: {
    postPatch = (drv.postPatch or "") + ''
      if [ -e _build/default/lib ]; then
        depdir=_build/default/lib
      else
        depdir=_checkouts
      fi
      patch -p1 -d "$depdir/relx" < ${patches/relx-copy.patch}
    '';
  });

in pkgs.stdenv.mkDerivation {
  name = "mongooseim-${upstreamInfo.mongooseim.version}";
  inherit (upstreamInfo.mongooseim) version;

  src = jailbreakSource {
    name = "mongooseim-${upstreamInfo.mongooseim.version}";
    src = pkgs.fetchFromGitHub {
      owner = "esl";
      repo = "MongooseIM";
      rev = upstreamInfo.mongooseim.version;
      inherit (upstreamInfo.mongooseim) sha256;
    };
  };

  setupHook = pkgs.writeText "setupHook.sh" ''
    addToSearchPath ERL_LIBS "$1/lib/erlang/lib/"
  '';

  patches = [
    patches/configure-paths.patch
    patches/logging-stdio.patch
    patches/set-config-at-runtime.patch
    patches/nodetool-setcookie.patch
  ];

  postPatch = ''
    cat ${./ejabberd_auth_nextcloud.erl} > src/auth/ejabberd_auth_nextcloud.erl
    substituteInPlace rel/files/mongooseim --replace '`whoami`' mongooseim
    substituteInPlace rel/files/mongooseimctl --replace '`whoami`' mongooseim
  '';

  configurePhase = ''
    patchShebangs tools
    ${pkgs.erlang}/bin/escript ${pkgs.rebar3.bootstrapper}
    ${pkgs.erlang}/bin/escript ${tools/fix-registry.erl}
    tools/configure system with-pgsql prefix="$out" user=mongooseim
  '';

  buildPhase = ''
    (source configure.out && HOME=. rebar3 as prod compile)
  '';

  nativeBuildInputs = [
    patchedRebar3 pkgs.erlang pkgs.openssl pkgs.makeWrapper
  ];
  buildInputs = [ pkgs.zlib ] ++ lib.attrValues topLevelDeps;

  buildPlugins = [
    rebarPlugins.pc
    rebarPlugins.provider_asn1
    rebarPlugins.rebar3_elixir
    rebarPlugins.rebar3_hex
  ];

  ctlBinPath = lib.makeSearchPath "bin" [
    pkgs.gawk pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.procps
  ];

  installPhase = ''
    sed -i -e '/^export RUNNER_USER/d' configure.out
    HOME=. make REBAR=rebar3 install
    cp -t "$out/lib/mongooseim/priv" priv/pg.sql
    sed -i -e '/logger/d' "$out/bin/mongooseimctl"
    wrapProgram "$out/bin/mongooseimctl" --set PATH "$ctlBinPath"
  '';
}
