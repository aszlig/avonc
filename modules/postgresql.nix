# This is a very limited drop-in replacement for the NixOS "postgresql" module
# and intentionally doesn't support all of its functionality.
#
# The main reason this module exist is to get rid of all the backwards-
# compatible stuff in the upstream module and also focus more on privilege
# separation and integration into systemd.
#
# Originally, the reason this module was *necessary* was because PostgreSQL in
# NixOS used /tmp as its socket path, but starting with NixOS 19.09 this is no
# longer the case, so this very module might go away someday once the upstream
# module is "good enough".
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
      defaultText = lib.literalExample "pkgs.postgresql_10";
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

    ensureUsers = mkOption {
      type = types.listOf types.unspecified;
      default = [];
      description = ''
        This is a dummy option and it's there to avoid evaluation errors.
      '';
    };
    ensureDatabases = mkOption {
      type = types.listOf types.unspecified;
      default = [];
      description = ''
        This is a dummy option and it's there to avoid evaluation errors.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = cfg.ensureUsers == [];
        message = "The option 'services.postgresql.ensureUsers' is not"
                + " supported, please make sure to avoid services using it.";
      }
      { assertion = cfg.ensureDatabases == [];
        message = "The option 'services.postgresql.ensureUsers' is not"
                + " supported, please make sure to avoid services using it.";
      }
    ];

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
