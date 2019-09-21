{ config, pkgs, lib, ... }:

let
  inherit (lib) mkOption types;
  cfg = config.nextcloud.apps.maps;

  osrm-backend = pkgs.osrm-backend.overrideAttrs (drv: {
    # XXX: Currently a limitation of ip2unix.
    NIX_CFLAGS_COMPILE = "-DBOOST_ASIO_DISABLE_EPOLL";
  });

  profileData = pkgs.runCommand "osrm-profiles" {
    inherit (cfg) osmDataset;
    profilesDir = "${osrm-backend}/share/osrm/profiles";
    nativeBuildInputs = [ osrm-backend ];
  } ''
    ${lib.concatMapStrings (profile: ''
      profile=${lib.escapeShellArg profile}
      ln -s "$osmDataset" "$profile.osm.pbf"
      osrm-extract -p "$profilesDir/$profile.lua" "$profile.osm.pbf"
      osrm-partition "$profile.osrm"
      osrm-customize "$profile.osrm"
      install -vD -m 0644 "$profile.osrm" "$out/$profile.osrm"
      for i in "$profile.osrm".*; do
        install -vD -m 0644 "$i" "$out/$i"
      done
    '') cfg.profiles}

  '';

  availableProfiles = [ "foot" "bicycle" "car" ];
  mkUnitName = profile: "nextcloud-osrm-${profile}";

  genProfileUnits = fun: let
    generate = name: lib.nameValuePair (mkUnitName name) (fun name);
  in lib.listToAttrs (map generate cfg.profiles);

in {
  options.nextcloud.apps.maps = {
    osmDataset = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        The OpenStreetMap dataset as a PBF file to use for routing or
        <literal>null</literal> to disable running the routing service.

        <note><para>Enable this only if you have sufficient resources on the
        machine, especially the <literal>planet</literal> data set will consume
        way over 100 GB of memory just to build.</para></note>
      '';
    };

    profiles = mkOption {
      type = types.listOf (types.enum availableProfiles);
      default = availableProfiles;
      # Deduplicate and sort, we want this to be deterministic even if the
      # module definition order/prio is changed to avoid regenerating the data.
      apply = ps: lib.attrNames (lib.genAttrs ps (lib.const null));
      description = ''
        The available routing profiles available, which can help bring down
        runtime memory requirements if you don't need all routing options.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    { nextcloud.extraPostPatch = ''
        patch -p1 -d apps/maps < ${./proxy-routing.patch}
      '';
    }
    (lib.mkIf (cfg.osmDataset != null && cfg.profiles != []) {
      nextcloud.apps.maps.config = let
        urlOptions = {
          car     = "osrmCarURL";
          bicycle = "osrmBikeURL";
          foot    = "osrmFootURL";
        };
        mkInternal = profile: {
          name = urlOptions.${profile};
          value = "internal";
        };
      in lib.listToAttrs (map mkInternal cfg.profiles);

      users.users.nextcloud-osrm = {
        description = "Nextcloud OSRM User";
        group = "nextcloud-osrm";
      };

      users.groups.nextcloud-osrm = {};

      nextcloud.extraPostPatch = ''
        patch -p1 -d apps/maps < ${pkgs.substituteAll {
          src = ./unix-sockets.patch;
          unixSocketMap = let
            mkPhpString = value: "'${lib.escape ["\\" "'"] value}'";
            mkEntry = profile: let
              sockPath = "/run/nextcloud-osrm-${profile}.sock";
            in "${mkPhpString profile} => ${mkPhpString sockPath}";
          in "[${lib.concatMapStringsSep ", " mkEntry cfg.profiles}]";
        }}
      '';

      systemd.sockets = genProfileUnits (profile: {
        description = "OSRM Socket for Profile ${profile}";
        requiredBy = [ "nextcloud.service" "${mkUnitName profile}.service" ];
        before = [ "nextcloud.service" ];

        socketConfig = {
          ListenStream = "/run/nextcloud-osrm-${profile}.sock";
          SocketUser = "root";
          SocketGroup = "nextcloud";
          SocketMode = "0660";
        };
      });

      systemd.services = {
        nextcloud.serviceConfig.BindPaths =
          map (profile: "/run/nextcloud-osrm-${profile}.sock") cfg.profiles;
      } // genProfileUnits (profile: {
        description = "OSRM Service for Profile ${profile}";
        wantedBy = [ "multi-user.target" ];

        confinement.enable = true;
        confinement.binSh = null;

        serviceConfig.SystemCallErrorNumber = "EPERM";
        serviceConfig.SystemCallFilter = [
          "@basic-io" "@io-event" "@file-system" "@timer" "@process"
          "@signal" "@network-io" "mprotect" "~listen" "~bind" "~connect"
          "ioctl"
        ];

        serviceConfig.PrivateNetwork = true;
        serviceConfig.User = "nextcloud-osrm";
        serviceConfig.Group = "nextcloud-osrm";
        serviceConfig.ExecStart = let
        in lib.escapeShellArgs [
          "${pkgs.ip2unix}/bin/ip2unix" "-r" "in,systemd" "-r" "reject"
          "${osrm-backend}/bin/osrm-routed" "--algorithm" "MLD"
          "${profileData}/${profile}.osrm"
        ];
      });
    })
  ]);
}
