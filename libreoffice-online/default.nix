{ config, pkgs, lib, ... }:

let
  cfg = config.nextcloud.apps.richdocuments;
  package = import ./package.nix { inherit pkgs lib; };

  fontConfig = pkgs.makeFontsConf {
    fontDirectories = [
      "${pkgs.ghostscript}/share/ghostscript/fonts"
      pkgs.dejavu_fonts
      pkgs.freefont_ttf
      pkgs.gyre-fonts
      pkgs.liberation_ttf
      pkgs.noto-fonts
      pkgs.noto-fonts-emoji
      pkgs.unifont
      pkgs.xorg.fontbh100dpi
      pkgs.xorg.fontbhlucidatypewriter100dpi
      pkgs.xorg.fontbhlucidatypewriter75dpi
      pkgs.xorg.fontcursormisc
      pkgs.xorg.fontmiscmisc
    ];
  };

  genOptionFlags = attrs: let
    mkVal = val: if val == true then "true"
                 else if val == false then "false"
                 else val;
    mkPair = keys: val: "--o:${lib.concatStringsSep "." keys}=${mkVal val}";
    isVal = x: lib.isDerivation x || lib.isString x || lib.isBool x;
    transformArgs = lib.mapAttrsRecursiveCond (x: !isVal x) mkPair;
  in lib.escapeShellArgs (lib.collect isVal (transformArgs attrs));

  settings = {
    file_server_root_path = "${package}/share/libreoffice-online";
    tile_cache_path = "/var/cache/libreoffice-online/tiles";
    lo_template_path = "${package.sdk}/lib/libreoffice";
    child_root_path = "/var/cache/libreoffice-online/roots";
    storage.wopi."host[0]" = config.nextcloud.domain;
    logging.level = cfg.logLevel;
    net.listen = "systemd";
    ssl.enable = false;
    ssl.termination = true;
  };

  # TODO: Remove this as soon as it is in the oldest nixpkgs version we
  #       support.
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

  richdocumentsPatch = pkgs.runCommand "richdocuments-substituted.patch" {
    nativeBuildInputs = lib.singleton (pkgs.writeScriptBin "extract-disco" ''
      #!${pkgs.python3Packages.python.interpreter}
      import sys
      from xml.etree import ElementTree as ET

      xml = ET.parse(sys.argv[1]).getroot()
      assert xml.tag == 'wopi-discovery'
      mimetypes = set()
      for app in xml.iterfind('./net-zone/app'):
          mimetypes.add(app.get('name'))
      array = ["'" + mt.replace('\\', '\\\\').replace("'", "\\'") + "'"
               for mt in mimetypes]
      sys.stdout.write('[' + ', '.join(array) + ']')
    '');
    discoveryXml = "${package.src}/discovery.xml";
    loolLeafletUrl = "${config.nextcloud.baseUrl}/loleaflet/"
                   + "${package.versionHash}/loleaflet.html?";
    patch = patches/richdocuments.patch;
  } ''
    loolMimeTypesArray="$(extract-disco "$discoveryXml")"
    substitute "$patch" "$out" \
      --subst-var-by LOOL_MIME_TYPES_ARRAY "$loolMimeTypesArray" \
      --subst-var-by LOOL_LEAFLET_URL "$loolLeafletUrl"
  '';

in {
  options.nextcloud.apps.richdocuments = {
    logLevel = lib.mkOption {
      type = lib.types.enum [
        "none" "fatal" "critical" "error" "warning" "notice" "information"
        "debug" "trace"
      ];
      default = "warning";
      example = "trace";
      description = ''
        The logging level for the LibreOffice Online instance.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nextcloud.extraPostPatch = ''
      rm apps/richdocuments/lib/Backgroundjobs/ObtainCapabilities.php \
         apps/richdocuments/lib/Service/CapabilitiesService.php \
         apps/richdocuments/lib/WOPI/Parser.php \
         apps/richdocuments/lib/WOPI/DiscoveryManager.php
      patch -p1 -d apps/richdocuments < ${richdocumentsPatch}
    '';

    nextcloud.apps.richdocuments.config.wopi_url = config.nextcloud.baseUrl;

    users.users.libreoffice-online = {
      description = "LibreOffice Online User";
      group = "libreoffice-online";
    };

    users.groups.libreoffice-online = {};

    services.nginx.virtualHosts.${config.nextcloud.domain} = {
      # This is needed for LibreOffice Online to connect back to the Nextcloud
      # instance.
      extraConfig = ''
        listen unix:/run/libreoffice-online/internal.socket${
          lib.optionalString config.nextcloud.useSSL " ssl"
        };
      '';
      locations = let
        commonConfig = {
          priority = 200;
          proxyPass = "http://unix:/run/libreoffice-online.socket:";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
          '';
        };

      in {
        "= /loleaflet/${package.versionHash}/loleaflet.html" = commonConfig;
        "^~ /loleaflet/${package.versionHash}" = {
          priority = 200;
          alias = "${package}/share/libreoffice-online/loleaflet/dist";
        };

        "~ ^/lool" = commonConfig;
        "~ ^/lool/(?:.*)/ws$" = commonConfig // {
          priority = 100;
          extraConfig = commonConfig.extraConfig + ''
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "Upgrade";
          '';
        };
      };
    };

    systemd.services.libreoffice-online-internal-sockdir = {
      description = "Prepare LibreOffice Online Internal Socket Directory";
      requiredBy = [ "nginx.service" "libreoffice-online.service" ];
      before = [ "nginx.service" ];

      unitConfig.ConditionPathExists = "!/run/libreoffice-online";

      serviceConfig.RuntimeDirectory = "libreoffice-online";
      serviceConfig.RuntimeDirectoryMode = "0710";
      serviceConfig.RuntimeDirectoryPreserve = true;
      serviceConfig.User = "nginx";
      serviceConfig.Group = "libreoffice-online";
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
      serviceConfig.Type = "oneshot";
    };

    systemd.sockets.libreoffice-online = {
      description = "LibreOffice Online Socket";
      wantedBy = [ "sockets.target" ];

      socketConfig = {
        ListenStream = "/run/libreoffice-online.socket";
        SocketUser = "root";
        SocketGroup = "nginx";
        SocketMode = "0660";
      };
    };

    systemd.services.libreoffice-online = {
      description = "LibreOffice Online";
      after = [ "nginx.service" ];

      environment.JAVA_HOME = package.sdk.jdk;
      environment.FONTCONFIG_FILE = fontConfig;
      environment.LOOL_NIX_STORE_PATHS_FILE = "${pkgs.closureInfo {
        rootPaths = [
          package.sdk fontConfig pkgs.glibcLocales package.sdk.jdk
        ];
      }}/store-paths";

      serviceConfig = {
        User = "libreoffice-online";
        Group = "libreoffice-online";
        ExecStart = toString [
          "${ip2unix}/bin/ip2unix"
          "-r out,port=9981,ignore"
          "-r out,path=/run/libreoffice-online/internal.socket"
          "${package}/bin/loolwsd ${genOptionFlags settings}"
        ];
        CacheDirectory = [
          "libreoffice-online/tiles"
          "libreoffice-online/sys"
          "libreoffice-online/roots"
        ];
        AmbientCapabilities = [
          "CAP_FOWNER"
          "CAP_MKNOD"
          "CAP_SYS_CHROOT"
          "CAP_SYS_ADMIN"
        ];
        Restart = "on-failure";
        PrivateMounts = true;
        PrivateNetwork = true;
      };
    };
  };
}
