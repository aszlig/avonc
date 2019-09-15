{ stdenv, lib, fetchzip, fetchFromGitHub

# Args passed by /default.nix.
, apps, theme, extraPostPatch
}:

let
  themeBreezeDark = fetchFromGitHub {
    owner = "mwalbeck";
    repo = "nextcloud-breeze-dark";
    rev = "e2b2c92df3544fcf16c1ad2d5e9598d54d906998";
    sha256 = "1cyzphbbis5wxqmk3f242pacm8nvqq70dn53c4kzzrkdin069rqr";
  };

  upstreamInfo = lib.importJSON ./upstream.json;

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

  buildPhase = lib.optionalString (theme == "breeze-dark") ''
    cp -TR ${lib.escapeShellArg themeBreezeDark} themes/nextcloud-breeze-dark
  '';

  patches = [
    patches/no-config-uid-check.patch
    patches/executable-lookup.patch
    patches/readonly-config-upgrade.patch
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
