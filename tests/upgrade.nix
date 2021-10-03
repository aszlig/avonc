import ./make-test.nix (pkgs: {
  name = "nextcloud-upgrade";

  machine = { config, lib, pkgs, ... }: {
    nextcloud.enable = true;
    nextcloud.domain = "localhost";
    nextcloud.majorVersion = lib.mkDefault 20;

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
      nc20apps = (lib.importJSON ../packages/20/upstream.json).applications;

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
        # Needs Java
        "libresign"
        # Needs an external backend
        "pdfdraw"
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
        # Needs FFI support
        "storj"
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

        # https://git.project-insanity.org/onny/nextcloud-app-podcast/issues/225
        (assert nc20apps.podcast.version == "0.3.1"; "podcast")

        # Don't test packages that include binaries:
        "documentserver_community"
        "integration_whiteboard"
        "recognize"
        "richdocumentscode"
        "richdocumentscode_arm64"
        "talk_matterbridge"

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
      { nextcloud.majorVersion = 20;
        nextcloud.apps = lib.mapAttrs enableApp nc20apps;
      }
      { nextcloud.majorVersion = 21;
        nextcloud.apps = lib.genAttrs [
          "apporder" "bookmarks" "calendar" "circles" "contacts" "deck"
          "external" "end_to_end_encryption" "files_accesscontrol"
          "files_markdown" "files_rightclick" "gpxpod" "groupfolders" "mail"
          "metadata" "news" "passwords" "polls" "phonetrack" "richdocuments"
          "social" "spreed" "tasks"
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
        if enabled != expected:
          diffstr = '\n'.join(ndiff(sorted(enabled), sorted(expected)))
          msg = f'Enabled apps do not match expected apps:\n{diffstr}'
          raise AssertionError(msg)
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
    from difflib import ndiff
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
