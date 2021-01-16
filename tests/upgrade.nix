import ./make-test.nix (pkgs: {
  name = "nextcloud-upgrade";

  machine = { config, lib, pkgs, ... }: {
    nextcloud.enable = true;
    nextcloud.domain = "localhost";
    nextcloud.majorVersion = lib.mkDefault 19;

    services.nginx.enable = true;
    services.postgresql.enable = true;
    systemd.services.postgresql.environment = {
      LD_PRELOAD = "${pkgs.libeatmydata}/lib/libeatmydata.so";
    };

    virtualisation.memorySize = 1024;

    system.extraSystemBuilderCmds = let
      isEnabled = lib.const (x: x.enable);
      enabledApps = lib.filterAttrs isEnabled config.nextcloud.apps;
      alwaysEnabled = [
        "cloud_federation_api" "dav" "federatedfilesharing" "files"
        "lookup_server_connector" "oauth2" "provisioning_api" "settings"
        "twofactor_backupcodes" "viewer" "workflowengine"
      ];
      json = builtins.toJSON (lib.attrNames enabledApps ++ alwaysEnabled);
    in "echo ${lib.escapeShellArg json} > \"$out/nc-enabled-apps.json\"";

    nesting.clone = let
      nc19apps = (lib.importJSON ../packages/19/upstream.json).applications;

      excludedApps = [
        # We'll need dpendency ordering for this app
        "auto_mail_accounts"
        # Needs Perl
        "camerarawpreviews"
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
        # Needs to have an LDAP provide
        "ldap_write_support"
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
        # No OCC support, since it requires $_SERVER['REQUEST_URI']
        "sendent"
        # Needs the "sqreen" library
        "sqreen_sdk"
        # XXX: Currently (2019-12-12) results in HTTP 404
        "emlviewer"
        # XXX: Conflicts with the "news" app - investigate this someday.
        "files_mindmap"
        # XXX: Hash mismatch in upstream URL
        "tencentcloudcosconfig"

        # XXX: Requires pdlib and thus module system integration for PHP
        #      extensions.
        "facerecognition"

        # XXX: Requires GnuPG
        "gpgmailer"

        # We already have a LibreOffice Online build from source, so no need
        # to test the binary releases:
        "richdocumentscode"
        "richdocumentscode_arm64"

        # https://github.com/nextcloud/user_oidc/issues/90
        (assert nc19apps.user_oidc.version == "0.2.1"; "user_oidc")

        # https://github.com/marius-wieschollek/passwords/issues/330
        (let
          inherit (lib.importJSON ../packages/20/upstream.json) applications;
        in assert applications.passwords.version == "2021.1.0"; "passwords")

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

    in [
      { nextcloud.majorVersion = 19;
        nextcloud.apps = lib.mapAttrs enableApp nc19apps;
      }
      { nextcloud.majorVersion = 20;
        nextcloud.apps = lib.genAttrs [
          "apporder" "bookmarks" "calendar" "circles" "contacts" "deck"
          "external" "end_to_end_encryption" "files_accesscontrol"
          "files_markdown" "files_rightclick" "gpxpod" "groupfolders" "mail"
          "metadata" "news" "passwords" "polls" "phonetrack" "richdocuments"
          # XXX: Temporarily disable "social" app, but attach assertion to
          #      "spreed" to maximum ugliness (and to possibly trigger OCD).
          # Upstream issue: https://github.com/nextcloud/social/issues/1034
          (let inherit (config.nextcloud.package) applications;
          in assert applications.social."20".version == "0.4.2"; "spreed")
          "tasks"
        ] (lib.const { enable = true; });
      }
    ];
  };

  testScript = { nodes, ... }: let
    inherit (nodes.machine.config.system.build) toplevel;
    getChild = num: "${toplevel}/fine-tune/child-${toString num}";

    checkApps = systemRoot: ''
      with machine.nested('checking whether enabled apps match expected ones'):
        applist = machine.succeed('nextcloud-occ app:list --output=json')
        enabled = json.loads(applist)['enabled'].keys()
        with open('${systemRoot}/nc-enabled-apps.json', 'r') as fp:
          expected = set(json.load(fp))
        assert enabled == expected, f'{enabled} != {expected}'
    '';

    switchToGeneration = num: desc: ''
      with machine.nested(r'${pkgs.lib.escape ["'" "\\"] desc}'):
        machine.succeed('${getChild num}/bin/switch-to-configuration test >&2')
        machine.start_job('nextcloud.service')
        machine.wait_for_unit('nextcloud.service')

      ${checkApps (getChild num)}
    '';

  in ''
    # fmt: off
    import json
    machine.wait_for_unit('multi-user.target')

    machine.start_job('nextcloud.service')
    machine.wait_for_unit('nextcloud.service')

    ${checkApps toplevel}

    ${switchToGeneration 1 "enable as many apps as possible"}

    machine.succeed(
      'curl -L http://localhost/ | grep -o "a safe home for all your data"'
    )

    ${switchToGeneration 2 "switch to new major version"}

    machine.succeed(
      'curl -L http://localhost/ | grep -o initial-state-core-loginUsername'
    )
  '';
})
