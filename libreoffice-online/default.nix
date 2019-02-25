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

in {
  users.users.libreoffice-online = {
    description = "LibreOffice Online User";
    group = "libreoffice-online";
  };

  users.groups.libreoffice-online = {};

  services.nginx.virtualHosts.${config.nextcloud.domain}.locations = let
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

  systemd.sockets.libreoffice-online-proxy = {
    description = "LibreOffice Online Proxy Socket";
    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "/run/libreoffice-online-proxy.socket";
      SocketUser = "root";
      SocketGroup = "libreoffice-online";
      SocketMode = "0660";
    };
  };

  systemd.services.libreoffice-online-proxy = {
    description = "LibreOffice Online Proxy To Nextcloud";
    requiredBy = [ "libreoffice-online-proxy-internal.service" ];
    after = [ "libreoffice-online-proxy-internal.service" ];

    serviceConfig = {
      User = "libreoffice-online";
      Group = "libreoffice-online";
      ExecStart = toString [
        "${config.systemd.package}/lib/systemd/systemd-socket-proxyd"
        "127.0.0.1:80"
      ];
      Restart = "on-failure";
    };
  };

  systemd.services.libreoffice-online-proxy-internal = {
    description = "LibreOffice Online Proxy To Root Namespace";
    requiredBy = [ "libreoffice-online.service" ];
    before = [ "libreoffice-online.service" ];

    serviceConfig = {
      User = "libreoffice-online";
      Group = "libreoffice-online";
      ExecStart = toString [
        "${pkgs.socat}/bin/socat"
        "TCP-LISTEN:8000,fork,reuseaddr"
        "UNIX_CONNECT:/run/libreoffice-online-proxy.socket"
      ];
      Restart = "on-failure";

      # Note that these namespaces apply to the main unit as well!
      PrivateMounts = true;
      PrivateNetwork = true;
    };
  };

  systemd.services.libreoffice-online = {
    description = "LibreOffice Online";
    wantedBy = [ "multi-user.target" ];

    environment.JAVA_HOME = package.sdk.jdk;
    environment.LOOL_NIX_STORE_PATHS_FILE = "${pkgs.closureInfo {
      rootPaths = [ package.sdk chrootEtc pkgs.glibcLocales package.sdk.jdk ];
    }}/store-paths";
    # XXX: URL SCHEME!
    environment.http_proxy = "http://127.0.0.1:8000";

    serviceConfig = {
      User = "libreoffice-online";
      Group = "libreoffice-online";
      ExecStart = "${package}/bin/loolwsd ${optionFlags}";
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
      JoinsNamespaceOf = "libreoffice-online-proxy-internal.service";
    };
  };
}
