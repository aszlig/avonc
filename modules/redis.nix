{ config, pkgs, lib, ... }:

{
  config = lib.mkIf config.nextcloud.enable {
    users.users.nextcloud-redis = {
      description = "nextcloud Redis User";
      group = "nextcloud-redis";
    };

    users.groups.nextcloud-redis = {};

    systemd.sockets.nextcloud-redis = {
      description = "Socket for nextcloud Redis Message Broker";
      wantedBy = [ "sockets.target" ];
      requiredBy = [ "nextcloud-redis.service" ];

      socketConfig = {
        ListenStream = "/run/nextcloud-redis.socket";
        SocketUser = "root";
        SocketGroup = "nextcloud";
        SocketMode = "0660";
      };
    };

    systemd.services.nextcloud-redis = {
      description = "Nextcloud Redis Message Broker";

      confinement.enable = true;

      serviceConfig = {
        Type = "notify";
        ExecStart = lib.escapeShellArgs [
          "${pkgs.ip2unix}/bin/ip2unix" "-r" "port=10,systemd"
          "${pkgs.redis}/bin/redis-server"
          (pkgs.writeText "redis.conf" ''
            bind 127.0.0.1
            port 10
            supervised systemd
            loglevel notice
            logfile ""
            save 300 10
            maxmemory 1gb
            dir /var/lib/nextcloud-redis
          '')
        ];
        User = "nextcloud-redis";
        Group = "nextcloud-redis";
        StateDirectory = "nextcloud-redis";
        BindReadOnlyPaths = [ "/run/systemd/notify" ];
      };
    };
  };
}
