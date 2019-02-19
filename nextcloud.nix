{ pkgs, lib, config, ... }:

let
  inherit (lib) types mkOption;

  cfg = config.nextcloud;

  urlScheme = if cfg.useSSL then "https" else "http";
  maybePort = let
    needsExplicit = !lib.elem cfg.port [ 80 443 ];
  in lib.optionalString needsExplicit ":${toString cfg.port}";
  baseUrl = "${urlScheme}://${cfg.domain}${maybePort}";

  upstreamInfo = lib.importJSON ./deps/upstream.json;

  themeBreezeDark = pkgs.fetchFromGitHub {
    owner = "mwalbeck";
    repo = "nextcloud-breeze-dark";
    rev = "6a1c90ae97f6b60772ce7756e77d3d2b6b2b41df";
    sha256 = "0sdzscz2pq7g674inkc6cryqsdnrpin2hsvvaqzngld6vp1z7h04";
  };

  occUser = pkgs.writeScriptBin "nextcloud-occ" ''
    #!${pkgs.stdenv.shell} -e
    export NEXTCLOUD_CONFIG_DIR=${lib.escapeShellArg nextcloudConfigDir}
    set -a
    source /var/lib/nextcloud/secrets.env
    set +a
    exec ${lib.escapeShellArg "${pkgs.utillinux}/bin/runuser"} \
      -u nextcloud -g nextcloud -- ${phpCli} \
      ${lib.escapeShellArg "${package}/occ"} \
      "$@"
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
        "-d" "display_errors=stderr"
      ]} -d "opcache.file_cache=$out" "$1" &> /dev/null || :
    '';
  } ''
    mkdir "$out"
    "$preloader" "$package/occ"
    find "$package" -type f -name '*.php' -print0 \
      | xargs -0 -P "$NIX_BUILD_CORES" -n1 "$preloader"
    chmod -R go+rX "$out"
  '';

  commonPhpConfig = [
    "expose_php=false"
    "extension=${phpPackages.apcu}/lib/php/extensions/apcu.so"
    "extension=${phpPackages.imagick}/lib/php/extensions/imagick.so"
    "opcache.enable=1"
    "opcache.enable_cli=1"
    "opcache.interned_strings_buffer=8"
    "opcache.max_accelerated_files=10000"
    "opcache.memory_consumption=128"
    "opcache.revalidate_freq=1"
    "opcache.save_comments=1"
    "opcache.validate_timestamps=0"
    "pgsql.allow_persistent=1"
    "pgsql.auto_reset_persistent=0"
    "pgsql.ignore_notice=0"
    "pgsql.log_notice=0"
    "pgsql.max_links=-1"
    "pgsql.max_persistent=-1"
    "post_max_size=1000M"
    "upload_max_filesize=1000M"
    "zend_extension=opcache.so"
  ] ++ lib.optionals cfg.preloadOpcache [
    "opcache.file_cache=${opcache}"
    "opcache.file_cache_consistency_checks=0"
    "opcache.validate_permission=0"
  ];

  phpCli = let
    mkArgs = lib.concatMapStringsSep " " (opt: "-d ${lib.escapeShellArg opt}");
    escPhp = lib.escapeShellArg "${php}/bin/php";
  in escPhp + " " + mkArgs (commonPhpConfig ++ [ "memory_limit=512M" ]);

  # NixOS options that are merged with the existing appids.
  extraAppOptions = {};

  package = pkgs.stdenv.mkDerivation rec {
    name = "nextcloud-${version}";
    inherit (upstreamInfo.nextcloud) version;

    src = pkgs.fetchzip {
      inherit (upstreamInfo.nextcloud) url sha256;
    };

    configurePhase = let
      inherit (upstreamInfo) applications;
      isEnabled = name: cfg.apps.${name}.enable;
      enabledApps = lib.filter isEnabled (lib.attrNames applications);
      appPaths = lib.genAttrs enabledApps (name: pkgs.fetchzip {
        inherit (applications.${name}) url sha256;
      });
    in lib.concatStrings (lib.mapAttrsToList (appid: path: ''
      cp -TR ${lib.escapeShellArg path} apps/${lib.escapeShellArg appid}
    '') appPaths);

    buildPhase = lib.optionalString (cfg.theme == "breeze-dark") ''
      cp -TR ${lib.escapeShellArg themeBreezeDark} themes/nextcloud-breeze-dark
    '';

    patches = [
      patches/no-config-uid-check.patch
      patches/executable-lookup.patch
    ];

    # Nextcloud checks whether the user matches the webserver user by comparing
    # the current userid with the owner of config.php. In our case however, the
    # config.php is inside the Nix store so it most certainly isn't owned by
    # the nextcloud user.
    postPatch = ''
      sed -i -e 's/${
        "\\($configUser *= *\\).*fileowner(.*config.php.*)"
      }/\1$user/g' cron.php console.php
    '';

    installPhase = "mkdir -p \"\$out/\"\ncp -R . \"$out/\"";

    meta = {
      description = "Sharing solution for files, calendars, contacts and more";
      homepage = https://nextcloud.com;
      license = lib.licenses.agpl3Plus;
    };
  };

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

  fullVersion = let
    isShort = builtins.match "([0-9]+\\.){2}[0-9]+" package.version != null;
  in if isShort then "${package.version}.0" else package.version;

  # All of the static files we can serve as-is without going through PHP.
  staticFiles = pkgs.runCommand "nextcloud-static" {
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
  ];

  nextcloudConfigDir = let
    nextcloudConfig = mkPhpConfig ({
      instanceid.__fromEnv = "__NEXTCLOUD_SECRETS_INSTANCEID";
      passwordsalt.__fromEnv = "__NEXTCLOUD_SECRETS_PASSWORDSALT";
      secret.__fromEnv = "__NEXTCLOUD_SECRETS_SECRET";

      trusted_domains = [];
      datadirectory = "/var/lib/nextcloud/data";
      version = fullVersion; # FIXME: Should be set at runtime!
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
      "overwrite.cli.url" = "/"; # XXX: maybe? baseUrl;
      "htaccess.RewriteBase" = "/";
      "htaccess.IgnoreFrontController" = true;

      updatechecker = false;
      connectivity_check_domains = [ "headcounter.org" "moonid.net" ];
      check_for_working_wellknown_setup = false;
      check_for_working_htaccess = false;
      config_is_read_only = true;

      log_type = "errorlog";
      "auth.bruteforce.protection.enabled" = false; # XXX: Remove me!
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
      in lib.optionalString isNeeded "${pkgs.libreoffice}/bin/libreoffice";

      # openssl.config = "... ECDSA maybe?"; # XXX

      "memcache.local" = "\\OC\\Memcache\\APCu";

      supportedDatabases = [ "pgsql" ];
      tempdirectory = "/tmp"; # TODO: NOT /tmp, because large files!
      hashingCost = 10; # FIXME: There are also other options we need to set
                        #        via php.ini

      # By default this contains '.htaccess', but our web server doesn't parse
      # these files, so we can safely allow them.
      blacklisted_files = [];
      cipher = "AES-256-CFB";

      "upgrade.disable-web" = true;
      # data-fingerprint = ???; XXX: Figure out!

    } // lib.optionalAttrs (cfg.theme != "default") {
      theme = "nextcloud-${cfg.theme}";
    });
  in pkgs.writeTextFile {
    name = "nextcloud-config";
    text = nextcloudConfig;
    destination = "/config.php";
    checkPhase = "${php}/bin/php -l \"$out/config.php\"";
  };

  nextcloudInit = pkgs.runCommand "nextcloud-init" {
    nativeBuildInputs = [
      postgresql php pkgs.glibcLocales
    ];
    outputs = [ "out" "sql" "data" ];
    nextcloud = package;
    adminUser = "admin"; # XXX
    adminPass = "foobar"; # XXX
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

    ${phpCli} "$nextcloud/occ" maintenance:install \
      --database pgsql \
      --database-name nextcloud \
      --database-host $TMPDIR \
      --database-user nextcloud \
      --admin-user "$adminUser" \
      --admin-pass "$adminPass" \
      --data-dir "$PWD/data"

    ${phpCli} "$nextcloud/occ" app:enable encryption
    ${phpCli} "$nextcloud/occ" background:cron
    ${phpCli} "$nextcloud/occ" db:convert-filecache-bigint

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
        env = "NEXTCLOUD_CONFIG_DIR=${nextcloudConfigDir}";
        master = true;
        php-allowed-script = map (name: "${package}/${name}.php") entryPoints;
        php-index = "index.php";
        php-docroot = package;
        php-sapi-name = "apache";
        php-set = commonPhpConfig ++ [ "display_errors=stderr" ];
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

    apps = lib.mapAttrs (appId: appinfo: {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable the ${appinfo.meta.name} (${appinfo.meta.summary})
          application.
        '' + lib.optionalString (appinfo.meta ? homepage) ''
          More information can be found at <link
          xlink:href='${appinfo.meta.homepage}'/>.
        '';
      };
    } // (extraAppOptions.${appId} or {})) upstreamInfo.applications;
  };

  config = {
    services.nginx.virtualHosts.${cfg.domain} = {
      forceSSL = cfg.useSSL;
      enableACME = cfg.useACME;
      extraConfig = ''
        error_page 403 ${baseUrl}/;
        error_page 404 ${baseUrl}/;
      '';
      locations = {
        "/" = {
          root = staticFiles;
          tryFiles = "$uri $uri$is_args$args /index.php$uri$is_args$args";
          extraConfig = "access_log off;";
        };

        "= /.well-known/host-meta" = {
          extraConfig = "rewrite ^ /public.php?service=host-meta;";
        };

        "= /.well-known/host-meta.json" = {
          extraConfig = "rewrite ^ /public.php?service=host-meta-json;";
        };

        "= /.well-known/webfinger" = {
          extraConfig = "rewrite ^ /public.php?service=webfinger;";
        };

        "= /.well-known/carddav" = {
          extraConfig = "return 301 ${baseUrl}/remote.php/dav;";
        };

        "= /.well-known/caldav" = {
          extraConfig = "return 301 ${baseUrl}/remote.php/dav;";
        };

        "~ ^/(?:${lib.concatStringsSep "|" entryPoints})\\.php(?:$|/)" = {
          extraConfig = ''
            uwsgi_intercept_errors on;
            uwsgi_pass unix:///run/nextcloud.socket;
          '';
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
          occ = lib.escapeShellArg "${package}/occ";
        in [
          "${tar} xf ${nextcloudInit.data} -C /var/lib/nextcloud/data"
          "${phpCli} ${occ} encryption:enable"
        ];
        ExecStartPost =
          "${pkgs.coreutils}/bin/touch /var/lib/nextcloud/.init-done";
      };
    };

    systemd.services.nextcloud = {
      description = "Nextcloud Server";
      requires = [ "postgresql.service" ];
      after = [ "network.target" "sockets.target" "postgresql.service" ];

      serviceConfig = {
        Type = "notify";
        User = "nextcloud";
        Group = "nextcloud";
        StateDirectory = "nextcloud/data";
        EnvironmentFile = "/var/lib/nextcloud/secrets.env";
        ExecStart = "@${uwsgiNextcloud} nextcloud";
        KillMode = "process";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        PrivateTmp = true;
      };
    };

    systemd.services.nextcloud-cron = {
      description = "Nextcloud Cron";
      requires = [ "nextcloud.service" ];
      after = [ "nextcloud.service" ];

      environment.NEXTCLOUD_CONFIG_DIR = nextcloudConfigDir;
      serviceConfig.Type = "oneshot";
      serviceConfig.User = "nextcloud";
      serviceConfig.Group = "nextcloud";
      serviceConfig.ExecStart = "${php}/bin/php -f ${package}/cron.php";
      serviceConfig.EnvironmentFile = "/var/lib/nextcloud/secrets.env";
      serviceConfig.PrivateTmp = true;
    };

    environment.systemPackages = [ occUser dbShell ];
  };
}
