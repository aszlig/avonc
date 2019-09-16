import <nixpkgs/nixos/tests/make-test.nix> ({ pkgs, ... }: {
  machine = { pkgs, ... }: {
    imports = [ ../. ../postgresql.nix ];

    nextcloud.domain = "localhost";
    nextcloud.apps.end_to_end_encryption.enable = true;
    nextcloud.apps.end_to_end_encryption.forceEnable = true;
    nextcloud.apps.social.enable = true;

    services.nginx.enable = true;
    services.postgresql.enable = true;
    systemd.services.postgresql.environment = {
      LD_PRELOAD = "${pkgs.libeatmydata}/lib/libeatmydata.so";
    };

    virtualisation.memorySize = 1024;
    environment.systemPackages = [
      (pkgs.python3.withPackages (p: [ p.requests ]))
    ];
  };

  testScript = let
    inherit (pkgs) lib;

    tests.".well-known/webfinger" = ''
      >>> requests.get(url + '/apps/social', auth=admin_auth)
      <Response [200]>
      >>> url += '/.well-known/webfinger'
      >>> qstring = 'resource=acct:admin@localhost'
      >>> response = requests.get(url + '?' + qstring)
      >>> response.raise_for_status()
      >>> sorted(response.json().keys())
      ['links', 'subject']
    '';

    tests.".well-known/host-meta" = ''
      >>> requests.get(url + '/.well-known/host-meta')
      <Response [404]>
      >>> requests.get(url + '/.well-known/host-meta.json')
      <Response [404]>
    '';

    tests.".well-known/caldav" = ''
      >>> url += '/.well-known/caldav'
      >>> response = requests.get(url, allow_redirects=False)
      >>> response.is_redirect
      True
      >>> response.is_permanent_redirect
      True
      >>> response.headers['location']
      'http://localhost/remote.php/dav/'
    '';

    tests.".well-known/carddav" = ''
      >>> url += '/.well-known/carddav/something'
      >>> response = requests.get(url, allow_redirects=False)
      >>> response.is_redirect
      True
      >>> response.is_permanent_redirect
      True
      >>> response.headers['location']
      'http://localhost/remote.php/dav/'
    '';

    tests."ocs/v2.php" = ''
      >>> from requests.auth import HTTPBasicAuth
      >>> url += '/ocs/v2.php/apps/end_to_end_encryption/api/v1/server-key'
      >>> response = requests.get(url + '?format=json', auth=admin_auth,
      ...                         headers={'OCS-APIREQUEST': 'true'})
      >>> response.raise_for_status()
      >>> data = response.json()
      >>> data['ocs']['meta']['status']
      'ok'
      >>> data['ocs']['meta']['statuscode']
      200
      >>> data['ocs']['meta']['message']
      'OK'
      >>> 'BEGIN PUBLIC KEY' in data['ocs']['data']['public-key']
      True
    '';

    tests.ocm-provider = ''
      >>> url += '/ocm-provider/'
      >>> response = requests.get(url)
      >>> response.raise_for_status()
      >>> data = response.json()
      >>> data['enabled']
      True
      >>> len(data['resourceTypes']) > 0
      True
    '';

    tests.ocs-provider = ''
      >>> url += '/ocs-provider'
      >>> response = requests.get(url)
      >>> response.raise_for_status()
      >>> data = response.json()
      >>> 'version' in data
      True
      >>> 'SHARING' in data['services']
      True
      >>> 'FEDERATED_SHARING' in data['services']
      True
    '';

  in ''
    $machine->waitForUnit('multi-user.target');
    $machine->startJob('nextcloud.service');
    $machine->waitForUnit('nextcloud.service');
  '' + lib.concatStrings (lib.mapAttrsToList (name: test: let
    testFile = pkgs.writeText "doctest.txt" ''
      >>> import requests
      >>> from requests.auth import HTTPBasicAuth
      >>> admin_auth = HTTPBasicAuth('admin', 'admin')
      >>> url = 'http://localhost'
      ${test}
    '';
    desc = "check whether ${name} works correctly";
  in ''
    subtest '${lib.escape ["\\" "'"] desc}', sub {
      $machine->succeed('python3 -m doctest ${testFile}');
    };
  '') tests);
})
