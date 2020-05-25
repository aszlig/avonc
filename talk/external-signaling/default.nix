{ config, lib, pkgs, ... }:

let
  cfg = config.nextcloud.apps.spreed;

  signalingConfig = pkgs.writeText "signaling.conf" (lib.generators.toINI {} {
    backend.timeout = 10;
    backend.connectionsperhost = 8;

    nats.url = ":loopback:";

    mcu.type = "janus";
    mcu.url = "ws://127.0.0.1:8188";
  });

  janusConfig = {
    transport.websockets = {
      general = {
        json = "indented";
        ws = true;
        ws_port = 8188;
        wss = false;
      };
    };
    plugin.videoroom.general = {};
  };

  sfuConfig = pkgs.writeText "janus.cfg" (lib.generators.toINI {} {
    nat.full_trickle = true;
  });

  janusConfigDir = let
    writeConfig = cat: item: attrs: let
      data = lib.escapeShellArg (lib.generators.toINI {} attrs);
      filename = lib.escapeShellArg "janus.${cat}.${item}.cfg";
    in "echo -n ${data} > \"$out/\"${filename}";

    mkConfig = lib.mapAttrsToList (cat: lib.mapAttrsToList (writeConfig cat));
    cmds = lib.concatStringsSep "\n" (lib.concatLists (mkConfig janusConfig));
  in pkgs.runCommand "janus-configs" {} "mkdir \"$out\"\n${cmds}\n";

  usrsctp = pkgs.stdenv.mkDerivation {
    pname = "usrsctp";
    version = "2020-05-20";

    src = pkgs.fetchFromGitHub {
      owner = "sctplab";
      repo = "usrsctp";
      rev = "79ce3f1e13cd1cb283871ec5a9f90cf4062d91d4";
      sha256 = "058zgpp4h9vkq5p2f9lhhgp0p8cbz552rxiiwbdfdg6fw1na21kf";
    };

    nativeBuildInputs = [ pkgs.meson pkgs.ninja ];
  };

  # XXX: Backwards-compatibility for NixOS 19.09
  meson52 = let
    isTooOld = lib.versionOlder pkgs.meson.version "0.52";

    newerNixpkgs = pkgs.fetchFromGitHub {
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "81b7dad9c5f742886a4ac9cbc64a3800177866cf";
      sha256 = "0hqck4n4dxfsyd101yzx5ff2ccngil6dbd0fvsgw47fph3c381bn";
    };
    mesonPath = "${newerNixpkgs}/pkgs/development/tools/build-managers/meson";

    newerMeson = pkgs.meson.overrideAttrs (drv: rec {
      version = "0.52.1";
      src = pkgs.python3Packages.fetchPypi {
        inherit (drv) pname;
        inherit version;
        sha256 = "02fnrk1fjf3yiix0ak0m9vgbpl4h97fafii5pmw7phmvnlv9fyan";
      };
      patches = [
        "${mesonPath}/allow-dirs-outside-of-prefix.patch"
        "${mesonPath}/gir-fallback-path.patch"
        (pkgs.runCommand "fix-rpath.patch" {
          src = "${mesonPath}/fix-rpath.patch";
          inherit (builtins) storeDir;
        } "substituteAll \"$src\" \"$out\"")
        (pkgs.fetchpatch {
          url = "https://github.com/mesonbuild/meson/commit/"
              + "972ede1d14fdf17fe5bb8fb99be220f9395c2392.patch";
          sha256 = "19bfsylhpy0b2xv3ks8ac9x3q6vvvyj1wjcy971v9d5f1455xhbb";
        })
      ];
    });
  in if isTooOld then newerMeson else pkgs.meson;

  libnice = pkgs.stdenv.mkDerivation rec {
    pname = "libnice";
    version = "0.1.17";

    src = pkgs.fetchurl {
      url = "https://nice.freedesktop.org/releases/${pname}-${version}.tar.gz";
      sha256 = "09lm0rxwvbr53svi3inaharlq96iwbs3s6957z69qp4bqpga0lhr";
    };

    nativeBuildInputs = [ meson52 pkgs.ninja pkgs.pkgconfig ];
    propagatedBuildInputs = [ pkgs.glib ];
    buildInputs = [
      pkgs.gnutls pkgs.gst_all_1.gstreamer pkgs.gst_all_1.gst-plugins-base
      pkgs.gupnp-igd
    ];

    mesonFlags = [ "-Dexamples=disabled" "-Dintrospection=disabled" ];
  };

  janus = pkgs.stdenv.mkDerivation rec {
    pname = "janus-gateway";
    version = "0.9.5";

    src = pkgs.fetchFromGitHub {
      owner = "meetecho";
      repo = pname;
      rev = "v${version}";
      sha256 = "1025c21mqndwvwsk04cz5bgyh6a7gj0wy3zq4q39nlha4zggc8v6";
    };

    nativeBuildInputs = [ pkgs.autoreconfHook pkgs.pkgconfig pkgs.gengetopt ];

    buildInputs = [
      pkgs.jansson pkgs.libconfig libnice pkgs.boringssl pkgs.srtp
      pkgs.libwebsockets pkgs.libuv usrsctp
    ];

    configureFlags = [
      "--enable-plugin-videoroom" "--enable-websockets"
      "--enable-data-channels"
      "--enable-boringssl=${lib.getDev pkgs.boringssl}"
      "--enable-dtls-settimeout"
    ];
  };

  signalingServer = pkgs.buildGoPackage rec {
    pname = "nextcloud-spreed-signaling";
    version = "2020-05-20";

    src = pkgs.fetchFromGitHub {
      repo = pname;
      owner = "strukturag";
      rev = "4447078bbb03824bc595a3820eb21fcdd663cd25";
      sha256 = "0q8lpmskqikbcqh63l9ngaslydvck6mp8i4d37qinyxnyvfd9762";
    };

    goPackagePath = "github.com/strukturag/${pname}";

    continentMapUpstream = pkgs.fetchurl {
      url = "https://pkgstore.datahub.io/JohnSnowLabs/"
          + "country-and-continent-codes-list/"
          + "country-and-continent-codes-list-csv_json/data/"
          + "c218eebbf2f8545f3db9051ac893d69c/"
          + "country-and-continent-codes-list-csv_json.json";
      sha256 = "0yv21nqb3wlsi3ymya0ixq1qy9w7v59y72y4r1cp5bxp4l6v0pf6";
    };

    nativeBuildInputs = [ pkgs.python3 ];

    patches = [ ./signaling-socket-activation.patch ];

    postPatch = ''
      sed -e '/^  data = subprocess/,/^  \])/c \${''
        \  import os \
        \  data = open(os.environ["continentMapUpstream"]).read()
      ''}' scripts/get_continent_map.py \
        | python3 - src/signaling/continentmap.go
    '';

    preBuild = ''
      export GOPATH="$NIX_BUILD_TOP/go/src/$goPackagePath:$GOPATH"
      ( cd "$NIX_BUILD_TOP/go/src/$goPackagePath"
        ${pkgs.easyjson}/bin/easyjson -all \
          src/signaling/api_signaling.go \
          src/signaling/api_backend.go \
          src/signaling/natsclient.go \
          src/signaling/room.go
      )
    '';

    extraSrcs = let
      mkGoDep = { goPackagePath, rev, sha256, ... }@attrs: let
        matchRepoOwner = builtins.match "github\\.com/([^/]+)/([^/]+)";
        matchResult = matchRepoOwner goPackagePath;
      in {
        inherit goPackagePath;
        src = if attrs ? url then pkgs.fetchgit {
          inherit (attrs) url;
          inherit rev sha256;
        } else pkgs.fetchFromGitHub {
          repo = lib.last matchResult;
          owner = lib.head matchResult;
          inherit rev sha256;
        };
      };
    in map mkGoDep [
      { goPackagePath = "github.com/dlintw/goconf";
        rev = "dcc070983490608a14480e3bf943bad464785df5";
        sha256 = "1fah0g4f1gpb9hqv80svp39ijamggimdsxsiw8w1bkj67mrhgcd7";
      }
      { goPackagePath = "github.com/gorilla/context";
        rev = "08b5f424b9271eedf6f9f0ce86cb9396ed337a42";
        sha256 = "03p4hn87vcmfih0p9w663qbx9lpsf7i7j3lc7yl7n84la3yz63m4";
      }
      { goPackagePath = "github.com/gorilla/mux";
        rev = "ac112f7d75a0714af1bd86ab17749b31f7809640";
        sha256 = "1fwn36y9zd8fh9rbdiq5gg69d9crp2hvbdziy1kf9hq65426pydk";
      }
      { goPackagePath = "github.com/gorilla/securecookie";
        rev = "e59506cc896acb7f7bf732d4fdf5e25f7ccd8983";
        sha256 = "16bqimpxs9vj5n59vm04y04v665l7jh0sddxn787pfafyxcmh410";
      }
      { goPackagePath = "github.com/gorilla/websocket";
        rev = "v1.4.2";
        sha256 = "0mkm9w6kjkrlzab5wh8p4qxkc0icqawjbvr01d2nk6ykylrln40s";
      }
      { goPackagePath = "github.com/mailru/easyjson";
        rev = "2f5df55504ebc322e4d52d34df6a1f5b503bf26d";
        sha256 = "0d9m8kyhbawa452vnwn255xxnh6pkp3im0d2310rw1k14nh3yh1p";
      }
      { goPackagePath = "github.com/nats-io/go-nats";
        rev = "d4ca4c8b588d5da9c2ac82d6e445ce4feaba18ba";
        sha256 = "0raaki95zbl5nnmkbyy77lpq8qsyr50kmsd7g2wvk1yfxar2c5ia";
      }
      { goPackagePath = "github.com/nats-io/nuid";
        rev = "3cf34f9fca4e88afa9da8eabd75e3326c9941b44";
        sha256 = "04yb56wvgn7caxqasfwpmz77a9n3w2hsb7ghdl729l7973v96ghl";
      }
      { goPackagePath = "github.com/notedit/janus-go";
        rev = "8e6e2c423c03884d938d84442d37d6f6f5294197";
        sha256 = "0glz2zxvblgyivim4658q193qhx83assyrxfvxjdz6341dv6bb38";
      }
      { goPackagePath = "github.com/oschwald/maxminddb-golang";
        rev = "1960b16a5147df3a4c61ac83b2f31cd8f811d609";
        sha256 = "09hyc457cp27nsia8akp8m2ymcxlnz9xq6xrw6f818k4g1rxfsqh";
      }
      { goPackagePath = "golang.org/x/net";
        url = "https://go.googlesource.com/net";
        rev = "f01ecb60fe3835d80d9a0b7b2bf24b228c89260e";
        sha256 = "0j992rd9mjbyqmn53b5g41x8x0i1q8723qy8138fj96brqis3xda";
      }
      { goPackagePath = "golang.org/x/sys";
        url = "https://go.googlesource.com/sys";
        rev = "ac767d655b305d4e9612f5f6e33120b9176c4ad4";
        sha256 = "1ds29n5lh4j21hmzxz7vk7hv1k6sixc7f0zsdc9xqdg0j7d212zm";
      }
      { goPackagePath = "github.com/coreos/go-systemd";
        rev = "v22.0.0";
        sha256 = "0p4sb2fxxm2j1xny2l4fkq4kwj74plvh600gih8nyniqzannhrdx";
      }
    ];
  };

in {
  config = lib.mkIf (config.nextcloud.enable && cfg.enable) {
    users.users.nextcloud-signaling = {
      description = "Nextcloud Talk Signaling User";
      group = "nextcloud-signaling";
    };
    users.groups.nextcloud-signaling = {};

    users.users.nextcloud-sfu = {
      description = "Nextcloud Talk SFU User";
      group = "nextcloud-sfu";
    };
    users.groups.nextcloud-sfu = {};

    nextcloud.extraPostPatch = ''
      patch -p1 -d apps/spreed < ${./spreed-use-unix-sockets.patch}
    '';

    nextcloud.apps.spreed.config = {
      signaling_servers = builtins.toJSON {
        servers = lib.singleton {
          server = let
            inherit (config.nextcloud) useSSL port;
            urlScheme = if useSSL then "wss" else "ws";
            maybePort = let
              needsExplicit = !lib.elem port [ 80 443 ];
            in lib.optionalString needsExplicit ":${toString port}";
          in "${urlScheme}://${config.nextcloud.domain}${maybePort}/signaling";
          verify = true;
        };
      };
    };

    services.nginx.virtualHosts.${config.nextcloud.domain} = {
      extraConfig = ''
        listen unix:/run/nextcloud-signaling/nextcloud.sock;
      '';
      locations = {
        "/signaling/spreed" = {
          proxyWebsockets = true;
          proxyPass = "http://unix:/run/nextcloud-signaling-external.sock:"
                    + "/spreed";
        };
      };
    };

    systemd.sockets.nextcloud-signaling-external = {
      description = "Nextcloud Talk Websocket";
      requiredBy = [ "nextcloud-signaling.service" ];
      wantedBy = [ "sockets.target" ];

      socketConfig = {
        Service = "nextcloud-signaling.service";
        ListenStream = "/run/nextcloud-signaling-external.sock";
        FileDescriptorName = "external";
        SocketUser = "root";
        SocketGroup = "nginx";
        SocketMode = "0660";
      };
    };

    systemd.sockets.nextcloud-signaling-internal = {
      description = "Nextcloud Talk Internal Signaling Socket";
      requiredBy = [ "nextcloud-signaling.service" ];
      wantedBy = [ "sockets.target" ];

      socketConfig = {
        Service = "nextcloud-signaling.service";
        ListenStream = "/run/nextcloud-signaling-internal.sock";
        FileDescriptorName = "internal";
        SocketUser = "root";
        SocketGroup = "nextcloud";
        SocketMode = "0660";
      };
    };

    systemd.services.nextcloud-signaling-internal-sockdir = {
      description = "Prepare Nextcloud Talk Signal Internal Socket Directory";

      requiredBy = [
        "nginx.service" "nextcloud.service" "nextcloud-signaling.service"
      ];
      before = [
        "nginx.service" "nextcloud.service" "nextcloud-signaling.service"
      ];

      unitConfig.ConditionPathExists = "!/run/nextcloud-signaling";

      serviceConfig.RuntimeDirectory = "nextcloud-signaling";
      serviceConfig.RuntimeDirectoryMode = "0710";
      serviceConfig.RuntimeDirectoryPreserve = true;
      serviceConfig.User = "nginx";
      serviceConfig.Group = "nextcloud-signaling";
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
      serviceConfig.Type = "oneshot";
    };

    systemd.services.nextcloud-signaling-secrets = {
      description = "Secrets for Nextcloud Talk Signaling Server";
      requiredBy = [ "nextcloud-signaling.service" ];
      before = [ "nextcloud-signaling.service" ];

      unitConfig = {
        ConditionPathExists = "!/var/lib/nextcloud-signaling/secrets.env";
      };

      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        RemainAfterExit = true;
        StateDirectory = "nextcloud-signaling";
        StateDirectoryMode = "0700";
        ExecStart = pkgs.writeScript "nextcloud-signaling-secrets-init.py" ''
          #!${pkgs.python3Packages.python.interpreter}
          from secrets import token_urlsafe
          data = 'NEXTCLOUD_SIGNALING_HASHKEY=' + token_urlsafe(64) + '\n'
          data += 'NEXTCLOUD_SIGNALING_BLOCKKEY=' + token_urlsafe(32) + '\n'
          open('/var/lib/nextcloud-signaling/secrets.env', 'w').write(data)
        '';
      };
    };

    systemd.services.nextcloud-signaling = {
      description = "Nextcloud Talk Signaling Server";
      wantedBy = [ "nextcloud.service" ];

      confinement.enable = true;
      confinement.mode = "chroot-only";

      serviceConfig = {
        ExecStart = "@${signalingServer}/bin/server nextcloud-signaling"
                  + " -config ${signalingConfig}";
        User = "nextcloud-signaling";
        Group = "nextcloud-signaling";
        BindReadOnlyPaths = [
          "/run/nextcloud-signaling"
          "/run/nextcloud-signaling-sfu.sock"
        ];
        EnvironmentFile = [ "/var/lib/nextcloud-signaling/secrets.env" ];
        PrivateNetwork = true;
      };
    };

    systemd.sockets.nextcloud-signaling-sfu = {
      description = "Nextcloud Talk SFU Socket";
      requiredBy = [ "nextcloud-signaling-sfu.service" ];
      wantedBy = [ "sockets.target" ];

      socketConfig = {
        ListenStream = "/run/nextcloud-signaling-sfu.sock";
        SocketUser = "root";
        SocketGroup = "nextcloud-signaling";
        SocketMode = "0660";
      };
    };

    systemd.services.nextcloud-signaling-sfu = {
      description = "Nextcloud Talk SFU";

      confinement.enable = true;
      confinement.binSh = null;

      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          "${pkgs.ip2unix}/bin/ip2unix" "-r" "in,port=8188,systemd"
          "${janus}/bin/janus" "-C" sfuConfig "-F" janusConfigDir
        ];
        User = "nextcloud-sfu";
        Group = "nextcloud-sfu";
      };
    };

    systemd.services.nextcloud.serviceConfig.BindReadOnlyPaths = [
      "/run/nextcloud-signaling" "/run/nextcloud-signaling-internal.sock"
    ];
  };
}
