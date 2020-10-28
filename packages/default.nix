{ stdenv, lib, fetchzip, fetchFromGitHub, callPackage

# Args passed by /default.nix.
, majorVersion, apps, extraPostPatch
}:

let
  packages = let
    isAllDigits = val: builtins.match "[1-9][0-9]*" val != null;
    isValidPackage = name: type: isAllDigits name && type == "directory";
    filtered = lib.filterAttrs isValidPackage (builtins.readDir ./.);
  in lib.mapAttrs (name: lib.const (./. + "/${name}")) filtered;

  releaseInfos = let
    importReleaseInfo = path: lib.importJSON (path + "/upstream.json");
  in lib.mapAttrs (lib.const importReleaseInfo) packages;

  inherit (releaseInfos.${toString majorVersion}) nextcloud;

  # All the apps zipped into one single attrset providing compatible Nextcloud
  # versions for every app.
  #
  # The structure looks like this:
  #
  #  {
  #    app1 = { "17" = { ... app attrs ... };
  #             "18" = { ... app attrs ... };
  #           };
  #    app2 = { "17" = { ... app attrs ... }; };
  #    app3 = { "18" = { ... app attrs ... }; };
  #  }
  #
  applications = let
    addVersions = name: relInfo: lib.mapAttrs (appid: value: {
      inherit name value;
    }) relInfo.applications;
    appsWithVersions = lib.mapAttrs addVersions releaseInfos;
    zipFun = lib.const lib.listToAttrs;
  in lib.zipAttrsWith zipFun (lib.attrValues appsWithVersions);

  # The attributes we need to add to the mkDerivation call below that are
  # specific to a major version, like patches.
  packageAttrs = let
    expr = import packages.${toString majorVersion};
  in if builtins.isFunction expr then callPackage expr {} else expr;

in stdenv.mkDerivation rec {
  name = "nextcloud-${version}";
  inherit (nextcloud) version;

  src = fetchzip { inherit (nextcloud) url sha256; };

  prePatch = let
    major = toString majorVersion;
    isShipped = appdata: appdata.${major}.meta.isShipped or false;
    notShipped = lib.const (appdata: !isShipped appdata);
    extApps = lib.filterAttrs notShipped applications;
    isEnabled = name: apps.${name}.enable;
    enabledApps = lib.filter isEnabled (lib.attrNames extApps);

    getAppPackage = name: let
      forceEnabled = apps.${name}.forceEnable or false;
      isAvailable = extApps.${name} ? ${major};
      latest = lib.last (lib.attrValues extApps.${name});
      appAttrs = extApps.${name}.${major} or latest;
      fetched = let
        overrides = lib.const { unpackCmd = "tar xf \"$curSrc\""; };
      in (fetchzip { inherit (appAttrs) url sha256; }).overrideAttrs overrides;
      err = throw "App package ${name} for Nextcloud ${major} not available.";
    in if isAvailable || forceEnabled then fetched else err;

    appPaths = lib.genAttrs enabledApps getAppPackage;

  in lib.concatStrings (lib.mapAttrsToList (appid: path: ''
    cp -TR ${lib.escapeShellArg path} apps/${lib.escapeShellArg appid}
    chmod -R +w apps/${lib.escapeShellArg appid}
  '') appPaths); # FIXME: Avoid the chmod above!

  patches = packageAttrs.patches or [];

  postPatch = extraPostPatch;

  installPhase = "mkdir -p \"\$out/\"\ncp -R . \"$out/\"";

  meta = {
    description = "Sharing solution for files, calendars, contacts and more";
    homepage = https://nextcloud.com;
    license = lib.licenses.agpl3Plus;
  };

  passthru = { inherit applications; };
}
