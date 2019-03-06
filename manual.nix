{ pkgs ? import <nixpkgs> {}, lib ? pkgs.lib }:

let
  modules = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    modules = [ ./. ];
    check = false;
  };

  isHOpt = opt: lib.head (lib.splitString "." opt.name) == "nextcloud";
  filterDoc = lib.filter (opt: isHOpt opt && opt.visible && !opt.internal);
  filtered = filterDoc (lib.optionAttrSetToDocList modules.options);
  optsXML = builtins.unsafeDiscardStringContext (builtins.toXML filtered);
  optsFile = builtins.toFile "options.xml" optsXML;
  nixosVersion = builtins.readFile "${pkgs.path}/.version";

in pkgs.stdenv.mkDerivation {
  name = "nextcloud-options-manual";

  nativeBuildInputs = [ pkgs.libxslt ];

  styleSheets = [
    "style.css" "overrides.css" "highlightjs/mono-blue.css"
  ];

  buildCommand = ''
    dest="$out/share/doc/nextcloud"
    mkdir -p "$dest"

    cat > manual.xml <<XML
    <book xmlns="http://docbook.org/ns/docbook"
          xmlns:xlink="http://www.w3.org/1999/xlink"
          xmlns:xi="http://www.w3.org/2001/XInclude">
      <title>NixOS options for Nextcloud</title>
      <xi:include href="options-db.xml" />
    </book>
    XML

    # XXX: NixOS 18.03 compatibility
    ${if lib.versionOlder nixosVersion "18.09" then ''
      xsltproc -o options-db.xml \
        "${pkgs.path}/nixos/doc/manual/options-to-docbook.xsl" \
        ${lib.escapeShellArg optsFile}
    '' else ''
      xsltproc -o intermediate.xml \
        "${pkgs.path}/nixos/doc/manual/options-to-docbook.xsl" \
        ${lib.escapeShellArg optsFile}
      xsltproc -o options-db.xml \
        "${pkgs.path}/nixos/doc/manual/postprocess-option-descriptions.xsl" \
        intermediate.xml
    ''}

    xsltproc -o "$dest/index.html" -nonet -xinclude \
      --param section.autolabel 1 \
      --param section.label.includes.component.label 1 \
      --stringparam html.stylesheet \
        'style.css overrides.css highlightjs/mono-blue.css' \
      --stringparam html.script \
        'highlightjs/highlight.pack.js highlightjs/loader.js' \
      --param xref.with.number.and.title 1 \
      --stringparam admon.style "" \
      ${pkgs.docbook5_xsl}/xml/xsl/docbook/xhtml/docbook.xsl \
      manual.xml

    cp "${pkgs.path}/doc/style.css" "$dest/style.css"
    cp "${pkgs.path}/doc/overrides.css" "$dest/overrides.css"
    cp -r ${pkgs.documentation-highlighter} "$dest/highlightjs"

    mkdir -p "$out/nix-support"
    echo "doc manual $dest" > "$out/nix-support/hydra-build-products"
  '';
}
