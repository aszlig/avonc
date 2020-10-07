{ nixpkgs ? <nixpkgs>, pkgs ? import nixpkgs {}, lib ? pkgs.lib, options }:

let
  optionsDb = pkgs.nixosOptionsDoc {
    options = options.nextcloud;
  };

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
      <xi:include href="${optionsDb.optionsDocBook}" />
    </book>
    XML

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

    cp "${nixpkgs}/doc/style.css" "$dest/style.css"
    cp "${nixpkgs}/doc/overrides.css" "$dest/overrides.css"
    cp -r ${pkgs.documentation-highlighter} "$dest/highlightjs"

    mkdir -p "$out/nix-support"
    echo "doc manual $dest" > "$out/nix-support/hydra-build-products"
  '';
}
