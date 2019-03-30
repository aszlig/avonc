{ pkgs, lib, config, ... }:

let
  inherit (lib) types mkOption;

  cfg = config.nextcloud;
  inherit (cfg) package;

  urlScheme = if cfg.useSSL then "https" else "http";
  maybePort = let
    needsExplicit = !lib.elem cfg.port [ 80 443 ];
  in lib.optionalString needsExplicit ":${toString cfg.port}";

  occ = lib.escapeShellArg "${package}/occ";

  occUser = pkgs.writeScriptBin "nextcloud-occ" ''
    #!${pkgs.stdenv.shell} -e
    export NEXTCLOUD_CONFIG_DIR=${lib.escapeShellArg nextcloudConfigDir}
    export __NEXTCLOUD_VERSION=${lib.escapeShellArg package.version}
    set -a
    source /var/lib/nextcloud/secrets.env
    set +a
    exec ${lib.escapeShellArg "${pkgs.utillinux}/bin/runuser"} \
      -u nextcloud -g nextcloud -- ${phpCli} ${occ} "$@"
  '';

  postgresql = config.services.postgresql.package;

  dbShell = pkgs.writeScriptBin "nextcloud-dbshell" ''
    export PGHOST=/run/postgresql
    exec ${lib.escapeShellArg "${pkgs.utillinux}/bin/runuser"} \
      -u nextcloud -g nextcloud -- \
      ${lib.escapeShellArg "${postgresql}/bin/psql"} \
      nextcloud \
      "$@"
  '';

  opcache = pkgs.runCommand "nextcloud-opcache-${package.version}" rec {
    nativeBuildInputs = [ php ];
    inherit package;
    preloader = pkgs.writeScript "opcache-preloader.sh" ''
      #!${pkgs.stdenv.shell}
      ${lib.escapeShellArgs [
        "${php}/bin/php"
        "-d" "zend_extension=opcache.so"
        "-d" "opcache.enable=1"
        "-d" "opcache.enable_cli=1"
        "-d" "opcache.max_accelerated_files=100000"
        "-d" "opcache.file_cache_only=1"
        "-d" "assert.exception=1"
        "-d" "error_reporting=E_ALL"
        "-d" "log_errors=1"
        "-d" "display_errors=0"
      ]} -d "opcache.file_cache=$out" "$1" &> /dev/null || :
    '';
  } ''
    mkdir "$out"
    "$preloader" "$package/occ"
    find "$package" -type f -name '*.php' -print0 \
      | xargs -0 -P "$NIX_BUILD_CORES" -n1 "$preloader"
    chmod -R go+rX "$out"
  '';

  caCerts = config.environment.etc."ssl/certs/ca-certificates.crt".source;

  commonPhpConfig = [
    "curl.cainfo=${caCerts}"
    "expose_php=false"
    "extension=${phpPackages.apcu}/lib/php/extensions/apcu.so"
    "extension=${phpPackages.imagick}/lib/php/extensions/imagick.so"
    "memory_limit=${toString cfg.maxUploadSize}M"
    "opcache.enable=1"
    "opcache.enable_cli=1"
    "opcache.interned_strings_buffer=8"
    "opcache.max_accelerated_files=10000"
    "opcache.memory_consumption=128"
    "opcache.revalidate_freq=1"
    "opcache.save_comments=1"
    "opcache.validate_timestamps=0"
    "openssl.cafile=${caCerts}"
    "pgsql.allow_persistent=1"
    "pgsql.auto_reset_persistent=0"
    "pgsql.ignore_notice=0"
    "pgsql.log_notice=0"
    "pgsql.max_links=-1"
    "pgsql.max_persistent=-1"
    "post_max_size=${toString cfg.maxUploadSize}M"
    "upload_max_filesize=${toString cfg.maxUploadSize}M"
    "user_ini.filename="
    "zend_extension=opcache.so"
  ] ++ lib.optionals (config.time.timeZone != null) [
    "date.timezone=${config.time.timeZone}"
  ] ++ lib.optionals cfg.preloadOpcache [
    "opcache.file_cache=${opcache}"
    "opcache.file_cache_consistency_checks=0"
    "opcache.validate_permission=0"
  ];

  runtimePhpConfig = [
    "session.save_path=/var/cache/nextcloud/sessions"
    "upload_tmp_dir=/var/cache/nextcloud/uploads"
  ];

  mkPhpCli = phpConfig: let
    mkArgs = lib.concatMapStringsSep " " (opt: "-d ${lib.escapeShellArg opt}");
    escPhp = lib.escapeShellArg "${php}/bin/php";
  in escPhp + " " + mkArgs phpConfig;

  phpCli = mkPhpCli (commonPhpConfig ++ runtimePhpConfig);
  phpCliInit = mkPhpCli commonPhpConfig;

  # NixOS options that are merged with the existing appids.
  extraAppOptions = {};

  mkPhpString = value: "'${lib.escape ["\\" "'"] value}'";

  mkPhpAssocArray = attrs: let
    mkKeyVal = key: val: "${mkPhpString key} => ${mkPhp val}";
    pairs = lib.mapAttrsToList mkKeyVal attrs;
  in "[${lib.concatStringsSep ", " pairs}]";

  mkPhpArray = vals: "[${lib.concatMapStringsSep ", " mkPhp vals}]";

  mkPhp = value:
    if lib.isInt value then toString value
    else if value == true then "true"
    else if value == false then "false"
    else if value == null then "null"
    else if value ? __fromEnv then "$_ENV[${mkPhpString value.__fromEnv}]"
    else if lib.isAttrs value then mkPhpAssocArray value
    else if lib.isList value then mkPhpArray value
    else mkPhpString value;

  mkPhpConfig = value: "<?php\n$CONFIG = ${mkPhp value};\n";

  # All of the static files we can serve as-is without going through PHP.
  staticFiles = pkgs.runCommand "nextcloud-static-${package.version}" {
    nextcloud = package;
  } ''
    cd "$nextcloud"
    install -D -m 644 robots.txt "$out/robots.txt"
    find . -type f \( ${let
      mkArg = ext: "-name ${lib.escapeShellArg "*.${ext}"}";
    in lib.concatMapStringsSep " -o " mkArg [
      "css" "gif" "html" "ico" "jpg" "js" "png" "svg" "ttf" "woff" "woff2"
    ]} \) -exec ${pkgs.writeScript "install-static" ''
      #!${pkgs.stdenv.shell}
      for path in "$@"; do
        install -D -m 644 "$path" "$out/$path"
      done
    ''} {} +
  '';

  # All of the PHP files that may be run via HTTP request relative to the
  # docroot and without extension.
  entryPoints = [
    "index" "remote" "public" "status" "ocs/v1" "ocs/v2" "ocs-provider/index"
    "ocm-provider/index"
  ];

  nextcloudConfigDir = let
    nextcloudConfig = mkPhpConfig ({
      instanceid.__fromEnv = "__NEXTCLOUD_SECRETS_INSTANCEID";
      passwordsalt.__fromEnv = "__NEXTCLOUD_SECRETS_PASSWORDSALT";
      secret.__fromEnv = "__NEXTCLOUD_SECRETS_SECRET";

      trusted_domains = [];
      datadirectory = "/var/lib/nextcloud/data";
      version.__fromEnv = "__NEXTCLOUD_VERSION";
      dbtype = "pgsql";
      dbhost = "/run/postgresql";
      dbname = "nextcloud";
      dbuser = "nextcloud";
      installed = true;
      knowledgebaseenabled = true;
      allow_user_to_change_display_name = true;
      skeletondirectory = "";
      lost_password_link = "disabled";
      mail_domain = cfg.domain;

      overwritehost = "${cfg.domain}${maybePort}";
      overwriteprotocol = urlScheme;
      overwritewebroot = "/";
      "overwrite.cli.url" = cfg.baseUrl;
      "htaccess.RewriteBase" = "/";
      "htaccess.IgnoreFrontController" = true;

      updatechecker = false;
      check_for_working_wellknown_setup = false;
      check_for_working_htaccess = false;
      config_is_read_only = true;

      # We do check integrity on our end via the updater and tampering on the
      # server can be verified via the store paths checksum, eg. comparing it
      # against one from a different host.
      "integrity.check.disabled" = true;
      lastupdateat = 0;

      log_type = "errorlog";
      logdateformat = ""; # Already taken care by journald.

      appstoreenabled = false;
      apps_paths = [
        { path = "${package}/apps";
          url = "/apps";
          writable = false;
        }
      ];

      nix_executable_map = {
        smbclient = "${pkgs.samba}/bin/smbclient";
        sendmail = "${config.security.wrapperDir}/sendmail";
        ffmpeg = "${pkgs.ffmpeg.bin}/bin/ffmpeg";
      };

      enabledPreviewProviders =
        map (ft: "OC\\Preview\\${ft}") cfg.previewFileTypes;

      preview_libreoffice_path = let
        isNeeded = !lib.mutuallyExclusive cfg.previewFileTypes [
          "MSOffice2003" "MSOffice2007" "MSOfficeDoc" "OpenDocument"
          "StarOffice"
        ];
        # TODO: Put into a separate sandbox.
        libreoffice = "${pkgs.libreoffice-unwrapped}/lib/libreoffice/program/"
                    + "soffice.bin";
      in lib.optionalString isNeeded libreoffice;

      "memcache.local" = "\\OC\\Memcache\\APCu";

      supportedDatabases = [ "pgsql" ];
      tempdirectory = "/var/cache/nextcloud/uploads";

      # By default this contains '.htaccess', but our web server doesn't parse
      # these files, so we can safely allow them.
      blacklisted_files = [];
      cipher = "AES-256-CFB";

      "upgrade.disable-web" = true;
    } // (lib.optionalAttrs (cfg.theme != "default") {
      theme = "nextcloud-${cfg.theme}";
    }) // cfg.extraConfig);
  in pkgs.writeTextFile {
    name = "nextcloud-config";
    text = nextcloudConfig;
    destination = "/config.php";
    checkPhase = "${php}/bin/php -l \"$out/config.php\"";
  };

  mkEnableDisableApps = occCmd: disableOnly: let
    appPart = lib.partition (a: cfg.apps.${a}.enable) (lib.attrNames cfg.apps);

    newState = pkgs.writeText "nextcloud-appstate.json" (builtins.toJSON ({
      disable = appPart.wrong;
    } // lib.optionalAttrs (!disableOnly) {
      enable = lib.genAttrs appPart.right (app: cfg.apps.${app}.onlyGroups);
      appconf = lib.genAttrs appPart.right (app: cfg.apps.${app}.config);
    }));

    enableDisableApps = lib.escapeShellArgs [
      pkgs.python3Packages.python.interpreter
      "${tools/enable-disable-apps.py}"
    ];

  in "${enableDisableApps} ${lib.escapeShellArg newState} ${occCmd}";

  nextcloudInit = pkgs.runCommand "nextcloud-init" {
    nativeBuildInputs = [
      postgresql php pkgs.glibcLocales
    ];
    outputs = [ "out" "sql" "data" ];
    nextcloud = package;
    adminUser = cfg.initialAdminUser;
    adminPass = cfg.initialAdminPass;
  } ''
    initdb -D "$TMPDIR/tempdb" -E UTF8 -N -U "$tempDbUser"
    pg_ctl start -w -D "$TMPDIR/tempdb" -o \
      "-F --listen_addresses= --unix_socket_directories=$TMPDIR"
    createuser -h "$TMPDIR" nextcloud
    createdb -h "$TMPDIR" nextcloud -O nextcloud

    mkdir tmpconfig
    cat > tmpconfig/override.config.php <<EOF
    <?php
    \$CONFIG = [
      'apps_paths' => [
        ['path' => '$nextcloud/apps', 'url' => '/apps', 'writable' => false],
        ['path' => '$PWD', 'url' => '/dummy', 'writable' => true]
      ],
      'skeletondirectory' => "",
    ];
    EOF
    export NEXTCLOUD_CONFIG_DIR="$PWD/tmpconfig"

    ${phpCliInit} "$nextcloud/occ" maintenance:install \
      --database pgsql \
      --database-name nextcloud \
      --database-host $TMPDIR \
      --database-user nextcloud \
      --admin-user "$adminUser" \
      --admin-pass "$adminPass" \
      --data-dir "$PWD/data"

    ${phpCliInit} "$nextcloud/occ" background:cron
    ${phpCliInit} "$nextcloud/occ" db:convert-filecache-bigint

    ${mkEnableDisableApps "${phpCliInit} \"$nextcloud/occ\"" true}

    rm "$PWD/data/index.html" "$PWD/data/.htaccess"
    pg_dump -h "$TMPDIR" nextcloud > "$sql"
    tar cf "$data" -C data .
    touch "$out"
  '';

  php = pkgs.php-embed;

  phpPackages = let
    needsGhostscript = lib.elem cfg.previewFileTypes [ "PDF" "Postscript" ];
  in pkgs.phpPackages.override ({
    inherit php;
  } // lib.optionalAttrs needsGhostscript {
    pkgs = pkgs // { imagemagick = pkgs.imagemagickBig; };
  });

  uwsgiNextcloud = pkgs.runCommand "uwsgi-nextcloud" {
    uwsgi = pkgs.uwsgi.override {
      plugins = [ "php" ];
      withPAM = false;
      withSystemd = true;
    };
    config = pkgs.writeText "wsgi-nextcloud.json" (builtins.toJSON {
      uwsgi = {
        auto-procname = true;
        chdir = package;
        die-on-term = true;
        disable-logging = true;
        env = [
          "NEXTCLOUD_CONFIG_DIR=${nextcloudConfigDir}"
          "PWD=${package}"
          "SSL_CERT_FILE=${caCerts}"
          "NIX_SSL_CERT_FILE=${caCerts}"
        ];
        master = true;
        php-allowed-script = map (name: "${package}/${name}.php") entryPoints;
        php-index = "index.php";
        php-docroot = package;
        php-sapi-name = "apache";
        php-set = commonPhpConfig ++ runtimePhpConfig
               ++ [ "log_errors=1" "display_errors=0" ];
        plugins = [ "0:php" ];
        processes = cfg.processes;
        procname-prefix-spaced = "[nextcloud]";
        single-interpreter = true;
        socket = config.systemd.sockets.nextcloud.socketConfig.ListenStream;
        strict = true;
      };
    });
    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildInputs = [];
  } "makeWrapper \"$uwsgi/bin/uwsgi\" \"$out\" --add-flags \"--json $config\"";

in {
  options.nextcloud = {
    domain = mkOption {
      type = types.str;
      default = "localhost";
      example = "cloud.example.org";
      description = "The main Nextcloud domain to use for serving the site.";
    };

    useSSL = lib.mkOption {
      type = types.bool;
      default = builtins.match ".+\\..+" cfg.domain != null;
      defaultText =
        "builtins.match \".+\\\\..+\" config.nextcloud.domain != null";
      description = ''
        Whether to allow HTTPS connections only. If <option>domain</option>
        contains any dots the default is <literal>true</literal>, otherwise
        it's <literal>false</literal>.
      '';
    };

    useACME = lib.mkOption {
      type = types.bool;
      default = cfg.useSSL;
      description = ''
        Whether to use ACME to get a certificate for the domain specified in
        <option>domain</option>. Defaults to <literal>true</literal> if
        <option>useSSL</option> is enabled.
      '';
    };

    port = lib.mkOption {
      type = types.ints.u16;
      default = 443;
      example = 8000;
      description = ''
        If the port number set here is not <literal>80</literal> or
        <literal>443</literal>, generated URLs will explicitly contain the port
        number as part of the URL scheme.

        This is only useful for development/debugging.
      '';
    };

    baseUrl = mkOption {
      type = types.str;
      internal = true;
      readOnly = true;
      description = ''
        This is a concatenation of the scheme, the host and an optional port
        and it's used for internal references from other modules.
      '';
    };

    initialAdminUser = mkOption {
      type = types.str;
      default = "admin";
      example = "horst";
      description = ''
        The initial admin user, which is only relevant for initial deployment.
      '';
    };

    initialAdminPass = mkOption {
      type = types.str;
      default = "admin";
      example = "ohwowsosecure";
      description = ''
        The initial admin password. Make sure to change this as soon as
        possible, because it will end up in the Nix store, which is readable by
        all users on the system.
      '';
    };

    processes = mkOption {
      type = types.ints.unsigned;
      default = if lib.isInt config.nix.maxJobs
                then config.nix.maxJobs * 2
                else 1;
      defaultText = "if lib.isInt config.nix.maxJobs then"
                  + " config.nix.maxJobs * 2 else 1";
      description = "The amount of processes to spawn for uWSGI.";
    };

    previewFileTypes = mkOption {
      type = types.listOf (types.enum [
        "BMP" "Font" "GIF" "HEIC" "Illustrator" "JPEG" "MP3" "MSOffice2003"
        "MSOffice2007" "MSOfficeDoc" "MarkDown" "Movie" "OpenDocument" "PDF"
        "PNG" "Photoshop" "Postscript" "SVG" "StarOffice" "TIFF" "TXT"
        "XBitmap"
      ]);
      default = [
        "BMP" "GIF" "HEIC" "JPEG" "MP3" "MarkDown" "PNG" "TXT" "XBitmap"
      ];
      description = ''
        File types for which to generate previews (eg. thumbnails).

        The ones not enabled by default are disabled due to performance or
        privacy concerns. For example some file types could cause segfaults.
      '';
    };

    preloadOpcache = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to preload PHP's OPcache at build-time.

        <warning><para>This is experimental and might result in errors, for
        example if the shared memory based storage has no more space
        available.</para></warning>
      '';
    };

    theme = mkOption {
      type = types.enum [ "default" "breeze-dark" ];
      default = "default";
      example = "breeze-dark";
      description = ''
        The UI theme to use for this Nextcloud instance.
      '';
    };

    maxUploadSize = mkOption {
      type = types.ints.unsigned;
      default = 512;
      example = 1024;
      description = ''
        The maximum file size allowed in uploads in megabytes.

        <warning><para>Note that this setting also raises the maximum amount of
        memory a single worker process might consume to the value specified
        here.</para></warning>
      '';
    };

    apps = lib.mapAttrs (appId: appinfo: {
      enable = mkOption {
        type = types.bool;
        default = appinfo.meta.defaultEnable or false;
        description = ''
          Whether to enable the ${appinfo.meta.name} (${appinfo.meta.summary})
          application.
        '' + lib.optionalString (appinfo.meta ? homepage) ''
          More information can be found at <link
          xlink:href='${appinfo.meta.homepage}'/>.
        '';
      };

      onlyGroups = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = [ "admin" "special" ];
        description = ''
          If the value is not <literal>null</literal>, enable the app only for
          the groups specified as a list. The groups are created if they do not
          exist.
        '';
      };

      config = mkOption {
        type = types.attrsOf types.str;
        default = {};
        internal = true;
        description = ''
          A set of configuration options to set for this app after it has been
          enabled.
        '';
      };
    } // (extraAppOptions.${appId} or {})) package.applications;

    extraConfig = lib.mkOption {
      type = types.attrsOf types.unspecified;
      default = {};
      example = {
        hashingCost = 50;
        lost_password_link = "disabled";
      };
      description = ''
        Extra options to add to the Nextcloud config file, which will be
        serialised into a PHP array.
      '';
    };

    extraPostPatch = lib.mkOption {
      type = types.lines;
      default = "";
      example = ''
        rm -r apps/comments
      '';
      internal = true;
      description = ''
        Extra shell script lines to append to the <literal>postPatch</literal>
        phase of the Nextcloud main derivation.
      '';
    };

    package = lib.mkOption {
      type = types.package;
      # XXX: Bah, this is so ugly!
      default = pkgs.callPackage package/current {
        inherit (cfg) apps theme extraPostPatch;
      };
      defaultText = "pkgs.callPackage package/current {"
                  + " inherit (cfg) apps theme extraPostPatch;"
                  + "}";
      internal = true;
      description = ''
        The main Nextcloud package to use. Only needed for the upgrade test and
        you shouldn't change this value at all if you don't know what you're
        doing.
      '';
    };
  };

  imports = [ ./systemd-chroot.nix ./libreoffice-online ./gpx ./xmpp ];

  config = {
    assertions = lib.singleton {
      assertion = cfg.apps.bookmarks.enable
               -> !cfg.apps.bookmarks_fulltextsearch.enable;
      message = toString [
        "The 'bookmarks' and 'bookmarks_fulltextsearch' apps are incompatible,"
        "see https://github.com/nextcloud/bookmarks#install"
      ];
    };

    nextcloud.baseUrl = "${urlScheme}://${cfg.domain}${maybePort}";

    services.nginx.virtualHosts.${cfg.domain} = {
      forceSSL = cfg.useSSL;
      enableACME = cfg.useACME;
      extraConfig = ''
        rewrite ^/\.well-known/webfinger /public.php?service=webfinger last;
        rewrite ^/\.well-known/host-meta /public.php?service=host-meta last;
        rewrite ^/\.well-known/host-meta.json
          /public.php?service=host-meta-json last;
        rewrite ^/(oc[ms]-provider) /$1/index.php last;
      '';
      locations = let
        backendConfig = ''
          client_max_body_size ${toString cfg.maxUploadSize}M;
          uwsgi_intercept_errors on;
          uwsgi_request_buffering off;
          include ${config.services.nginx.package}/conf/uwsgi_params;
          uwsgi_param REQUEST_URI $uri$is_args$args;
          uwsgi_pass unix:///run/nextcloud.socket;
        '';
      in {
        "/" = {
          root = staticFiles;
          tryFiles = "$uri $uri$is_args$args /index.php$uri$is_args$args";
          extraConfig = "access_log off;";
        };

        "~ ^/.well-known/(?:card|cal)dav(?:$|/)" = {
          priority = 200;
          extraConfig = "return 301 ${cfg.baseUrl}/remote.php/dav/;";
        };

        "= /ocs/v2.php/apps/end_to_end_encryption/api/v1/public-key" = {
          extraConfig = backendConfig + ''
            uwsgi_param CONTENT_TYPE application/x-www-form-urlencoded;
          '';
        };

        "~ ^/(?:${lib.concatStringsSep "|" entryPoints})\\.php(?:$|/)" = {
          extraConfig = backendConfig;
        };
      };
    };

    users.users.nextcloud = {
      description = "Nextcloud Server User";
      group = "nextcloud";
    };

    users.groups.nextcloud = {};

    systemd.sockets.nextcloud = {
      description = "Nextcloud uWSGI Socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "/run/nextcloud.socket";
        SocketUser = "root";
        SocketGroup = "nginx";
        SocketMode = "0660";
      };
    };

    systemd.timers.nextcloud-cron = {
      description = "Timer For Nextcloud Cron";
      wantedBy = [ "timers.target" ];

      timerConfig.OnBootSec = "5m";
      timerConfig.OnUnitActiveSec = "15m";
    };

    systemd.services.nextcloud-init-db = {
      description = "Nextcloud Database Initialisation";
      requiredBy = [ "nextcloud.service" ];
      requires = [ "postgresql.service" ];
      before = [ "nextcloud.service" ];
      after = [ "postgresql.service" ];

      unitConfig.ConditionPathExists = "!/var/lib/nextcloud/.init-done";
      environment.PGHOST = "/run/postgresql";

      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        RemainAfterExit = true;
        ExecStart = [
          "${postgresql}/bin/createuser nextcloud"
          "${postgresql}/bin/createdb -O nextcloud nextcloud"
          "${postgresql}/bin/psql -1 -f ${nextcloudInit.sql} nextcloud"
        ];
      };
    };

    systemd.services.nextcloud-secrets-init = {
      description = "Nextcloud Secret Values Initialisation";
      requiredBy = [ "nextcloud-init.service" ];
      before = [ "nextcloud-init.service" "nextcloud.service" ];

      unitConfig.ConditionPathExists = "!/var/lib/nextcloud/secrets.env";

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        StateDirectory = "nextcloud";
        StateDirectoryMode = "0710";
        Group = "nextcloud";
        ExecStart = pkgs.writeScript "nextcloud-secrets-init.py" ''
          #!${pkgs.python3Packages.python.interpreter}
          import secrets, string

          LOWER_DIGITS = string.ascii_lowercase + string.digits

          result = {
            'INSTANCEID': "".join(secrets.choice(LOWER_DIGITS)
                                  for i in range(10)),

            # This is deprecated, but let's generate it anyway in case
            # some app still uses this value.
            'PASSWORDSALT': secrets.token_urlsafe(30),

            'SECRET': secrets.token_urlsafe(48),
          }
          lines = ['__NEXTCLOUD_SECRETS_' + key + '="' + val + '"\n'
                   for key, val in result.items()]
          open('/var/lib/nextcloud/secrets.env', 'w').write("".join(lines))
        '';
      };
    };

    systemd.services.nextcloud-init = {
      description = "Nextcloud Data Initialisation";
      requiredBy = [ "nextcloud.service" ];
      requires = [ "nextcloud-init-db.service" ];
      after = [ "nextcloud-init-db.service" ];
      before = [ "nextcloud.service" ];

      unitConfig.ConditionPathExists = "!/var/lib/nextcloud/.init-done";
      environment.NEXTCLOUD_CONFIG_DIR = nextcloudConfigDir;

      serviceConfig = {
        Type = "oneshot";
        User = "nextcloud";
        Group = "nextcloud";
        RemainAfterExit = true;
        PermissionsStartOnly = true;
        StateDirectory = "nextcloud/data";
        EnvironmentFile = "/var/lib/nextcloud/secrets.env";
        ExecStart = let
          tar = "${pkgs.gnutar}/bin/tar";
        in "${tar} xf ${nextcloudInit.data} -C /var/lib/nextcloud/data";
        ExecStartPost =
          "${pkgs.coreutils}/bin/touch /var/lib/nextcloud/.init-done";
      };
    };

    systemd.services.nextcloud-upgrade = {
      description = "Nextcloud Update Actions";
      requiredBy = [ "nextcloud.service" ];
      requires = [ "nextcloud-init-db.service" "nextcloud-init.service" ];
      after = [ "nextcloud-init-db.service" "nextcloud-init.service" ];
      before = [ "nextcloud.service" "nextcloud-cron.service" ];

      environment.NEXTCLOUD_CONFIG_DIR = nextcloudConfigDir;
      environment.__NEXTCLOUD_VERSION = package.version;

      chroot.enable = true;
      chroot.packages = [ pkgs.glibcLocales php nextcloudConfigDir ];

      script = ''
        if [ -e /var/lib/nextcloud/.version ]; then
          __NEXTCLOUD_VERSION="$(< /var/lib/nextcloud/.version)" \
            ${phpCli} ${occ} upgrade
        fi
        ${mkEnableDisableApps "${phpCli} ${occ}" false}
      '';

      postStart = ''
        echo -n ${lib.escapeShellArg package.version} \
          > /var/lib/nextcloud/.version
      '';

      serviceConfig = {
        Type = "oneshot";
        User = "nextcloud";
        Group = "nextcloud";
        RemainAfterExit = true;
        PermissionsStartOnly = true;
        StateDirectory = "nextcloud/data";
        CacheDirectory = [ "nextcloud/uploads" "nextcloud/sessions" ];
        EnvironmentFile = "/var/lib/nextcloud/secrets.env";
        BindReadOnlyPaths = [ "/run/postgresql" "/etc/resolv.conf" ];
        BindPaths = [ "/var/lib/nextcloud" ];
        PrivateNetwork = true;
      };
    };

    systemd.services.nextcloud = {
      description = "Nextcloud Server";
      requires = [ "postgresql.service" ];
      after = [ "network.target" "sockets.target" "postgresql.service" ];

      environment.__NEXTCLOUD_VERSION = package.version;

      chroot.enable = true;
      chroot.packages = [ pkgs.glibcLocales php ];

      serviceConfig = {
        Type = "notify";
        User = "nextcloud";
        Group = "nextcloud";
        StateDirectory = "nextcloud/data";
        CacheDirectory = [ "nextcloud/uploads" "nextcloud/sessions" ];
        EnvironmentFile = "/var/lib/nextcloud/secrets.env";
        ExecStart = "@${uwsgiNextcloud} nextcloud";
        KillMode = "process";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";

        BindReadOnlyPaths = [
          "/run/postgresql" "/run/systemd/notify" "/etc/resolv.conf"
        ];
      };
    };

    systemd.services.nextcloud-cron = {
      description = "Nextcloud Cron";
      requires = [ "nextcloud.service" ];
      after = [ "nextcloud.service" ];

      environment.NEXTCLOUD_CONFIG_DIR = nextcloudConfigDir;
      environment.__NEXTCLOUD_VERSION = package.version;
      environment.SSL_CERT_FILE = caCerts;
      environment.NIX_SSL_CERT_FILE = caCerts;

      chroot.enable = true;
      chroot.packages = [ pkgs.glibcLocales php nextcloudConfigDir caCerts ];

      serviceConfig = {
        Type = "oneshot";
        User = "nextcloud";
        Group = "nextcloud";
        StateDirectory = "nextcloud/data";
        CacheDirectory = [ "nextcloud/uploads" "nextcloud/sessions" ];
        ExecStart = "${php}/bin/php -f ${package}/cron.php";
        EnvironmentFile = "/var/lib/nextcloud/secrets.env";

        BindReadOnlyPaths = [ "/run/postgresql" "/etc/resolv.conf" ];
      };
    };

    environment.systemPackages = [ occUser dbShell ];
  };
}
