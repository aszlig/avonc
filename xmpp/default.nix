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

  # Basic rules to block epmd's TCP sockets and use Unix sockets instead.
  baseRules = [
    { direction = "incoming";
      port = 4369;
      reject = true;
      rejectError = "EADDRINUSE";
    }
    { direction = "incoming";
      port = 0;
      socketPath = "/run/mongooseim-epmd/port-%p.socket";
    }
    { direction = "outgoing";
      address = "127.0.0.100";
      port = 5432;
      socketPath = "/run/postgresql/.s.PGSQL.5432";
    }
    { direction = "outgoing";
      port = 4369;
      type = "tcp";
      socketPath = "/run/mongooseim-epmd.socket";
    }
    { direction = "outgoing";
      address = "127.0.0.1";
      socketPath = "/run/mongooseim-epmd/port-%p.socket";
    }
  ];

  # Additional rules just for running the server.
  serverRules = [
    { direction = "incoming";
      port = 5280;
      socketActivation = true;
    }
    { direction = "outgoing";
      address = "127.0.0.200";
      port = 7;
      socketPath = "/run/mongooseim-internal/auth.socket";
    }
  ];

  mkCtl = extraRules: switchUser: let
    rules = builtins.toJSON (baseRules ++ extraRules);
    maybeSwitchUser = lib.optionalString switchUser (" ${lib.escapeShellArgs [
      "${pkgs.utillinux}/bin/runuser" "-u" "mongooseim" "-g" "mongooseim"
    ]} --");
  in pkgs.writeScriptBin "mongooseimctl" ''
    #!${pkgs.stdenv.shell}
    export ERL_EPMD_ADDRESS=127.0.0.150
    ${lib.optionalString switchUser "cd /var/empty"}
    exec${maybeSwitchUser} ${lib.escapeShellArgs [
      "${ip2unix}/bin/ip2unix"
      "-f" (pkgs.writeText "ip2unix.rules" rules)
      "${package}/bin/mongooseimctl"
    ]} "$@"
  '';

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
    { pubsub_createnode.allow.atom = "local"; }
  ] ++ lib.concatMap (mamAction: [
    { "mam_${mamAction}".default.atom = "all"; }
    { "mam_${mamAction}_shaper".mam_shaper.atom = "all"; }
    { "mam_${mamAction}_global_shaper".mam_global_shaper.atom = "all"; }
  ]) [
    "set_prefs" "get_prefs" "lookup_messages" "purge_single_message"
    "purge_multiple_messages"
  ]);

  writeConfig = terms: pkgs.writeText "mongooseim.cfg" ''
    override_global.
    override_local.
    override_acls.
    ${erlexpr.erlTermList terms}
  '';

  mainConfig = writeConfig {
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
    auth_method.atom = "nextcloud";
    auth_opts = {
      host = "http://127.0.0.200:7";
      connection_pool_size = 10;
    };
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
      mod_caps = {};
      mod_commands = {};
      mod_muc_commands = {};
      mod_muc_light_commands = {};
      mod_last = {};
      mod_stream_management = {};
      mod_offline.access_max_user_messages.atom = "max_user_offline_messages";
      mod_privacy = {};
      mod_blocking = {};
      mod_private = {};
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
      mod_muc.access_persistent.atom = "muc_create";

      mod_pubsub.access_createnode.atom = "pubsub_createnode";
      mod_pubsub.ignore_pep_from_offline = false;
      mod_pubsub.backend.atom = "rdbms";
      mod_pubsub.last_item_cache = true;
      mod_pubsub.max_items_node = 1000;
      mod_pubsub.plugins = [
        { binary = "dag"; }
        { binary = "flat"; }
        { binary = "hometree"; }
        { binary = "pep"; }
      ];
    };

    rdbms_server_type.atom = "pgsql";
    outgoing_pools = [
      { tuple = [
          { atom = "rdbms"; }
          { atom = "global"; }
          { atom = "default"; }
          { workers = 10; }
          { server.tuple = [
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
      }
      { tuple = [
          { atom = "http"; }
          { atom = "global"; }
          { atom = "auth"; }
          {}
          { server = "http://127.0.0.200:7";
            path_prefix = "/index.php/";
          }
        ];
      }
    ];
  };

in lib.mkIf cfg.enable {
  nextcloud.extraPostPatch = ''
    patch -p1 -d apps/ojsxc < ${patches/ojsxc.patch}
  '';

  users.users.mongooseim = {
    description = "MongooseIM User";
    group = "mongooseim";
  };

  users.groups.mongooseim = {};

  environment.systemPackages = lib.singleton (mkCtl [] true);

  systemd.services.mongooseim-create-db = {
    description = "MongooseIM Database Creation";
    requiredBy = [ "mongooseim.service" "mongooseim-init-db.service" ];
    requires = [ "postgresql.service" ];
    before = [ "mongooseim.service" "mongooseim-init-db.service" ];
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
      ];
    };
  };

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
      User = "mongooseim";
      Group = "mongooseim";
      RemainAfterExit = true;
      ExecStart = "${postgresql}/bin/psql -1 -f ${pgDbSchema} mongooseim";
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
      "-r in,port=4369,tcp,addr=127.0.0.150,systemd"
      "-r in,blackhole"
      "-r out,path=/run/mongooseim-epmd/port-%%p.socket"
      "${pkgs.erlang}/bin/epmd -address 127.0.0.150"
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

    chroot.enable = true;
    chroot.packages = [ mainConfig ];

    serviceConfig = {
      ExecStart = "${mkCtl serverRules false}/bin/mongooseimctl foreground";
      ExecStop = "${mkCtl [] false}/bin/mongooseimctl stop";
      ExecReload = "${mkCtl [] false}/bin/mongooseimctl reload_cluster";
      User = "mongooseim";
      Group = "mongooseim";
      StateDirectory = "mongooseim";
      RuntimeDirectory = "mongooseim";

      # XXX: Temporary until we have figured out a good way to share the S2S
      #      certificate with nginx.
      PrivateNetwork = true;

      BindPaths = [ "/run/mongooseim-epmd" "/run/mongooseim-epmd.socket" ];
      BindReadOnlyPaths = [
        "/run/postgresql" "/run/mongooseim-internal"
        "/etc/resolv.conf" "/etc/hosts"
      ];
    };
  };

  systemd.services.mongooseim-internal-sockdir = {
    description = "Prepare MongooseIM Internal Socket Directory";
    requiredBy = [ "nginx.service" "mongooseim.service" ];
    before = [ "nginx.service" ];

    unitConfig.ConditionPathExists = "!/run/mongooseim-internal";

    serviceConfig.RuntimeDirectory = "mongooseim-internal";
    serviceConfig.RuntimeDirectoryMode = "0710";
    serviceConfig.RuntimeDirectoryPreserve = true;
    serviceConfig.User = "nginx";
    serviceConfig.Group = "mongooseim";
    serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
    serviceConfig.Type = "oneshot";
  };

  # This is the only entry point for "externalApi.php", which is used to
  # authenticate the XMPP user against Nextcloud. Obviously we want that URL to
  # be inaccessible from the web and only provide access to that entry point
  # via Unix socket.
  services.nginx.appendHttpConfig = ''
    server {
      server_name xmpp-auth.local;
      listen unix:/run/mongooseim-internal/auth.socket;

      location = /index.php/apps/ojsxc/ajax/externalApi.php {
        uwsgi_intercept_errors on;
        include ${config.services.nginx.package}/conf/uwsgi_params;
        uwsgi_param INTERNAL_XMPP_AUTH allowed;
        uwsgi_pass unix:///run/nextcloud.socket;
      }
    }
  '';

  services.nginx.virtualHosts.${config.nextcloud.domain}.locations = {
    "= /xmpp/http-bind" = {
      proxyPass = "http://unix:/run/mongooseim-bosh.socket:";
      extraConfig = ''
        client_body_buffer_size 128K;
        client_max_body_size 4M;
        keepalive_timeout 60;
        proxy_buffering off;
        proxy_connect_timeout 5;
        proxy_read_timeout 60;
        proxy_redirect off;
        send_timeout 60;
      '';
    };
  };
}
