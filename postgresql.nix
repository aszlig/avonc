# This module exists because the implementation of the PostgreSQL service
# module in NixOS is really crappy. It contains a lot of backwards-compatible
# options and it's designed to run with IP sockets. Furthermore Unix domains
# are pointed to /tmp, which is really a bad idea if you want to use PrivateTmp
# on other services accessing PostgreSQL.
#
# Here on the other hand, we try to aim for maximum privilege separation and
# better integration into systemd.
{ config, pkgs, lib, ... }:

let
  inherit (lib) types mkOption;
  cfg = config.services.postgresql;
  dataDir = "/var/lib/postgresql";

  configuration = {
    hba_file = pkgs.writeText "pg_hba.conf" cfg.authentication;
    ident_file = pkgs.writeText "pg_ident.conf" cfg.identMap;
    unix_socket_directories = "/run/postgresql";
    log_destination = "stderr";
    port = "5432";
    listen_addresses = "";
  };

in {
  disabledModules = [ "services/databases/postgresql.nix" ];

  options.services.postgresql = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to run the PostgreSQL database server.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.postgresql_10 or pkgs.postgresql100;
      defaultText = "pkgs.postgresql_10";
      description = "PostgreSQL package to use.";

      apply = pkg: pkg.overrideAttrs (drv: {
        configureFlags = (drv.configureFlags or []) ++ [ "--with-systemd" ];
        buildInputs = (drv.buildInputs or []) ++ [ pkgs.systemd ];
      });
    };

    superUser = mkOption {
      type = types.str;
      default = "postgres";
      internal = true;
      readOnly = true;
      description = "The name of the PostgreSQL superuser.";
    };

    authentication = mkOption {
      type = types.lines;
      description = ''
        Defines how users authenticate themselves to the server. By default,
        peer authentication is used via Unix domain sockets.
      '';
    };

    identMap = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Defines the mapping from system users to database users.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql.authentication = lib.mkAfter ''
      local all all peer
    '';

    users.users.postgres = {
      description = "PostgreSQL Server User";
      group = "postgres";
      uid = config.ids.uids.postgres;
    };

    users.groups.postgres.gid = config.ids.gids.postgres;

    systemd.services.postgresql-init = {
      description = "Initialize PostgreSQL Cluster";
      requiredBy = [ "postgresql.service" ];
      before = [ "postgresql.service" ];
      environment.PGDATA = dataDir;
      unitConfig.ConditionPathExists = "!${dataDir}/PG_VERSION";
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/initdb";
        StateDirectory = "postgresql";
        StateDirectoryMode = "0700";
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
      };
    };

    systemd.services.postgresql = {
      description = "PostgreSQL Server";
      wantedBy = [ "multi-user.target" ];
      environment.PGDATA = dataDir;
      serviceConfig = {
        ExecStart = let
          mkCfgVal = name: val: "-c ${lib.escapeShellArg "${name}=${val}"}";
          cfgVals = lib.mapAttrsToList mkCfgVal configuration;
        in "${cfg.package}/bin/postgres ${lib.concatStringsSep " " cfgVals}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        RuntimeDirectory = "postgresql";
        StateDirectory = "postgresql";
        StateDirectoryMode = "0700";
        Type = "notify";
        User = "postgres";
        Group = "postgres";
        PrivateNetwork = true;
      };
    };

    environment.systemPackages = [ cfg.package ];
  };
}
