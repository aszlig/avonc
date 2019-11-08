{ system ? builtins.currentSystem
, pkgs ? import <nixpkgs> { inherit system; config = {}; }
, lib ? pkgs.lib

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
            p.setuptools p.pystemd
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
          pinnedPkgs.geckodriver pinnedPkgs.firefox-unwrapped
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
    use File::Copy;
    startAll;
    my $clients = ${toString clients};

    sub saveItem {
      my ($self, $what, $fromFile, $filename, $cmd) = @_;
      my $path = $ENV{'out'}.'/'.$filename;
      $self->nest("saving $what to '$path'", sub {
        $self->succeed(($cmd // 'true').' && sync /tmp/xchg/'.$fromFile);
        copy('vm-state-'.$self->name.'/xchg/'.$fromFile, $path);
      }, {image => $filename});
    }

    sub Machine::seleniumScreenshot {
      my ($self, $name) = @_;
      saveItem($self, 'browser screenshot', 'screenshot.png', $name.'.png',
               'test-client screenshot');
    }

    sub Machine::saveDriverLog {
      my ($self, $name) = @_;
      saveItem($self, 'driver log', 'driver.log', $name.'.log');
    }

    sub Machine::saveBrowserLog {
      my ($self, $name) = @_;
      saveItem($self, 'browser log', 'browser.log', $name.'.log');
    }

    sub Machine::saveHtml {
      my ($self, $name) = @_;
      saveItem($self, 'HTML of current page', 'page.html', $name.'.html',
               'test-client save_html');
    }

    sub Machine::webrtcInfo {
      my ($self, $name) = @_;
      saveItem($self, 'WebRTC info', 'webrtc.html', $name.'.html',
               'test-client webrtc_info');
    }

    $server->waitForUnit('multi-user.target');
    $server->startJob('nextcloud.service');
    $server->waitForUnit('nextcloud.service');

    $server->succeed(
      'OC_PASS=VogibOc9 nextcloud-occ user:add --password-from-env someuser'
    );

    $server->nest('check connectivity between nodes', sub {
      foreach my $i (1..$clients) {
        $server->succeed('ping -c1 beef::'.$i.' >&2');
        $vms{"client$i"}->succeed(
          'ping -c1 nextcloud >&2',
          'nc -z nextcloud 3478',
        );
      }
    });

    $client2->nest('disallow direct connectivity', sub {
      $client2->succeed(
        'iptables -I INPUT -s 80.81.82.${toString (clients + 1)} -j ACCEPT',
        'iptables -I INPUT -i lo -j ACCEPT',
        'iptables -P INPUT DROP',
        'ip6tables -I INPUT -s beef::${toString (clients + 1)} -j ACCEPT',
        'ip6tables -I INPUT -i lo -j ACCEPT',
        'ip6tables -P INPUT DROP',
        'ping -c1 nextcloud >&2',
        'nc -z nextcloud 3478',
      );
      foreach my $i (1, 3..$clients) {
        $vms{"client$i"}->fail('ping -c1 80.81.82.2');
        $vms{"client$i"}->fail('ping -c1 beef::2');
      }
    });

    $client1->succeed('test-client login someuser VogibOc9');
    $client1->seleniumScreenshot('logged_in');

    my $url = $client1->succeed('test-client create_conversation foobar');
    $client1->seleniumScreenshot('conversation_created');

    foreach my $i (2..$clients) {
      $vms{"client$i"}->succeed('test-client join_conversation '.$url);
      $vms{"client$i"}->seleniumScreenshot('client'.$i.'_joined');
    }

    $client1->startJob('video-provider.service');
    $client1->succeed('test-client start_call');

    foreach my $i (2..$clients) {
      $vms{"client$i"}->startJob('video-provider.service');
      $vms{"client$i"}->succeed('test-client start_call');
    }

    $client1->succeed('test-client wait_for_others');

    foreach my $i (1..$clients) {
      $vms{"client$i"}->seleniumScreenshot('client'.$i.'_call_started');
      $vms{"client$i"}->saveDriverLog('client'.$i.'_driver');
      $vms{"client$i"}->saveBrowserLog('client'.$i.'_browser');
      $vms{"client$i"}->saveHtml('client'.$i.'_call_started');
    }
  '';
} args
