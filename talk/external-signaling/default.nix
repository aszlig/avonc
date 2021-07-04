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
    version = "0.3.0";

    src = pkgs.fetchFromGitHub {
      repo = pname;
      owner = "strukturag";
      rev = "v${version}";
      sha256 = "1rdkinmkk5ymrxrr46gbwglvdy18nmkfj0q4makj3y2sjspgv8d0";
    };

    goPackagePath = "github.com/strukturag/${pname}";

    nativeBuildInputs = [ pkgs.python3 ];

    patches = [ ./signaling-socket-activation.patch ];

    preBuild = ''
      export GOPATH="$NIX_BUILD_TOP/go/src/$goPackagePath:$GOPATH"
      ( cd "$NIX_BUILD_TOP/go/src/$goPackagePath"
        ${pkgs.easyjson}/bin/easyjson -all \
          api_signaling.go \
          api_backend.go \
          api_proxy.go \
          natsclient.go \
          room.go
      )
    '';

    # All those dependencies are from "go.mod" and "go.sum" in the source tree.
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
        rev = "v1.2.0";
        sha256 = "08wqig98w23cg2ngjijhgm6s0mdayb95awa3cn3bs69lg20gryac";
      }
      { goPackagePath = "github.com/gorilla/mux";
        rev = "v1.8.0";
        sha256 = "18f0q9qxgq1yh4ji07mqhiydfcwvi56z9d775v7dc7yckj33kpdk";
      }
      { goPackagePath = "github.com/gorilla/securecookie";
        rev = "v1.1.1";
        sha256 = "16bqimpxs9vj5n59vm04y04v665l7jh0sddxn787pfafyxcmh410";
      }
      { goPackagePath = "github.com/gorilla/websocket";
        rev = "v1.4.2";
        sha256 = "0mkm9w6kjkrlzab5wh8p4qxkc0icqawjbvr01d2nk6ykylrln40s";
      }
      { goPackagePath = "github.com/mailru/easyjson";
        rev = "v0.7.7";
        sha256 = "0clifkvvy8f45rv3cdyv58dglzagyvfcqb63wl6rij30c5j2pzc1";
      }
      { goPackagePath = "github.com/josharian/intern";
        rev = "v1.0.0";
        sha256 = "1za48ppvwd5vg8vv25ldmwz1biwpb3p6qhf8vazhsfdg9m07951c";
      }
      { goPackagePath = "github.com/nats-io/nats-server";
        rev = "v2.2.6";
        sha256 = "0yc3paznkjmkdzs1r7mnlvlsyh7wb9r5vslbr6bw3h4fk94b7dxb";
      }
      { goPackagePath = "github.com/nats-io/nats.go";
        rev = "v1.11.0";
        sha256 = "133a9xa573519innd2xbzd3qiv799k2z0888cs9iilj60gkb7kqx";
      }
      { goPackagePath = "github.com/nats-io/nkeys";
        rev = "v0.3.0";
        sha256 = "06wbmb3cxjrcfvgfbn6rdfzb4pfaaw11bnvl1r4kig4ag22qcz7b";
      }
      { goPackagePath = "github.com/nats-io/nuid";
        rev = "v1.0.1";
        sha256 = "11zbhg4kds5idsya04bwz4plj0mmiigypzppzih731ppbk2ms1zg";
      }
      { goPackagePath = "github.com/notedit/janus-go";
        rev = "10eb8b95d1a0469ac8921c5ce5fb55b4c0d3ad7d";
        sha256 = "0ng184pp2bhrdd3ak4qp2cnj2y3zch90l2jvd3x5gspy5w6vmszn";
      }
      { goPackagePath = "github.com/oschwald/maxminddb-golang";
        rev = "v1.8.0";
        sha256 = "1047hgf3ly78083rldfnrygdihwb6hifbphl9b0iszcm77h52lh9";
      }
      { goPackagePath = "go.etcd.io/etcd";
        github = { owner = "etcd-io"; repo = "etcd"; };
        rev = "aa7126864d82e88c477594b8a53f55f2e2408aa3";
        sha256 = "0vjkwqadmjcvr52nnz26xj8flghc5grnimajp8cqv2pl7gxvd44c";
      }
      { goPackagePath = "google.golang.org/protobuf";
        github = { owner = "protocolbuffers"; repo = "protobuf-go"; };
        rev = "v1.26.0";
        sha256 = "0xq6phaps6d0vcv13ga59gzj4306l0ki9kikhmb52h6pq0iwfqlz";
      }
      { goPackagePath = "golang.org/x/crypto";
        url = "https://go.googlesource.com/crypto";
        rev = "e6e6c4f2bb5b5887c7f7dd52f01ea7b2fbeb297d";
        sha256 = "1q4kr6cmz8ybx9qvz4553j81azwkxircmr24qw2d506k4my7wppj";
      }
      { goPackagePath = "golang.org/x/sys";
        url = "https://go.googlesource.com/sys";
        rev = "c709ea063b76879dc9915358f55d4d77c16ab6d5";
        sha256 = "15nq53a6kcqchng4j0d1pjw0m6hny6126nhjdwqw5n9dzh6a226d";
      }
      { goPackagePath = "gopkg.in/dgrijalva/jwt-go.v3";
        url = "https://gopkg.in/dgrijalva/jwt-go.v3";
        rev = "v3.2.0";
        sha256 = "08m27vlms74pfy5z79w67f9lk9zkx6a9jd68k3c4msxy75ry36mp";
      }
      { goPackagePath = "github.com/coreos/go-systemd";
        rev = "v22.3.2";
        sha256 = "1ndi86b8va84ha93njqgafypz4di7yxfd5r5kf1r0s3y3ghcjajq";
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

    nextcloud.apps.spreed.patches = let
      inherit (config.nextcloud) majorVersion;
      patchFile = if majorVersion >= 19 then ./spreed-use-unix-sockets-v9.patch
                  else ./spreed-use-unix-sockets.patch;
    in lib.singleton patchFile;

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
