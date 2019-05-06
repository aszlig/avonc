{ pkgs ? import <nixpkgs> {}, lib ? pkgs.lib }:

let
  # FIXME: Downgrade Rebar3 to version 3.6.1 to be backwards-compatible until
  #        we have a better way to pin our dependencies.
  beamPackages = pkgs.beam.packages.erlang.extend (self: super: {
    rebar3 = let
      erlware_commons = self.fetchHex {
        pkg = "erlware_commons";
        version = "1.2.0";
        sha256 = "149kkn9gc9cjgvlmakygq475r63q2rry31s29ax0s425dh37sfl7";
      };
      ssl_verify_fun = self.fetchHex {
        pkg = "ssl_verify_fun";
        version = "1.1.3";
        sha256 = "1zljxashfhqmiscmf298vhr880ppwbgi2rl3nbnyvsfn0mjhw4if";
      };
      certifi = self.fetchHex {
        pkg = "certifi";
        version = "2.0.0";
        sha256 = "075v7cvny52jbhnskchd3fp68fxgp7qfvdls0haamcycxrn0dipx";
      };
      providers = self.fetchHex {
        pkg = "providers";
        version = "1.7.0";
        sha256 = "19p4rbsdx9lm2ihgvlhxyld1q76kxpd7qwyqxxsgmhl5r8ln3rlb";
      };
      getopt = self.fetchHex {
        pkg = "getopt";
        version = "1.0.1";
        sha256 = "174mb46c2qd1f4a7507fng4vvscjh1ds7rykfab5rdnfp61spqak";
      };
      bbmustache = self.fetchHex {
        pkg = "bbmustache";
        version = "1.5.0";
        sha256 = "0xg3r4lxhqifrv32nm55b4zmkflacc1s964g15p6y6jfx6v4y1zd";
      };
      relx = self.fetchHex {
        pkg = "relx";
        version = "3.26.0";
        sha256 = "1f810rb01kdidpa985s321ycg3y4hvqpzbk263n6i1bfnqykkvv9";
      };
      cf = self.fetchHex {
        pkg = "cf";
        version = "0.2.2";
        sha256 = "08cvy7skn5d2k4manlx5k3anqgjdvajjhc5jwxbaszxw34q3na28";
      };
      cth_readable = self.fetchHex {
        pkg = "cth_readable";
        version = "1.4.2";
        sha256 = "1pjid4f60pp81ds01rqa6ybksrnzqriw3aibilld1asn9iabxkav";
      };
      eunit_formatters = self.fetchHex {
        pkg = "eunit_formatters";
        version = "0.5.0";
        sha256 = "1jb3hzb216r29x2h4pcjwfmx1k81431rgh5v0mp4x5146hhvmj6n";
      };
      rebar3_hex = self.fetchHex {
        pkg = "rebar3_hex";
        version = "4.0.0";
        sha256 = "0k0ykx1lz62r03dpbi2zxsvrxgnr5hj67yky0hjrls09ynk4682v";
      };
    in super.rebar3.overrideAttrs (drv: rec {
      name = "rebar-${version}";
      version = "3.6.1";

      src = pkgs.fetchurl {
        url = "https://github.com/rebar/rebar3/archive/${version}.tar.gz";
        sha256 = "0cqhqymzh10pfyxqiy4hcg3d2myz3chx0y4m2ixmq8zk81acics0";
      };

      postPatch = (drv.postPatch or "") + ''
        rm -rf _build _checkouts
        mkdir -p _build/default/lib _build/default/plugins

        cp --no-preserve=mode -R ${erlware_commons} \
          _build/default/lib/erlware_commons
        cp --no-preserve=mode -R ${providers} _build/default/lib/providers
        cp --no-preserve=mode -R ${getopt} _build/default/lib/getopt
        cp --no-preserve=mode -R ${bbmustache} _build/default/lib/bbmustache
        cp --no-preserve=mode -R ${certifi} _build/default/lib/certifi
        cp --no-preserve=mode -R ${cf} _build/default/lib/cf
        cp --no-preserve=mode -R ${cth_readable} \
          _build/default/lib/cth_readable
        cp --no-preserve=mode -R ${eunit_formatters} \
          _build/default/lib/eunit_formatters
        cp --no-preserve=mode -R ${relx} _build/default/lib/relx
        cp --no-preserve=mode -R ${ssl_verify_fun} \
          _build/default/lib/ssl_verify_fun
        cp --no-preserve=mode -R ${rebar3_hex} \
          _build/default/plugins/rebar3_hex
      '';
    });
  });

  upstreamInfo = lib.importJSON ./upstream.json;

  rebarPlugins = lib.makeExtensible (self: {
    pc = beamPackages.buildRebar3 rec {
      name = "pc";
      version = "1.10.1";

      src = pkgs.fetchFromGitHub {
        owner = "blt";
        repo = "port_compiler";
        rev = "v${version}";
        sha256 = "0bs3h3aw87kmxsxxkc42jig6n2q6p41xrmiw04ly24w8rakcn5ch";
      };
    };
    provider_asn1 = beamPackages.buildRebar3 {
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
    rebar_erl_vsn = beamPackages.buildHex {
      name = "rebar_erl_vsn";
      version = "0.2.2";
      sha256 = "167fy44gn4z2rw6ry8llpyvdg586f9sy702pfpr29jqk1farai7s";
    };
    rebar3_elixir = beamPackages.buildHex {
      name = "rebar3_elixir";
      version = "0.2.4";
      sha256 = "0n1zq355pfamy3l6sd0aynd1pqcb4qaiqjhzf5dfjajfamp833pb";
      buildPlugins = [ self.rebar3_hex ];
    };
    rebar3_hex = beamPackages.buildHex {
      name = "rebar3_hex";
      version = "6.4.0";
      sha256 = "1rv1af5hn0zcw7fcmnlbns86w05jsj4ikknrj6qrngpr6lwkfs8z";
    };
    rebar3_proper = beamPackages.buildHex {
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
      } else if fetchtype == "hex" then beamPackages.fetchHex {
        pkg = attrs.src.name;
        inherit (attrs) version sha256;
      } else throw "Unknown fetchtype '${fetchtype}' for package '${name}'.";
    };

  in beamPackages.buildRebar3 {
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
  patchedRebar3 = beamPackages.rebar3.overrideAttrs (drv: {
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
    ${pkgs.erlang}/bin/escript ${beamPackages.rebar3.bootstrapper}
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
