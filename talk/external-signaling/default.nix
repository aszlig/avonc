{ config, lib, pkgs, ... }:

let
  cfg = config.nextcloud.apps.spreed;

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
        rev = "ea4d1f681babbce9545c9c5f3d5194a789c89f5b";
        sha256 = "1bhgs2542qs49p1dafybqxfs2qc072xv41w5nswyrknwyjxxs2a1";
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

  configFile = pkgs.writeText "signaling.conf" (lib.generators.toINI {} {
    backend.timeout = 10;
    backend.connectionsperhost = 8;

    nats.url = ":loopback:";

    mcu.type = "janus";
    mcu.url = "";
  });

in {
  config = lib.mkIf (config.nextcloud.enable && cfg.enable) {
    users.users.nextcloud-signaling = {
      description = "Nextcloud Talk Signaling User";
      group = "nextcloud-signaling";
    };
    users.groups.nextcloud-signaling = {};

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
          proxyPass = "http://unix:/run/nextcloud-signaling/external.sock:"
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
        ListenStream = "/run/nextcloud-signaling/external.sock";
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
        ListenStream = "/run/nextcloud-signaling/internal.sock";
        FileDescriptorName = "internal";
        SocketUser = "root";
        SocketGroup = "nextcloud";
        SocketMode = "0660";
      };
    };

    systemd.services.nextcloud-signaling-internal-sockdir = {
      description = "Prepare Nextcloud Talk Signal Internal Socket Directory";
      requiredBy = [
        "nginx.service" "nextcloud-signaling.service"
        "nextcloud-signaling-internal.socket"
      ];
      before = [ "nginx.service" "nextcloud-signaling-internal.socket" ];

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

      chroot.enable = true;
      chroot.confinement = "chroot-only";

      serviceConfig = {
        ExecStart = "@${signalingServer}/bin/server nextcloud-signaling"
                  + " -config ${configFile}";
        User = "nextcloud-signaling";
        Group = "nextcloud-signaling";
        BindReadOnlyPaths = [ "/run/nextcloud-signaling" ];
        EnvironmentFile = [ "/var/lib/nextcloud-signaling/secrets.env" ];
      };
    };

    systemd.services.nextcloud.serviceConfig.BindReadOnlyPaths = [
      "/run/nextcloud-signaling"
    ];
  };
}
