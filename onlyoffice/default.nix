with import <nixpkgs> {};

let
  source = callPackage ./source.nix {};

  icu58Pkgs = pkgs.extend (super: self: {
    icu = super.icu58;
  });

  # We can't use buildEnv here, because AllFontsGen doesn't support symlinks.
  systemFonts = pkgs.runCommand "${source.baseName}-system-fonts" {
    paths = [
      pkgs.xorg.fontbhlucidatypewriter100dpi
      pkgs.xorg.fontbhlucidatypewriter75dpi
      pkgs.dejavu_fonts
      pkgs.freefont_ttf
      pkgs.gyre-fonts
      pkgs.liberation_ttf
      pkgs.xorg.fontbh100dpi
      pkgs.xorg.fontmiscmisc
      pkgs.xorg.fontcursormisc
      pkgs.unifont
    ];
  } ''
    mkdir "$out"
    find $paths -mindepth 1 -maxdepth 1 \
      -exec cp --no-preserve=mode -rt "$out" {} +
  '';

  core = stdenv.mkDerivation {
    name = "${source.baseName}-core-${source.version}";
    inherit (source) version;

    src = "${source.src}/core";

    patches = [
      ./core-format-string-security.patch
      ./core-makefile.patch
      ./fontgen-array-oob-fix.patch
    ];

    postPatch = ''
      cat > Common/3dParty/boost/boost.pri <<EOF
      core_boost_libs {
        LIBS += -lboost_system -lboost_filesystem
      }
      core_boost_regex {
        LIBS += -lboost_regex
      }
      core_boost_date_time {
        LIBS += -lboost_date_time
      }
      EOF

      cat > Common/3dParty/curl/curl.pri <<EOF
      LIBS += -lcurl
      EOF

      cat > Common/3dParty/icu/icu.pri <<EOF
      LIBS += -licuuc -licudata
      EOF

      cat > Common/3dParty/openssl/openssl.pri <<EOF
      LIBS += -lssl -lcrypto
      EOF

      cat > Common/3dParty/v8/v8.pri <<EOF
      LIBS += -lv8_base -lv8_libplatform -lv8_libbase -lv8_snapshot
      LIBS += -lv8_libsampler -licui18n -licuuc
      EOF

      sed -i -e 's!/usr/share/fonts!'"$systemFonts"'/share/fonts!g' \
             -e 's!/usr/local/share/fonts!'"$systemFonts"'/share/fonts!g' \
             -e 's!/usr/share/X11/fonts!'"$systemFonts"'/lib/X11/fonts!g' \
             -e 's!/usr/X11R6/lib/X11/fonts!'"$systemFonts"'/lib/X11/fonts!g' \
             DesktopEditor/fontengine/ApplicationFonts.cpp
    '';

    inherit systemFonts;
    # The path will be encoded in UCS-4, so it won't be propageted by default.
    propagatedBuildInputs = [ systemFonts ];

    # Suppress most of the warnings so we don't get flooded by the build
    # output.
    NIX_CFLAGS_COMPILE = [
      "-Wno-unused-function"
      "-Wno-unused-variable"
      "-Wno-unused-parameter"
      "-Wno-implicit-fallthrough"
    ];

    nativeBuildInputs = [ icu58Pkgs.qt5.qmake ];
    dontUseQmakeConfigure = true;
    enableParallelBuilding = true;

    buildInputs = [
      icu58Pkgs.boost icu58Pkgs.curl icu58Pkgs.icu icu58Pkgs.openssl
      icu58Pkgs.v8
    ];

    bits = if stdenv.is64bit then 64 else 32;

    installPhase = ''
      install -vD "build/bin/AllFontsGen/linux_$bits" "$out/bin/AllFontsGen"
      install -vD "build/bin/linux_$bits/x2t" "$out/bin/x2t"
      cp -r "build/lib/linux_$bits" "$out/lib"
    '';
  };

  nodePackages = (import ./node-deps { inherit pkgs; });

  webapps = stdenv.mkDerivation {
    name = "${source.baseName}-webapps-${source.version}";
    inherit (source) version;

    srcs = [
      "${source.src}/web-apps"
      "${source.src}/sdkjs"
    ];

    sourceRoot = "sdkjs";

    postUnpack = let
      sdkjsModules = "${nodePackages.sdkjs.copyEnv}/lib/node_modules";
      webappsModules = "${nodePackages.webapps.copyEnv}/lib/node_modules";
    in ''
      chmod -R +w sdkjs web-apps
      ln -s ${lib.escapeShellArg sdkjsModules} sdkjs/build/node_modules
      ln -s ${lib.escapeShellArg webappsModules} web-apps/build/node_modules
      export PATH="$PWD/sdkjs/build/node_modules/.bin:$PATH"
    '';

    nativeBuildInputs = [ jre ];

    installPhase = "cp -r deploy/web-apps \"$out\"";
  };

  server = stdenv.mkDerivation {
    name = "${source.baseName}-server-${source.version}";
    inherit (source) version;

    srcs = [
      "${source.src}/server"
      "${source.src}/dictionaries"
      "${source.src}/core-fonts"
    ];

    sourceRoot = "server";

    patches = [ ./server-makefile.patch ];

    makeFlags = [ "CORE_PREFIX=${core}" ];

    nativeBuildInputs = [ nodePackages_10_x.grunt-cli ];

    preBuild = let
      serverModuleMap = {
        server = ".";
        server-common = "build/server/Common";
        server-docservice = "build/server/DocService";
        server-fileconverter = "build/server/FileConverter";
        server-metrics = "build/server/Metrics";
        server-spellchecker = "build/server/SpellChecker";
      };

      getModPath = package:
        "${nodePackages.${package}.copyEnv}/lib/node_modules";

    in lib.concatStrings (lib.mapAttrsToList (package: path: ''
      mkdir -p ${lib.escapeShellArg path}
      ln -s ${lib.escapeShellArg (getModPath package)} \
            ${lib.escapeShellArg path}/node_modules
    '') serverModuleMap);

    installPhase = "cp -r build \"$out\"";

    /*
    buildPhase = ''
      mkdir docroot

      mkdir fonts
      # ${strace}/bin/strace -f \
      AllFontsGen --input="${source.src}/core-fonts" \
                  --allfonts-web="${webapps}/sdkjs/common/AllFonts.js" \
                  --allfonts=FileConverter/bin/AllFonts.js \
                  --images="${webapps}/sdkjs/common/Images" \
                  --selection=FileConverter/bin/font_selection.bin \
                  --output-web=fonts \
                  --use-system=true
    '';
    */
  };

in stdenv.mkDerivation {
  name = "${source.baseName}-${source.version}";
  inherit (source) version;

  nativeBuildInputs = [ core ];

  inherit (core) systemFonts;

  buildCommand = ''
    mkdir -p "$out/fonts"
    cp -fr -t "$out" ${server}/* ${webapps}/*
    chmod -R +w "$out"

    AllFontsGen \
      --input="$out/core-fonts" \
      --allfonts-web="$out/sdkjs/common/AllFonts.js" \
      --allfonts="$out/server/FileConverter/bin/AllFonts.js" \
      --images="$out/sdkjs/common/Images" \
      --selection="$out/server/FileConverter/bin/font_selection.bin" \
      --output-web="$out/fonts" \
      --use-system=true
  '';
}
