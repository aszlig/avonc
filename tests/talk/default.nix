{ system ? builtins.currentSystem
, nixpkgs ? <nixpkgs>
, extraModules ? []
, pkgs ? import nixpkgs { inherit system; config = {}; }
, lib ? pkgs.lib

, geckodriver ? null
, firefox-unwrapped ? null

, clients ? 4
} @ args:

assert clients > 1;

import ../make-test.nix {
  name = "nextcloud-talk";

  nodes = let
    mkNetConf = num: { lib, ... }: {
      networking.useDHCP = false;
      networking.interfaces = {
        eth0.ipv4.addresses = lib.mkForce [];
        eth0.ipv6.addresses = lib.mkForce [];
        eth1.ipv4.addresses = lib.mkForce (lib.singleton {
          address = "80.81.82.${toString num}";
          prefixLength = 28;
        });
        eth1.ipv6.addresses = lib.mkForce (lib.singleton {
          address = "beef::${toString num}";
          prefixLength = 124;
        });
      };
      networking.hosts."beef::${toString (clients + 1)}" = [ "nextcloud" ];
      networking.hosts."80.81.82.${toString (clients + 1)}" = [ "nextcloud" ];
    };

    mkClient = num: { config, pkgs, lib, nodes, ... }: {
      imports = lib.singleton (mkNetConf num);

      boot.kernelModules = [ "v4l2loopback" ];
      boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];

      systemd.services.video-provider = {
        description = "WebRTC Test Video Provider";

        environment.FONTCONFIG_FILE = pkgs.makeFontsConf {
          fontDirectories = [ pkgs.inconsolata ];
        };

        path = [ pkgs.ffmpeg ];

        serviceConfig.Type = "notify";
        serviceConfig.ExecStartPre = lib.escapeShellArgs [
          # XXX: Fallback for NixOS 19.03
          "${pkgs.v4l-utils or pkgs.v4l_utils}/bin/v4l2-ctl"
          "-c" "keep_format=1,sustain_framerate=1"
          "-d" "/dev/video0"
        ];
        serviceConfig.ExecStart = lib.escapeShellArgs [
          (pkgs.python3.withPackages (p: [
            p.imageio p.imageio-ffmpeg p.numpy p.pillow p.python-fontconfig
            p.setuptools p.systemd
          ])).interpreter
          "${./video-provider.py}"
          "User${toString num}"
        ];
      };

      systemd.services.test-driver = {
        description = "Test Driver for Client ${toString num}";
        requiredBy = [ "multi-user.target" ];
        requires = [ "pulseaudio.service" ];
        after = [ "pulseaudio.service" ];

        environment = {
          MOZ_LOG = let
            logModules = {
              CamerasChild = 4;
              CamerasParent = 4;
              GetUserMedia = 5;
              MediaCapabilities = 4;
              MediaChild = 4;
              MediaControl = 4;
              MediaDecoder = 4;
              MediaDemuxer = 4;
              MediaEncoder = 4;
              MediaFormatReader = 4;
              MediaManager = 4;
              MediaParent = 4;
              MediaResource = 4;
              MediaStream = 4;
              MediaStreamTrack = 4;
              VideoEngine = 4;
              VideoFrameContainer = 4;
            };
            mkEntry = module: loglevel: "${module}:${toString loglevel}";
          in lib.concatStringsSep "," (lib.mapAttrsToList mkEntry logModules);
          MOZ_LOG_FILE = "/tmp/xchg/browser.log";
          PULSE_COOKIE = config.environment.variables.PULSE_COOKIE;
          LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.libpulseaudio ];
        };

        path = let
          # Always use known good Firefox and GeckoDriver from nixpkgs master
          # to make sure we get a consistent result accross (older) nixpkgs
          # versions we run this test against.
          pinnedPkgs = import (pkgs.fetchFromGitHub {
            owner = "NixOS";
            repo = "nixpkgs";
            rev = "d8cf78466e56b798cdecd2dbbacdfe00bd7e4ef8";
            sha256 = "0aas57cl5m5g5f7bibsy0rwzcn2mgbyiaacbb4k4zmy6z1abrx6r";
          }) { inherit (config.nixpkgs) config; };
        in [
          (if geckodriver == null then pinnedPkgs.geckodriver else geckodriver)
          (if firefox-unwrapped == null then pinnedPkgs.firefox-unwrapped
           else firefox-unwrapped)
          config.hardware.pulseaudio.package
        ];

        preStart = "while ! pactl stat &> /dev/null; do sleep 1; done";
        serviceConfig.ExecStart = lib.escapeShellArgs [
          (pkgs.python3.withPackages (p: [ p.selenium ])).interpreter
          "${./driver.py}"
        ];
      };

      environment.systemPackages = let
        testClient = pkgs.writeScriptBin "test-client" ''
          #!${pkgs.python3.interpreter}
          import sys
          import xmlrpc.client

          proxy = xmlrpc.client.ServerProxy('http://localhost:1234/')

          assert len(sys.argv) > 1
          func = getattr(proxy, sys.argv[1])
          ret = func(*sys.argv[2:])
          if ret is not None:
            if isinstance(ret, xmlrpc.client.Binary):
              sys.stdout.buffer.write(ret.data)
            elif isinstance(ret, (bytes, bytearray)):
              sys.stdout.buffer.write(ret)
            else:
              sys.stdout.write(str(ret))
        '';
      in [ testClient pkgs.iptables ];

      hardware.pulseaudio.enable = true;
      hardware.pulseaudio.systemWide = true;
      hardware.pulseaudio.configFile = pkgs.writeText "default.pa" ''
        load-module module-native-protocol-unix
        load-module module-sine-source
      '';

      virtualisation.memorySize = 1024;
      virtualisation.qemu.options = [ "-smp 4" ];
    };

  in {
    server = { pkgs, lib, ... }: {
      imports = lib.singleton (mkNetConf (clients + 1));

      nextcloud.enable = true;
      nextcloud.domain = "nextcloud";
      nextcloud.useSSL = true;
      nextcloud.useACME = false;
      nextcloud.processes = 8;
      nextcloud.apps.firstrunwizard.enable = false;
      nextcloud.apps.spreed.enable = true;

      services.nginx.enable = true;
      services.nginx.virtualHosts.nextcloud = let
        snakeoilCert = pkgs.runCommand "snakeoil-cert" {
          nativeBuildInputs = [ pkgs.openssl ];
          OPENSSL_CONF = pkgs.writeText "snakeoil.cnf" ''
            [req]
            default_bits = 4096
            prompt = no
            default_md = sha256
            req_extensions = req_ext
            distinguished_name = dn
            [dn]
            CN = nextcloud
            [req_ext]
            subjectAltName = DNS:nextcloud
          '';
        } ''
          mkdir -p "$out"
          openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/key.pem" \
            -out "$out/cert.pem" -days 36500
        '';
      in {
        sslCertificate = "${snakeoilCert}/cert.pem";
        sslCertificateKey = "${snakeoilCert}/key.pem";
      };

      services.postgresql.enable = true;
      systemd.services.postgresql.environment = {
        LD_PRELOAD = "${pkgs.libeatmydata}/lib/libeatmydata.so";
      };

      virtualisation.memorySize = 2048;
      virtualisation.qemu.options = [ "-smp 4" ];
    };
  } // lib.listToAttrs (lib.genList (num: {
    name = "client${toString (num + 1)}";
    value = mkClient (num + 1);
  }) clients);

  testScript = ''
    # fmt: off
    import os
    from pathlib import Path
    from shutil import copyfile

    start_all()
    clients = ${toString clients}

    class ExtendedMachine:
      def save_item(self, what, from_file, filename, cmd='true'):
        path = Path(os.environ['out']) / filename
        with self.nested(f'saving {what} to {path!r}', {'image': filename}):
          self.succeed(f'{cmd} && sync /tmp/xchg/{from_file}')
          copyfile(f'vm-state-{self.name}/xchg/{from_file}', path)

      def selenium_screenshot(self, name):
        self.save_item('browser screenshot', 'screenshot.png',
                       f'{name}.png', 'test-client screenshot')

      def save_driver_log(self, name):
        self.save_item('driver log', 'driver.log', f'{name}.log')

      def save_browser_log(self, name):
        self.save_item('browser log', 'browser.log', f'{name}.log')

      def save_html(self, name):
        self.save_item('HTML of current page', 'page.html', f'{name}.html',
                       'test-client save_html')

      def webrtc_info(self, name):
        self.save_item('WebRTC info', 'webrtc.html', f'{name}.html',
                       'test-client webrtc_info')

    # Monkey-add all the methods of ExtendedMachine to all Machine instances
    for attr in dir(ExtendedMachine):
      if attr.startswith('_'): continue
      setattr(Machine, attr, getattr(ExtendedMachine, attr))

    server.wait_for_unit('multi-user.target')
    server.start_job('nextcloud.service')
    server.wait_for_unit('nextcloud.service')

    server.succeed(
      'OC_PASS=RiejFafphi nextcloud-occ user:add --password-from-env someuser'
    )

    with server.nested('check connectivity between nodes'):
      for i in map(lambda x: x + 1, range(clients)):
        server.succeed(f'ping -c1 beef::{i} >&2')
        globals()[f'client{i}'].succeed(
          'ping -c1 nextcloud >&2',
          'nc -z nextcloud 3478',
        )

    with client2.nested('disallow direct connectivity'):
      client2.succeed(
        'iptables -I INPUT -s 80.81.82.${toString (clients + 1)} -j ACCEPT',
        'iptables -I INPUT -i lo -j ACCEPT',
        'iptables -P INPUT DROP',
        'ip6tables -I INPUT -s beef::${toString (clients + 1)} -j ACCEPT',
        'ip6tables -I INPUT -i lo -j ACCEPT',
        'ip6tables -P INPUT DROP',
        'ping -c1 nextcloud >&2',
        'nc -z nextcloud 3478',
      )
      for i in [1] + [num + 1 for num in range(2, clients)]:
        globals()[f'client{i}'].fail('ping -c1 80.81.82.2')
        globals()[f'client{i}'].fail('ping -c1 beef::2')

    client1.succeed('test-client login someuser RiejFafphi')
    client1.selenium_screenshot('logged_in')

    url = client1.succeed('test-client create_conversation foobar')
    client1.selenium_screenshot('conversation_created')

    for i in map(lambda x: x + 1, range(1, 4)):
      globals()[f'client{i}'].succeed(f'test-client join_conversation {url}')
      globals()[f'client{i}'].selenium_screenshot(f'client{i}_joined')

    client1.start_job('video-provider.service')
    client1.succeed('test-client start_call')

    for i in map(lambda x: x + 1, range(1, 4)):
      globals()[f'client{i}'].start_job('video-provider.service')
      globals()[f'client{i}'].succeed('test-client start_call')

    client1.succeed('test-client wait_for_others')

    for i in map(lambda x: x + 1, range(clients)):
      globals()[f'client{i}'].selenium_screenshot(f'client{i}_call_started')
      globals()[f'client{i}'].save_driver_log(f'client{i}_driver')
      globals()[f'client{i}'].save_html(f'client{i}_call_started')
  '';
} args
