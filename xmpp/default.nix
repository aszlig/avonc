{ config, pkgs, lib, ... }:

let
  cfg = config.nextcloud.apps.ojsxc;

  package = import ./package.nix { inherit pkgs lib; };
  erlexpr = import ./erlexpr lib;

  # TODO: Remove this as soon as it is in the oldest nixpkgs version we
  #       support.
  # XXX: Also, this is a duplicate of the same in /libreoffice-online.
  ip2unix = pkgs.stdenv.mkDerivation rec {
    name = "ip2unix-${version}";
    version = "2.0.1";

    src = pkgs.fetchFromGitHub {
      owner = "nixcloud";
      repo = "ip2unix";
      rev = "v${version}";
      sha256 = "1x2nfv15a1hg8vrw5vh8fqady12v9hfrb4p3cfg0ybx52y0xs48a";
    };

    nativeBuildInputs = [
      pkgs.meson pkgs.ninja pkgs.pkgconfig pkgs.python3Packages.pytest
      pkgs.python3Packages.pytest-timeout
    ];
    buildInputs = [ pkgs.libyamlcpp ];

    doCheck = true;
  };

  postgresql = config.services.postgresql.package;
  pgDbSchema = "${package}/lib/mongooseim/priv/pg.sql";

  boshSettings = {
    num_acceptors = 10;
    transport_options.max_connections = 1024;
    modules = [
      { tuple = [ "_" "/xmpp/http-bind" { atom = "mod_bosh"; } ]; }
    ];
  };

  s2sSettings = {
    shaper.atem = "s2s_shaper";
    max_stanza_size = 131072;
    protocol_options = [ "no_sslv3" ];
  };

  mkRuleList = lib.concatMap (lib.mapAttrsToList (atom: opts: {
    extuple = [ { inherit atom; } opts ];
  }));

  shapers = mkRuleList [
    { normal.maxrate = 1000; }
    { fast.maxrate = 50000; }
    { mam_shaper.maxrate = 1; }
    { mam_global_shaper.maxrate = 1000; }
  ];

  accessRules= mkRuleList ([
    { max_user_sessions = [ { tuple = [ 10 { atom = "all"; } ]; } ]; }
    { max_user_offline_messages = [
        { tuple = [ 5000 { atom = "admin"; } ]; }
        { tuple = [ 100 { atom = "all"; } ]; }
      ];
    }
    { local.allow.atom = "local"; }
    { c2s = [
        { tuple = [ { atom = "deny"; } { atom = "blocked"; } ]; }
        { tuple = [ { atom = "allow"; } { atom = "all"; } ]; }
      ];
    }
    { c2s_shaper = [
        { tuple = [ { atom = "none"; } { atom = "admin"; } ]; }
        { tuple = [ { atom = "normal"; } { atom = "all"; } ]; }
      ];
    }
    { s2s_shaper.fast.atom = "all"; }
    { muc_admin.allow.atom = "admin"; }
    { muc_create.allow.atom = "local"; }
    { muc.allow.atom = "all"; }
    { register.deny.atom = "all"; }
  ] ++ lib.concatMap (mamAction: [
    { "mam_${mamAction}".default.atom = "all"; }
    { "mam_${mamAction}_shaper".mam_shaper.atom = "all"; }
    { "mam_${mamAction}_global_shaper".mam_global_shaper.atom = "all"; }
  ]) [
    "set_prefs" "get_prefs" "lookup_messages" "purge_single_message"
    "purge_multiple_messages"
  ]);

  mainConfig = pkgs.writeText "mongooseim.cfg" (erlexpr.erlTermList {
    loglevel = 3;
    hosts = [ config.nextcloud.domain ];
    listen = [
      { tuple = [ 5280 { atom = "ejabberd_cowboy"; } boshSettings ]; }
      { tuple = [ 5269 { atom = "ejabberd_s2s_in"; } s2sSettings ]; }
    ];
    s2s_use_snarttls.atom = "required";
    s2s_certfile = "priv/ssl/fake_server.pem"; # TODO!
    s2s_ciphers = config.services.nginx.sslCiphers;
    s2s_default_policy.atom = "deny";
    outgoing_s2s_port = 5269;
    sm_backend.tuple = [ { atom = "mnesia"; } {} ];
    auth_method.atom = "internal";
    shaper.multi = shapers;
    max_fsm_queue = 1000;
    acl.extuple = [
      { atom = "local"; }
      { tuple = [ { atom = "user_regexp"; } "" ]; }
    ];
    access.multi = accessRules;
    registration_timeout.atom = "infinity";
    language = "en";
    all_metrics_are_global = false;
    modules = {
      mod_adhoc = {};
      mod_disco.users_can_see_hidden_services = false;
      mod_commands = {};
      mod_muc_commands = {};
      mod_muc_light_commands = {};
      mod_last = {};
      mod_stream_management = {};
      mod_offline.access_max_user_messages.atom = "max_user_offline_messages";
      mod_privacy = {};
      mod_blocking = {};
      mod_private = {};
      mod_register.access.atom = "register";
      mod_roster = {};
      mod_sic = {};
      mod_vcard.host = "vjud.@HOST@";
      mod_bosh = {};
      mod_carboncopy = {};
      mod_mam_meta = {
        backend.atom = "rdbms";
        user_prefs_store.atom = "mnesia";
        muc.host = "muc.@HOST@";
      };
      mod_muc_light.host = "muclight.@HOST@";
      mod_muc.host = "muc.@HOST@";
      mod_muc.access.atom = "muc";
      mod_muc.access_create.atom = "muc_create";
    };

    rdbms_server_type.atom = "pgsql";
    outgoing_pools = lib.singleton {
      tuple = [
        { atom = "rdbms"; }
        { atom = "global"; }
        { atom = "default"; }
        { workers = 10; }
        { server = [
            { atom = "pgsql"; }
            "127.0.0.100"
            5432
            "mongooseim"
            "mongooseim"
            ""
            { keepalive_interval = 10; }
          ];
        }
      ];
    };
  });

in lib.mkIf cfg.enable {
  users.users.mongooseim = {
    description = "MongooseIM User";
    group = "mongooseim";
  };

  users.groups.mongooseim = {};

  systemd.services.mongooseim-init-db = {
    description = "MongooseIM Database Initialisation";
    requiredBy = [ "mongooseim.service" ];
    requires = [ "postgresql.service" ];
    before = [ "mongooseim.service" ];
    after = [ "postgresql.service" ];

    unitConfig.ConditionPathExists = "!/var/lib/mongooseim";
    environment.PGHOST = "/run/postgresql";

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
      RemainAfterExit = true;
      ExecStart = [
        "${postgresql}/bin/createuser mongooseim"
        "${postgresql}/bin/createdb -O mongooseim mongooseim"
        "${postgresql}/bin/psql -1 -f ${pgDbSchema} mongooseim"
      ];
    };
  };

  systemd.sockets.mongooseim-epmd = {
    description = "Socket for MongooseIM Erlang Port Mapper";
    wantedBy = [ "sockets.target" ];

    socketConfig.ListenStream = "/run/mongooseim-epmd.socket";
    socketConfig.SocketUser = "root";
    socketConfig.SocketGroup = "mongooseim";
    socketConfig.SocketMode = "0660";
  };

  systemd.services.mongooseim-epmd = {
    description = "Erlang Port Mapper for MongooseIM";
    requiredBy = [ "mongooseim.service" ];
    before = [ "mongooseim.service" ];

    serviceConfig.ExecStart = toString [
      "${ip2unix}/bin/ip2unix"
      "-r in,port=4369,tcp,addr=127.0.0.1,systemd"
      "-r in,blackhole"
      "-r out,path=/run/mongooseim-epmd/port-%%p.socket"
      "${pkgs.erlang}/bin/epmd -address 127.0.0.1"
    ];
    serviceConfig.RuntimeDirectory = "mongooseim-epmd";
    serviceConfig.RuntimeDirectoryMode = "0730";
    serviceConfig.DynamicUser = true;
    serviceConfig.Group = "mongooseim";
  };

  systemd.sockets.mongooseim = {
    description = "MongooseIM BOSH Socket";
    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "/run/mongooseim-bosh.socket";
      SocketUser = "root";
      SocketGroup = "nginx";
      SocketMode = "0660";
    };
  };

  systemd.services.mongooseim = {
    description = "MongooseIM XMPP Server";
    wantedBy = [ "multi-user.target" ];

    environment.EJABBERD_CONFIG_PATH = mainConfig;

    serviceConfig.ExecStart = toString [
      "${ip2unix}/bin/ip2unix"
      "-r in,port=5280,systemd"
      "-r in,port=4369,tcp,reject=EADDRINUSE"
      "-r in,port=0,path=/run/mongooseim-epmd/port-%%p.socket"
      "-r out,addr=127.0.0.100,port=5432,path=/run/postgresql/.s.PGSQL.5432"
      "-r out,port=4369,tcp,path=/run/mongooseim-epmd.socket"
      "${package}/bin/mongooseimctl foreground"
    ];
    serviceConfig.User = "mongooseim";
    serviceConfig.Group = "mongooseim";
    serviceConfig.StateDirectory = "mongooseim";
  };

  services.nginx.virtualHosts.${config.nextcloud.domain}.locations = {
    "= /xmpp/http-bind".proxyPass = "http://unix:/run/mongooseim-bosh.socket:";
  };
}