{ config, lib, pkgs, ... }:

let
  cfg = config.nextcloud.apps.spreed;

  signalingConfig = pkgs.writeText "signaling.conf" (lib.generators.toINI {} {
    backend.backends = "default";
    backend.timeout = 10;
    backend.connectionsperhost = 8;

    default.url = "http://localhost";
    default.secret = "internal";

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
    version = "2021-03-29";

    src = pkgs.fetchFromGitHub {
      owner = "sctplab";
      repo = "usrsctp";
      rev = "70d42ae95a1de83bd317c8cc9503f894671d1392";
      sha256 = "0n5xm45csnwj9kk82saqlss406k1rynrl37zd8jhpv0rcl6cvnsr";
    };

    nativeBuildInputs = [ pkgs.meson pkgs.ninja ];
  };

  libnice = pkgs.stdenv.mkDerivation rec {
    pname = "libnice";
    version = "0.1.18";

    src = pkgs.fetchurl {
      url = "https://nice.freedesktop.org/releases/${pname}-${version}.tar.gz";
      sha256 = "1x3kj9b3dy9m2h6j96wgywfamas1j8k2ca43k5v82kmml9dx5asy";
    };

    nativeBuildInputs = [ pkgs.meson pkgs.ninja pkgs.pkgconfig ];
    propagatedBuildInputs = [ pkgs.glib ];
    buildInputs = [
      pkgs.gnutls pkgs.gst_all_1.gstreamer pkgs.gst_all_1.gst-plugins-base
      pkgs.gupnp-igd
    ];

    mesonFlags = [ "-Dexamples=disabled" "-Dintrospection=disabled" ];
  };

  janus = pkgs.stdenv.mkDerivation rec {
    pname = "janus-gateway";
    version = "0.11.1";

    src = pkgs.fetchFromGitHub {
      owner = "meetecho";
      repo = pname;
      rev = "v${version}";
      sha256 = "1dyvvw3mfn8n5prhyr9d7gbh8abgap0xvgk04vxr97jdm74g9js7";
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
    version = "0.2.0";

    src = pkgs.fetchFromGitHub {
      repo = pname;
      owner = "strukturag";
      rev = "v${version}";
      sha256 = "1fz4h520jbvndb96fpi78698lj0287a89hgql1ykcg5j8pzf5q45";
    };

    goPackagePath = "github.com/strukturag/${pname}";

    nativeBuildInputs = [ pkgs.python3 ];

    patches = [ ./signaling-socket-activation.patch ];

    preBuild = ''
      export GOPATH="$NIX_BUILD_TOP/go/src/$goPackagePath:$GOPATH"
      ( cd "$NIX_BUILD_TOP/go/src/$goPackagePath"
        ${pkgs.easyjson}/bin/easyjson -all \
          src/signaling/api_signaling.go \
          src/signaling/api_backend.go \
          src/signaling/api_proxy.go \
          src/signaling/natsclient.go \
          src/signaling/room.go
      )
    '';

    # All those dependencies are from "dependencies.tsv" in the source tree.
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
          repo = attrs.github.repo or (lib.last matchResult);
          owner = attrs.github.owner or (lib.head matchResult);
          inherit rev sha256;
        };
      };
    in map mkGoDep [
      { goPackagePath = "github.com/dlintw/goconf";
        rev = "dcc070983490608a14480e3bf943bad464785df5";
        sha256 = "1fah0g4f1gpb9hqv80svp39ijamggimdsxsiw8w1bkj67mrhgcd7";
      }
      { goPackagePath = "github.com/google/uuid";
        rev = "0e4e31197428a347842d152773b4cace4645ca25";
        sha256 = "1rbpfa0v0ly9sdnixcxhf79swki54ikgm1zkwwkj64p1ws66syqd";
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
        # Using newer version here, because we need NetDialContext for our
        # patch.
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
        rev = "10eb8b95d1a0469ac8921c5ce5fb55b4c0d3ad7d";
        sha256 = "0ng184pp2bhrdd3ak4qp2cnj2y3zch90l2jvd3x5gspy5w6vmszn";
      }
      { goPackagePath = "github.com/oschwald/maxminddb-golang";
        rev = "1960b16a5147df3a4c61ac83b2f31cd8f811d609";
        sha256 = "09hyc457cp27nsia8akp8m2ymcxlnz9xq6xrw6f818k4g1rxfsqh";
      }
      { goPackagePath = "go.etcd.io/etcd";
        github = { owner = "etcd-io"; repo = "etcd"; };
        rev = "ae9734ed278b7a1a7dfc82e800471ebbf9fce56f";
        sha256 = "0bvky593241i60qf6793sxzsxwfl3f56cgscnva9f2jfhk157wmy";
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
      { goPackagePath = "gopkg.in/dgrijalva/jwt-go.v3";
        url = "https://gopkg.in/dgrijalva/jwt-go.v3";
        rev = "06ea1031745cb8b3dab3f6a236daf2b0aa468b7e";
        sha256 = "08m27vlms74pfy5z79w67f9lk9zkx6a9jd68k3c4msxy75ry36mp";
      }
      { goPackagePath = "github.com/coreos/go-systemd";
        rev = "v22.1.0";
        sha256 = "127dj1iwp69yj74nwh9ckgc0mkk1mv4yzbxmbdxix1r7j6q35z3j";
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

    nextcloud.extraPostPatch = let
      inherit (config.nextcloud) majorVersion;
      patchFile = if majorVersion >= 19 then ./spreed-use-unix-sockets-v9.patch
                  else ./spreed-use-unix-sockets.patch;
    in "patch -p1 -d apps/spreed < ${patchFile}\n";

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
