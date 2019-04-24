{ config, lib, pkgs, ... }:

let
  cfg = config.nextcloud.apps.spreed;
  inherit (config.services) nginx;
  inherit (lib) optionalString;

  coturn = pkgs.coturn.overrideAttrs (drv: {
    patches = (drv.patches or []) ++ [ ./coturn-secret-from-env.patch ];
  });

  notProto = proto: let
    protoList = builtins.split " " nginx.sslProtocols;
  in !lib.elem proto protoList;

  configFile = pkgs.writeText "nextcloud-coturn.conf" (''
    no-cli
    simple-log

    fingerprint
    stale-nonce
    no-loopback-peers
    no-multicast-peers

    use-auth-secret
    static-auth-secret=!
    realm=${config.nextcloud.domain}

  '' + (if config.nextcloud.useSSL then ''
    no-udp
    no-tcp
    tls-listening-port=${toString cfg.port}
    cipher-list="${nginx.sslCiphers}"
    ${optionalString (notProto "TLSv1") "no-tlsv1"}
    ${optionalString (notProto "TLSv1.1") "no-tlsv1_1"}
    ${optionalString (notProto "TLSv1.2") "no-tlsv1_2"}
    ${optionalString (nginx.sslDhparam != null) "dh-file=${nginx.sslDhparam}"}
    cert=/run/nextcloud-coturn/cert.pem
    pkey=/run/nextcloud-coturn/key.pem
  '' else ''
    no-tls
    no-dtls
    listening-port=${toString cfg.port}
  ''));

in {
  options.nextcloud.apps.spreed = {
    port = lib.mkOption {
      type = lib.types.port;
      default = if config.nextcloud.useSSL then 5349 else 3478;
      defaultText = "if config.nextcloud.useSSL then 5349 else 3478";
      example = 5000;
      description = ''
        The port to use for the STUN/TURN server.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.nextcloud-coturn = {
      description = "Nextcloud STUN/TURN User";
      group = "nextcloud-coturn";
    };
    users.groups.nextcloud-coturn = {};

    nextcloud.apps.spreed.config = {
      stun_servers = builtins.toJSON [
        "${config.nextcloud.domain}:${toString cfg.port}"
      ];
      turn_servers = builtins.toJSON (lib.singleton {
        server = "${config.nextcloud.domain}:${toString cfg.port}";
        secret = "__FROM_ENV";
        protocols = "udp,tcp";
      });
    };

    nextcloud.extraPostPatch = ''
      patch -p1 -d apps/spreed < ${./spreed-secret-from-env.patch}
    '';

    systemd.services.nextcloud-coturn-secrets = {
      description = "Secrets for Nextcloud Talk STUN/TURN Server";
      requires = [ "nginx.service" "nextcloud-upgrade.service" ];
      after = [ "nginx.service" ];
      before = [ "nextcloud-upgrade.service" ];

      environment = lib.optionalAttrs config.nextcloud.useSSL {
        inherit (nginx.virtualHosts.${config.nextcloud.domain})
          sslCertificate sslCertificateKey;
      };

      unitConfig = lib.optionalAttrs (!config.nextcloud.useSSL) {
        ConditionPathExists = "!/var/lib/nextcloud-coturn/secrets.env";
      };

      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        RemainAfterExit = true;
        ExecStart = pkgs.writeScript "nextcloud-coturn-secrets-init.py" (''
          #!${pkgs.python3Packages.python.interpreter}
          import secrets, shutil, os

          SECRETS_FILE = '/var/lib/nextcloud-coturn/secrets.env'

          if not os.path.exists(SECRETS_FILE):
            os.makedirs(os.path.dirname(SECRETS_FILE), 0o700, True)
            secret = secrets.token_urlsafe(80)
            data = 'COTURN_STATIC_AUTH_SECRET=' + secret + '\n'
            open(SECRETS_FILE, 'w').write(data)

        '' + optionalString config.nextcloud.useSSL ''
          CERT_DIR = '/run/nextcloud-coturn'

          shutil.rmtree(CERT_DIR, True)
          os.makedirs(CERT_DIR, 0o700)
          certfile = os.path.join(CERT_DIR, 'cert.pem')
          keyfile = os.path.join(CERT_DIR, 'key.pem')

          shutil.copyfile(os.environ['sslCertificate'], certfile)
          shutil.copyfile(os.environ['sslCertificateKey'], keyfile)

          shutil.chown(certfile, group='nextcloud-coturn')
          shutil.chown(keyfile, group='nextcloud-coturn')
          os.chmod(certfile, 0o640)
          os.chmod(keyfile, 0o640)

          shutil.chown(CERT_DIR, group='nextcloud-coturn')
          os.chmod(CERT_DIR, 0o710)
        '');
      };
    };

    systemd.services.nextcloud-coturn = {
      description = "Nextcloud Talk STUN/TURN Server";
      wantedBy = [ "nextcloud.service" ];
      requires = [ "nextcloud-coturn-secrets.service" ];
      after = [ "network.target" "nextcloud-coturn-secrets.service" ];

      chroot.enable = true;
      chroot.confinement = "chroot-only";

      serviceConfig = {
        ExecStart = "${coturn}/bin/turnserver -c ${configFile}";
        User = "nextcloud-coturn";
        Group = "nextcloud-coturn";

        EnvironmentFile = [ "/var/lib/nextcloud-coturn/secrets.env" ];

        BindReadOnlyPaths =
             lib.optional config.nextcloud.useSSL "/run/nextcloud-coturn"
          ++ lib.optional (nginx.sslDhparam != null) nginx.sslDhparam;
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
