{ config, pkgs, lib, ... }:

let
  inherit (lib) types;
  mkSafeName = lib.replaceStrings ["@" ":" "\\" "[" "]"] ["-" "-" "-" "" ""];
in {
  options.systemd.services = lib.mkOption {
    type = types.attrsOf (types.submodule ({ name, config, ... }: {
      options.chroot.enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = ''
          If set, all the required runtime store paths for this service are
          bind-mounted into a <literal>tmpfs</literal>-based <citerefentry>
            <refentrytitle>chroot</refentrytitle>
            <manvolnum>2</manvolnum>
          </citerefentry>.
        '';
      };

      options.chroot.packages = lib.mkOption {
        type = types.listOf (types.either types.package types.str);
        default = [];
        description = let
          mkScOption = optName: "<option>serviceConfig.${optName}</option>";

        in ''
          Additional packages or strings with context to add to the closure of
          the chroot. By default, this includes all the packages from the
          ${lib.concatMapStringsSep ", " mkScOption [
            "ExecReload" "ExecStartPost" "ExecStartPre" "ExecStop"
            "ExecStopPost"
          ]} and ${mkScOption "ExecStart"} options.

          <note><para><emphasis role="strong">Only</emphasis> the latter
          (${mkScOption "ExecStart"}) will be used if
          ${mkScOption "RootDirectoryStartOnly"} is enabled.</para></note>
        '';
      };

      options.chroot.withBinSh = lib.mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to symlink <literal>dash</literal> as
          <filename>/bin/sh</filename> to the chroot.

          This is useful for some applications, which for example use the
          <citerefentry>
            <refentrytitle>system</refentrytitle>
            <manvolnum>3</manvolnum>
          </citerefentry> library function to execute commands.
        '';
      };

      options.chroot.confinement = lib.mkOption {
        type = types.enum [ "full" "full-apivfs" "chroot-only" ];
        default = "full-apivfs";
        description = ''
          If this is set to <literal>full</literal>, user name spaces are set
          up for the service.

          The value <literal>full-apivfs</literal> (the default) also sets up
          private <filename class="directory">/dev</filename>, <filename
          class="directory">/proc</filename>, <filename
          class="directory">/sys</filename> and <filename
          class="directory">/tmp</filename> file systems.

          If this is set to <literal>chroot-only</literal>, only the file
          system name space is set up along with the call to <citerefentry>
            <refentrytitle>chroot</refentrytitle>
            <manvolnum>2</manvolnum>
          </citerefentry>.

          <note><para>This doesn't cover network namespaces and is solely for
          file system level isolation.</para></note>
        '';
      };

      config = lib.mkIf config.chroot.enable {
        serviceConfig = let
          rootName = "${mkSafeName name}-chroot";
        in {
          RootDirectory = pkgs.runCommand rootName {} "mkdir \"$out\"";
          TemporaryFileSystem = "/";
          MountFlags = lib.mkDefault "private";
        } // lib.optionalAttrs config.chroot.withBinSh {
          BindReadOnlyPaths = [ "${pkgs.dash}/bin/dash:/bin/sh" ];
        } // (if config.chroot.confinement == "full" then {
          PrivateUsers = true;
        } else if config.chroot.confinement == "full-apivfs" then {
          MountAPIVFS = true;
          PrivateDevices = true;
          PrivateTmp = true;
          PrivateUsers = true;
          ProtectControlGroups = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
        } else {});
        chroot.packages = let
          startOnly = config.serviceConfig.RootDirectoryStartOnly or false;
          execOpts = if startOnly then [ "ExecStart" ] else [
            "ExecReload" "ExecStart" "ExecStartPost" "ExecStartPre" "ExecStop"
            "ExecStopPost"
          ];
          execPkgs = lib.concatMap (opt: let
            isSet = config.serviceConfig ? ${opt};
          in lib.optional isSet config.serviceConfig.${opt}) execOpts;
        in execPkgs ++ lib.optional config.chroot.withBinSh pkgs.dash;
      };
    }));
  };

  config.systemd.packages = lib.concatLists (lib.mapAttrsToList (name: cfg: let
    rootPaths = let
      contents = lib.concatStringsSep "\n" cfg.chroot.packages;
    in pkgs.writeText "${mkSafeName name}-string-contexts.txt" contents;

    chrootPaths = pkgs.runCommand "${mkSafeName name}-chroot-paths" {
      closureInfo = pkgs.closureInfo { inherit rootPaths; };
      serviceName = "${name}.service";
      excludePath = rootPaths;
    } ''
      mkdir -p "$out/lib/systemd/system"
      serviceFile="$out/lib/systemd/system/$serviceName"

      echo '[Service]' > "$serviceFile"

      while read storePath; do
        # FIXME: Can't currently cope with symlinks, so let's skip them.
        if [ "$storePath" = "$excludePath" -o -L "$storePath" ]; then
          continue
        fi
        echo "BindReadOnlyPaths=$storePath:$storePath"
      done < "$closureInfo/store-paths" >> "$serviceFile"
    '';
  in lib.optional cfg.chroot.enable chrootPaths) config.systemd.services);
}
