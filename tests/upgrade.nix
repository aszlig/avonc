import ./make-test.nix (pkgs: {
  name = "nextcloud-upgrade";

  nodes = let
    common = { options, pkgs, ... }: {
      nextcloud.enable = true;
      nextcloud.domain = "localhost";

      services.nginx.enable = true;
      services.postgresql.enable = true;
      systemd.services.postgresql.environment = {
        LD_PRELOAD = "${pkgs.libeatmydata}/lib/libeatmydata.so";
      };

      environment.systemPackages = [ pkgs.jq ];
      virtualisation.memorySize = 1024;
    };

  in {
    generation1 = { lib, options, config, pkgs, ... }: {
      imports = [ common ];

      nextcloud.majorVersion = 17;

      nextcloud.apps = let
        nc17apps = (lib.importJSON ../packages/17/upstream.json).applications;

        excludedApps = [
          # We'll need dpendency ordering for this app
          "auto_mail_accounts"
          # Needs /usr/bin/clamscan
          "files_antivirus"
          # Broken upgrade routine across major versions
          "files_external_dropbox"
          # Upstream URL very unstable
          "files_external_gdrive"
          # Needs PHP's inotify extension
          "files_inotify"
          # Needs the OAuth library
          "grauphel"
          # Only works with MyQSL
          "sensorlogger"
          # Windows only (at least it seems)
          "sharepoint"
          # Seems to be incompatible with PostgreSQL
          "twofactor_admin"
          # Needs "user_backend_sql_raw" in config
          "user_backend_sql_raw"
          # Needs write access to to "apps/cms_pico/appdata_public/".
          "cms_pico"
          # XXX: Currently (2019-12-12) results in HTTP 404
          "emlviewer"
          # XXX: Conflicts with the "news" app - investigate this someday.
          "files_mindmap"

          # These apps have non-deterministic download URLs
          "occweb"
          "quicknotes"
          "spgverein"
          "twainwebscan"
          "twofactor_yubikey"

          # Will be enabled later
          "spreed"
          "richdocuments"
        ];
        enableApp = name: let
          isExcluded = lib.elem name excludedApps;
        in lib.const (lib.optionalAttrs (!isExcluded) {
          enable = true;
        });
      in lib.mapAttrs enableApp nc17apps;
    };

    generation2 = { lib, nodes, ... }: {
      imports = [ common ];

      systemd.services.libreoffice-online.enable = false;
      systemd.services.mongooseim.enable = false;

      nextcloud.apps = let
        # XXX: These apps are unsupported in Nextcloud 18.
        forceEnabled = lib.genAttrs [
          "social"
        ] (lib.const { forceEnable = true; enable = true; });

        enabled = lib.genAttrs [
          "apporder" "bookmarks" "calendar" "circles" "contacts" "deck"
          "external" "end_to_end_encryption" "files_accesscontrol"
          "files_markdown" "files_rightclick" "gpxpod" "groupfolders" "mail"
          "metadata" "news" "passwords" "polls" "phonetrack" "richdocuments"
          "spreed" "tasks"
        ] (lib.const { enable = true; });

      in forceEnabled // enabled;
    };
  };

  testScript = { nodes, ... }: let
    switchToGeneration = gen: let
      node = "generation${toString gen}";
      inherit (nodes.${node}.config.system.build) toplevel;
      switchCmd = "${toplevel}/bin/switch-to-configuration test";
    in ''
      $machine->nest('switch to generation ${toString gen}', sub {
        $machine->succeed('${switchCmd} >&2');
        $main::machine = ''$${node};
      });
    '';

    expectedAppsPerlHash = let
      inherit (pkgs.lib) attrNames filterAttrs const escape;
      inherit (nodes.generation2.config.nextcloud) apps;
      alwaysEnabled = [
        "cloud_federation_api" "dav" "federatedfilesharing" "files"
        "lookup_server_connector" "oauth2" "provisioning_api" "settings"
        "twofactor_backupcodes" "viewer" "workflowengine"
      ];
      enabled = attrNames (filterAttrs (const (x: x.enable)) apps);
      allEnabled = enabled ++ alwaysEnabled;
      mkHash = val: "'${escape ["\\" "'"] val}' => 1";
    in "(${pkgs.lib.concatMapStringsSep ", " mkHash allEnabled})";

  in ''
    my $machine = $generation1;

    $machine->waitForUnit('multi-user.target');

    $machine->startJob('nextcloud.service');
    $machine->waitForUnit('nextcloud.service');

    $machine->succeed(
      'curl -L http://localhost/ | grep -o "a safe home for all your data"'
    );

    ${switchToGeneration 2}
    $machine->startJob('nextcloud.service');
    $machine->waitForUnit('nextcloud.service');

    $machine->succeed(
      'curl -L http://localhost/ | grep -o initial-state-core-loginUsername'
    );

    my $applist = $machine->succeed('nextcloud-occ app:list --output=json'
                                   .' | jq -r ".enabled | keys[] | @text"');

    my %expected = ${expectedAppsPerlHash};
    my %actual = map { $_ => 1 } split "\n", $applist;
    use Test::More tests => 1;
    is_deeply(\%actual, \%expected, 'enabled apps should match with config');
  '';
})
