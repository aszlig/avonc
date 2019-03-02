{ config, lib, pkgs, ... }:

let
  package = import ./.;

  docserverConfig = pkgs.writeText "onlyoffice-server.json" (builtins.toJSON {
    log.filePath = pkgs.writeText "onlyoffice-log.json" (builtins.toJSON {
      appenders.default = {
        type = "stderr";
        layout = {
          type = "pattern";
          pattern = "[%p] %c %m";
        };
      };
      categories.default = {
        appenders = [ "default" ];
        level = "TRACE"; # XXX!
      };
    });
    storage.fs.folderPath =
      "/var/lib/onlyoffice/documentserver/App_Data/cache/files";

    services = {
      CoAuthoring.server.static_content = {
        "/fonts" = {
          path = "${package}/fonts";
          options.maxAge = "7d";
        };
        "/sdkjs" = {
          path = "${package}/sdkjs";
          options.maxAge = "7d";
        };
        "/web-apps" = {
          path = "${package}/web-apps";
          options.maxAge = "7d";
        };
        "/welcome" = {
          path = "${package}/server/welcome";
          options.maxAge = "7d";
        };
        "/info" = {
          path = "${package}/server/info";
          options.maxAge = "7d";
        };
        "/sdkjs-plugins" = {
          path = "${package}/sdkjs-plugins";
          options.maxAge = "7d";
        };
      };
      utils.utils_common_fontdir = "/usr/share/fonts";
      sockjs.sockjs_url = "/web-apps/vendor/sockjs/sockjs.min.js";
    };

    FileConverter.converter = {
      fontDir = "/usr/share/fonts";
      presentationThemesDir = "${package}/sdkjs/slide/themes";
      x2tPath = "${package}/server/FileConverter/bin/x2t";
      docbuilderPath = "${package}/server/FileConverter/bin/docbuilder";
      docbuilderAllFontsPath =
        "${package}/server/FileConverter/bin/AllFonts.js";
    };

    FileStorage.directory = "/var/lib/onlyoffice/documentserver/App_Data";
  });

  configDir = pkgs.runCommand "onlyoffice-config" {
    inherit docserverConfig;
    defaultConf = "${package}/server/Common/config/default.json";
  } ''
    mkdir "$out"
    ln -s "$docserverConfig" "$out/onlyoffice.json"
    ln -s "$defaultConf" "$out/default.json"
  '';

in {
  imports = [ ../postgresql.nix ];

  users.users.onlyoffice = {
    description = "OnlyOffice Document Server User";
    group = "onlyoffice";
  };

  users.groups.onlyoffice = {};

  services.redis.enable = true; # XXX
  services.rabbitmq.enable = true; # XXX

  systemd.services.onlyoffice-init-db = {
    description = "OnlyOffice Database Initialisation";
    requiredBy = [ "onlyoffice.service" ];
    requires = [ "postgresql.service" ];
    before = [ "onlyoffice.service" ];
    after = [ "postgresql.service" ];

    unitConfig.ConditionPathExists = "!/var/lib/onlyoffice";
    environment.PGHOST = "/run/postgresql";

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
      RemainAfterExit = true;
      ExecStart = let
        postgresql = config.services.postgresql.package;
      in [
        "${postgresql}/bin/createuser onlyoffice"
        "${postgresql}/bin/createdb -O onlyoffice onlyoffice"
        "${postgresql}/bin/psql -1 -f ${package}/server/schema/postgresql/createdb.sql onlyoffice"
      ];
    };
  };

  systemd.services.onlyoffice = {
    description = "OnlyOffice Document Server";
    requires = [ "postgresql.service" ];
    after = [ "network.target" "sockets.target" "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      NODE_ENV = "onlyoffice";
      NODE_CONFIG_DIR = configDir;
    };

    serviceConfig = {
      User = "onlyoffice";
      Group = "onlyoffice";
      StateDirectory = "onlyoffice";
      ExecStart = "${pkgs.nodejs-10_x}/bin/node ${package}/server/DocService/sources/server.js";
      PrivateTmp = true;
    };
  };
}
