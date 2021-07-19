import ./make-test.nix {
  name = "nextcloud-smoke";

  machine = { pkgs, ... }: {
    nextcloud.domain = "localhost";
    services.nginx.enable = true;
    services.postgresql.enable = true;
    systemd.services.postgresql.environment = {
      LD_PRELOAD = "${pkgs.libeatmydata}/lib/libeatmydata.so";
    };
  };

  testScript = ''
    # fmt: off
    machine.wait_for_unit('multi-user.target')
    machine.start_job('nextcloud-cron.service')
    machine.succeed(
      'test -z "$(journalctl -q _SYSTEMD_UNIT=nextcloud-cron.service)"'
    )
  '';
}
