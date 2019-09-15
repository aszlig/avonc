{ stdenv, lib, fetchzip, fetchFromGitHub

# Args passed by /default.nix.
, apps, theme, extraPostPatch
}:

let
  upstreamInfo = lib.importJSON ./upstream.json;

  fetchTheme = attrs: attrs // { result = fetchFromGitHub attrs.github; };
  themes = lib.mapAttrs (lib.const fetchTheme) upstreamInfo.themes;

in stdenv.mkDerivation rec {
  name = "nextcloud-${version}";
  inherit (upstreamInfo.nextcloud) version;

  src = fetchzip {
    inherit (upstreamInfo.nextcloud) url sha256;
  };

  prePatch = let
    inherit (upstreamInfo) applications;
    notShipped = lib.const (appdata: !appdata.meta.isShipped);
    extApps = lib.filterAttrs notShipped applications;
    isEnabled = name: apps.${name}.enable;
    enabledApps = lib.filter isEnabled (lib.attrNames extApps);
    appPaths = lib.genAttrs enabledApps (name: fetchzip {
      inherit (extApps.${name}) url sha256;
    });
  in lib.concatStrings (lib.mapAttrsToList (appid: path: ''
    cp -TR ${lib.escapeShellArg path} apps/${lib.escapeShellArg appid}
    chmod -R +w apps/${lib.escapeShellArg appid}
  '') appPaths); # FIXME: Avoid the chmod above!

  buildPhase = let
    inherit (themes.${theme}) result directory;
  in lib.optionalString (themes ? ${theme}) ''
    cp -TR ${lib.escapeShellArg result} themes/${lib.escapeShellArg directory}
  '';

  patches = [
    patches/no-config-uid-check.patch
    ../15/patches/executable-lookup.patch
    ../15/patches/readonly-config-upgrade.patch
  ];

  # Nextcloud checks whether the user matches the webserver user by comparing
  # the current userid with the owner of config.php. In our case however, the
  # config.php is inside the Nix store so it most certainly isn't owned by
  # the nextcloud user.
  postPatch = ''
    sed -i -e 's/${
      "\\($configUser *= *\\).*fileowner(.*config.php.*)"
    }/\1$user/g' cron.php console.php
  '' + extraPostPatch;

  installPhase = "mkdir -p \"\$out/\"\ncp -R . \"$out/\"";

  meta = {
    description = "Sharing solution for files, calendars, contacts and more";
    homepage = https://nextcloud.com;
    license = lib.licenses.agpl3Plus;
  };

  passthru.applications = upstreamInfo.applications;
}
