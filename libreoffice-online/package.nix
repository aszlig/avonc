{ pkgs ? import <nixpkgs> {}, lib ? pkgs.lib }:

let
  nodePackages = (import ./node-deps { inherit pkgs; });

  libreofficeSDK = pkgs.libreoffice-fresh-unwrapped.overrideAttrs (drv: {
    configureFlags = (drv.configureFlags or []) ++ [ "--enable-odk" ];
    stripReportBuilder = pkgs.writeText "strip-reportbuilder.xslt" ''
      <?xml version="1.0"?>
      <xsl:stylesheet version="1.0"
                      xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                      xmlns:uno="http://openoffice.org/2010/uno-components">
        <xsl:template match="@*|node()">
          <xsl:copy>
            <xsl:apply-templates select="@*|node()" />
          </xsl:copy>
        </xsl:template>
        <xsl:template match="uno:component[starts-with(@prefix, 'rpt')]" />
      </xsl:stylesheet>
    '';
    postInstall = (drv.postInstall or "") + ''
      mkdir -p "$out/include/LibreOfficeKit"
      install -v -m 644 include/LibreOfficeKit/* "$out/include/LibreOfficeKit"
      servicesXML="$out/lib/libreoffice/program/services/services.rdb"
      xsltproc -o "$servicesXML" "$stripReportBuilder" "$servicesXML"
    '';
  });

in pkgs.stdenv.mkDerivation rec {
  name = "libreoffice-online-${version}";
  version = "6.1.3.2";
  versionHash = builtins.hashString "sha1" src.outputHash;

  src = pkgs.fetchgit {
    url = https://anongit.freedesktop.org/git/libreoffice/online.git;
    rev = "libreoffice-${version}";
    sha256 = "166g7cz75376bf39a6ax5nrml1kjcy8wh9z4s2spz3x5lwkwxp5x";
  };

  patches = [
    patches/no-setcap.patch
    patches/username.patch
    patches/nix-store-paths.patch
    patches/systemd.patch
    patches/no-systemplate.patch
    patches/logging-fixes.patch
    patches/disable-nonworking-commands.patch
  ];

  postPatch = ''
    find -name Makefile.am -exec sed -i -e '/fc-cache/d' {} +
    patchShebangs loleaflet/util

    # We don't care about whether this is the real Git hash as long as it
    # differs with different versions of the source and it's base 16 encoded.
    echo -n "$versionHash" > dist_git_hash
  '';

  preBuild = lib.concatMapStrings (pkg: ''
    mkdir -p loleaflet/node_modules
    cp -r --no-preserve=mode -t loleaflet/node_modules \
      ${lib.escapeShellArg "${pkg}/lib/node_modules"}/*
  '') (lib.attrValues nodePackages);

  configureFlags = [
    "--disable-setcap"
    "--with-lokit-path=${libreofficeSDK}/include"
    "--with-lo-path=${libreofficeSDK}/lib"
  ];

  buildInputs = [
    libreofficeSDK pkgs.libpng pkgs.libcap pkgs.poco pkgs.pam pkgs.pcre
    pkgs.openssl
  ];

  nativeBuildInputs = [
    pkgs.autoreconfHook pkgs.pkgconfig pkgs.cppunit pkgs.nodejs-10_x
    pkgs.python3Packages.polib
  ];

  enableParallelBuilding = true;

  passthru.sdk = libreofficeSDK;
}
