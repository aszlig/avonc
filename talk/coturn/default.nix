{ config, lib, pkgs, ... }:

let
  cfg = config.nextcloud.apps.spreed;
  inherit (config.services) nginx;
  inherit (lib) optionalString;

  coturn = pkgs.coturn.overrideAttrs (drv: let
    isRecentEnough = lib.versionAtLeast drv.version "4.5.1.0";
  in {
    patches = (drv.patches or []) ++ [ ./coturn-secret-from-env.patch ];
  } // lib.optionalAttrs (!isRecentEnough) rec {
    name = "coturn-${version}";
    version = "4.5.1.1";

    src = pkgs.fetchFromGitHub {
      owner = "coturn";
      repo = "coturn";
      rev = "${version}";
      sha256 = "12x604lgva1d3g4wvl3f66rdj6lkjk5cqr0l3xas33xgzgm13pwr";
    };
  });

  configFile = pkgs.writeText "nextcloud-coturn.conf" ''
    no-cli
    simple-log
    log-file=stdout

    fingerprint
    stale-nonce
    no-multicast-peers

    use-auth-secret
    static-auth-secret=!
    realm=${config.nextcloud.domain}

    no-tls
    no-dtls
    listening-port=${toString cfg.port}
  '';

in {
  options.nextcloud.apps.spreed = {
    port = lib.mkOption {
      type = lib.types.ints.u16;
      default = 3478;
      example = 5000;
      description = ''
        The port to use for the STUN/TURN server.
      '';
    };
  };

  config = lib.mkIf (config.nextcloud.enable && cfg.enable) {
    users.users.nextcloud-coturn = {
      description = "Nextcloud STUN/TURN User";
      group = "nextcloud-coturn";
    };
    users.groups.nextcloud-coturn = {};

    nextcloud.apps.spreed = {
      patches = lib.singleton ./spreed-secret-from-env.patch;
      config = {
        stun_servers = builtins.toJSON [
          "${config.nextcloud.domain}:${toString cfg.port}"
        ];
        turn_servers = builtins.toJSON (lib.singleton {
          server = "${config.nextcloud.domain}:${toString cfg.port}";
          secret = "__FROM_ENV";
          protocols = "udp,tcp";
        });
      };
    };

    systemd.services.nextcloud-coturn-secrets = {
      description = "Secrets for Nextcloud Talk STUN/TURN Server";
      requires = [ "nginx.service" "nextcloud-upgrade.service" ];
      after = [ "nginx.service" ];
      before = [ "nextcloud-upgrade.service" ];

      unitConfig = {
        ConditionPathExists = "!/var/lib/nextcloud-coturn/secrets.env";
      };

      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        RemainAfterExit = true;
        StateDirectory = "nextcloud-coturn";
        StateDirectoryMode = "0700";
        ExecStart = pkgs.writeScript "nextcloud-coturn-secrets-init.py" ''
          #!${pkgs.python3Packages.python.interpreter}
          from secrets import token_urlsafe
          data = 'COTURN_STATIC_AUTH_SECRET=' + token_urlsafe(80) + '\n'
          open('/var/lib/nextcloud-coturn/secrets.env', 'w').write(data)
        '';
      };
    };

    systemd.services.nextcloud-coturn = {
      description = "Nextcloud Talk STUN/TURN Server";
      wantedBy = [ "nextcloud.service" ];
      requires = [ "nextcloud-coturn-secrets.service" ];
      after = [ "network.target" "nextcloud-coturn-secrets.service" ];

      confinement.enable = true;
      confinement.mode = "chroot-only";

      serviceConfig = {
        ExecStart = "${coturn}/bin/turnserver -c ${configFile}";
        User = "nextcloud-coturn";
        Group = "nextcloud-coturn";
        EnvironmentFile = [ "/var/lib/nextcloud-coturn/secrets.env" ];
      };
    };

    systemd.services.nextcloud.serviceConfig = {
      EnvironmentFile = [ "/var/lib/nextcloud-coturn/secrets.env" ];
    };

    systemd.services.nextcloud-cron.serviceConfig = {
      EnvironmentFile = [ "/var/lib/nextcloud-coturn/secrets.env" ];
    };
  };
}
