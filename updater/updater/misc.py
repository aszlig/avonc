import subprocess

from semantic_version import Version


def get_php_version() -> Version:
    cmd = ['php', '-r', 'echo PHP_VERSION;']
    return Version(subprocess.check_output(cmd).strip().decode())
