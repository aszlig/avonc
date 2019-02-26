{ config, pkgs, lib, ... }:

let
  package = import ./package.nix { inherit pkgs lib; };

  chrootEtc = (import <nixpkgs/nixos> {
    configuration = {};
  }).config.system.build.etc;

  genOptionFlags = attrs: let
    mkPair = keys: val: "--o:${lib.concatStringsSep "." keys}=${val}";
    isVal = x: lib.isDerivation x || lib.isString x;
    transformArgs = lib.mapAttrsRecursiveCond (x: !isVal x) mkPair;
  in lib.escapeShellArgs (lib.collect isVal (transformArgs attrs));

  optionFlags = genOptionFlags {
    file_server_root_path = "${package}/share/libreoffice-online";
    tile_cache_path = "/var/cache/libreoffice-online/tiles";
    lo_template_path = "${package.sdk}/lib/libreoffice";
    # XXX: Should be empty or even better: Remove the code!
    sys_template_path = chrootEtc;
    child_root_path = "/var/cache/libreoffice-online/roots";
    server_name = let
      # XXX: Make this DRY, it's from ../nextcloud.nix!
      maybePort = let
        needsExplicit = !lib.elem config.nextcloud.port [ 80 443 ];
      in lib.optionalString needsExplicit ":${toString config.nextcloud.port}";
    in "${config.nextcloud.domain}${maybePort}";
    storage.wopi."host[0]" = "dnyarri";
    logging.level = "trace";
    net.listen = "systemd";
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
    discoveryXml = "${package}/share/libreoffice-online/discovery.xml";
    loolLeafletUrl = "${config.nextcloud.baseUrl}/loleaflet/"
                   + "${package.versionHash}/loleaflet.html?";
    patch = ./richdocuments.patch;
  } ''
    loolMimeTypesArray="$(extract-disco "$discoveryXml")"
    substitute "$patch" "$out" \
      --subst-var-by LOOL_MIME_TYPES_ARRAY "$loolMimeTypesArray" \
      --subst-var-by LOOL_LEAFLET_URL "$loolLeafletUrl"
  '';

in {
  config = lib.mkIf config.nextcloud.apps.richdocuments.enable {
    nextcloud.extraPostPatch = ''
      rm apps/richdocuments/lib/Backgroundjobs/ObtainCapabilities.php \
         apps/richdocuments/lib/Service/CapabilitiesService.php \
         apps/richdocuments/lib/WOPI/Parser.php \
         apps/richdocuments/lib/WOPI/DiscoveryManager.php
      patch -p1 -d apps/richdocuments < ${richdocumentsPatch}
    '';

    users.users.libreoffice-online = {
      description = "LibreOffice Online User";
      group = "libreoffice-online";
    };

    users.groups.libreoffice-online = {};

    services.nginx.virtualHosts.${config.nextcloud.domain} = {
      # This is needed for LibreOffice Online to connect back to the Nextcloud
      # instance.
      extraConfig = ''
        listen unix:/run/libreoffice-online-internal.socket;
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
        "^~ /loleaflet" = commonConfig;
        "^~ /hosting/discovery" = commonConfig;
        "^~ /hosting/capabilities" = commonConfig;
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
      wantedBy = [ "multi-user.target" ];
      after = [ "nginx.service" ];

      environment.JAVA_HOME = package.sdk.jdk;
      environment.LOOL_NIX_STORE_PATHS_FILE = "${pkgs.closureInfo {
        rootPaths = [
          package.sdk chrootEtc pkgs.glibcLocales package.sdk.jdk
        ];
      }}/store-paths";

      serviceConfig = {
        User = "libreoffice-online";
        Group = "libreoffice-online";
        ExecStart = toString [
          "${ip2unix}/bin/ip2unix"
          "-r out,port=9981,ignore"
          "-r out,path=/run/libreoffice-online-internal.socket"
          "${package}/bin/loolwsd ${optionFlags}"
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
