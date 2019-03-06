let
  configuration = { config, pkgs, lib, ... }: let
    sshKeyPair = pkgs.runCommand "ssh-keypair" {
      buildInputs = [ pkgs.openssh ];
    } ''
      mkdir "$out"
      ssh-keygen -t ed25519 -f "$out/key" -N "" -C "$keyComment"
    '';

    vuizvui = (import <nixpkgs> {}).fetchFromGitHub {
      owner = "openlab-aux";
      repo = "vuizvui";
      rev = "87defa03a178378951ddcfaddab2df3f489cc391";
      sha256 = "15yr3xpvbb37nxk09b2sassb8m4pdqh2hr33s4gyfwaiccr1z3ac";
    };

    zshModule = "${vuizvui}/modules/user/aszlig/programs/zsh";
    vuizvuiPkgs = import "${vuizvui}/pkgs" { inherit pkgs; };

    mailcap = let
      mkEntry = attrs: let
        optAttrs = removeAttrs attrs [ "command" ];
        mkOpt = key: val:
          if val == true then key
          else if val == false then null
          else "${key}=${val}";
        opts = lib.remove null (lib.mapAttrsToList mkOpt optAttrs);
      in lib.concatStringsSep "; " ([ attrs.type attrs.command ] ++ opts);
    in pkgs.writeText "mailcap" (lib.concatMapStringsSep "\n" mkEntry [
      { type = "text/html";
        command = "${pkgs.w3m}/bin/w3m -T text/html '%s'";
        needsterminal = true;
        description = "HTML Text";
        nametemplate = "%s.html";
      }
      { type = "text/html";
        command = "${pkgs.w3m}/bin/w3m -T text/html '%s'";
        copiousoutput = true;
        description = "HTML Text";
        nametemplate = "%s.html";
      }
    ]);

  in {
    imports = [ zshModule ./. ./postgresql.nix ];

    nextcloud.port = 8000;
    nextcloud.processes = 4;

    # XXX: For testing
    nextcloud.apps.apporder.enable = true;
    nextcloud.apps.calendar.enable = true;
    nextcloud.apps.checksum.enable = true;
    nextcloud.apps.circles.enable = true;
    nextcloud.apps.contacts.enable = true;
    nextcloud.apps.deck.enable = true;
    nextcloud.apps.dropit.enable = true;
    nextcloud.apps.end_to_end_encryption.enable = true;
    nextcloud.apps.event_update_notification.enable = true;
    nextcloud.apps.external.enable = true;
    nextcloud.apps.files_accesscontrol.enable = true;
    nextcloud.apps.files_markdown.enable = true;
    nextcloud.apps.files_readmemd.enable = true;
    nextcloud.apps.files_rightclick.enable = true;
    nextcloud.apps.groupfolders.enable = true;
    nextcloud.apps.mail.enable = true;
    nextcloud.apps.metadata.enable = true;
    nextcloud.apps.music.enable = true;
    nextcloud.apps.news.enable = true;
    nextcloud.apps.ojsxc.enable = true;
    nextcloud.apps.onlyoffice.enable = true;
    nextcloud.apps.passman.enable = true;
    nextcloud.apps.polls.enable = true;
    nextcloud.apps.quicknotes.enable = true;
    nextcloud.apps.richdocuments.enable = true;
    nextcloud.apps.social.enable = true;
    nextcloud.apps.spreed.enable = true;
    nextcloud.apps.tasks.enable = true;
    nextcloud.apps.weather.enable = true;

    services.nginx.enable = true;
    services.postgresql.enable = true;

    environment.systemPackages = [
      pkgs.htop
      (pkgs.mutt.overrideAttrs (attrs: {
        configureFlags = (attrs.configureFlags or []) ++ [
          "--with-domain=${config.networking.hostName}"
        ];
        postInstall = (attrs.postInstall or "") + ''
          cat >> "$out/etc/Muttrc" <<MUTTRC
          alternative_order text/plain text/enriched text/html
          auto_view text/html
          bind attach <return> view-mailcap
          set ascii_chars=yes
          set folder = \$MAIL
          set mailcap_path = ${mailcap}
          set sort=threads
          MUTTRC
        '';
      }))
      vuizvuiPkgs.aszlig.vim
    ];

    vuizvui.user.aszlig.programs.zsh.enable = true;
    vuizvui.user.aszlig.programs.zsh.machineColor = "yellow";
    users.defaultUserShell = "/var/run/current-system/sw/bin/zsh";
    time.timeZone = "Europe/Berlin";

    networking.hostName = "newnextcloud-test";
    networking.firewall.enable = false;

    services.postfix.enable = true;
    services.postfix.virtual = "/.*/ root\n";
    services.postfix.virtualMapType = "regexp";
    services.postfix.config = {
      inet_interfaces = "127.0.0.1";
      virtual_alias_domains = "";
    };

    services.openssh.enable = true;

    services.journald.rateLimitInterval = "0";

    system.build.wrapped-vm = let
      sleep = lib.escapeShellArg "${pkgs.coreutils}/bin/sleep";
      nc = lib.escapeShellArg "${pkgs.netcat-openbsd}/bin/nc";
      ssh = lib.escapeShellArg "${pkgs.openssh}/bin/ssh";

      connect = lib.concatMapStringsSep " " lib.escapeShellArg [
        "${pkgs.openssh}/bin/ssh"
        "-i" "${sshKeyPair}/key"
        "-o" "UserKnownHostsFile=/dev/null"
        "-o" "GlobalKnownHostsFile=/dev/null"
        "-o" "StrictHostKeyChecking=no"
        "-o" "ConnectionAttempts=10"
        "-p" "8022"
        "root@localhost"
      ];

    in pkgs.writeScript "run-vm" ''
      #!${pkgs.stdenv.shell}

      if [ "$1" = '--connect' ]; then
        shift
        exec ${connect} "$@"
        exit 1
      elif [ "$1" = '--switch' ]; then
        shift
        newsys=${lib.escapeShellArg config.system.build.toplevel}
        exec ${connect} "$newsys/bin/switch-to-configuration" test
        exit 1
      fi

      if ${nc} -z 127.0.0.1 8022; then
        echo "VM already running, use '--connect' to connect to it." >&2
        exit 1
      fi

      kill_everything() {
        retry=0
        while kill -0 $(jobs -p); do
          if [ $retry -ge 15 ]; then
            kill -9 $(jobs -p)
          else
            kill $(jobs -p)
          fi
          retry=$(($retry + 1))
          ${sleep} 0.1
        done 2> /dev/null || :
      }

      waitport_ssh() {
        while ! ${nc} -z 127.0.0.1 "$1"; do ${sleep} 0.1; done
        while ! ${nc} -w1 127.0.0.1 "$1" < /dev/null | grep -q -m1 '^SSH-'; do
          ${sleep} 0.1
        done
      }

      trap kill_everything EXIT

      set -e

      ${nc} -u -l 127.0.0.1 8882 &
      ncpid=$!

      ${lib.escapeShellArg config.system.build.vm}/bin/run-*-vm \
        -monitor tcp:127.0.0.1:8881,server,nowait \
        -serial udp:127.0.0.1:8882 \
        "$@" &
      vmpid=$!

      waitport_ssh 8022

      set +e
      ${connect}
      retval=$?
      set -e

      echo system_powerdown | ${nc} 127.0.0.1 8881 > /dev/null
      wait $vmpid || :
      exit $retval
    '';

    systemd.services."serial-getty@ttyS0".enable = false;
    systemd.services."serial-getty@hvc0".enable = false;

    environment.etc."ssh/authorized_keys.d/root" = lib.mkForce {
      mode = "0444";
      source = "${sshKeyPair}/key.pub";
    };

    virtualisation.diskSize = 32768;
    virtualisation.memorySize = 1024;
    virtualisation.graphics = false;

    virtualisation.qemu.networkingOptions = let
      devOpts = lib.concatStringsSep "," [
        "hostfwd=tcp:127.0.0.1:8000-:80"
        "hostfwd=tcp:127.0.0.1:8022-:22"
      ];
    in [
      "-device virtio-net-pci,netdev=vlan0"
      "-netdev user,id=vlan0,${devOpts}\${QEMU_NET_OPTS:+,$QEMU_NET_OPTS}"
    ];

    virtualisation.qemu.options = [ "-device virtio-rng-pci" ];
  };

in (import <nixpkgs/nixos/lib/eval-config.nix> {
  system = builtins.currentSystem;
  modules = [
    configuration <nixpkgs/nixos/modules/virtualisation/qemu-vm.nix>
  ];
}).config.system.build.wrapped-vm
