{ stdenv, lib, fetchzip, fetchFromGitHub, fetchpatch

# Args passed by /default.nix.
, apps, theme, extraPostPatch
}:

let
  themeBreezeDark = fetchFromGitHub {
    owner = "mwalbeck";
    repo = "nextcloud-breeze-dark";
    rev = "6a1c90ae97f6b60772ce7756e77d3d2b6b2b41df";
    sha256 = "0sdzscz2pq7g674inkc6cryqsdnrpin2hsvvaqzngld6vp1z7h04";
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
  ] ++ (lib.singleton (fetchpatch {
    # In Nextcloud 15.0.6.1, there has been a regression[1] which has been
    # caused by the following commit, which we subsequently revert for now.
    #
    # [1]: https://github.com/nextcloud/server/issues/14962
    url = "https://github.com/nextcloud/server/commit/"
        + "8ac03c67a783ca1c59ac0c8dc7eaf000a9919996.patch";
    sha256 = "0z95ciggjfklmb414cqvbch368p2np3c9y70h37yp2v2fx2jngdi";
    revert = true;
  }));

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
