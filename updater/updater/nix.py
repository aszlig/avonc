import os
import subprocess
import tempfile


def hash_zip_content(fname: str, data: bytes) -> str:
    with tempfile.TemporaryDirectory() as tempdir:
        destpath = os.path.join(tempdir, fname)
        open(destpath, 'wb').write(data)
        desturl = 'file://' + destpath
        cmd = ['nix-prefetch-url', '--type', 'sha256', '--unpack', desturl]
        result = subprocess.run(cmd, capture_output=True, check=True).stdout
        ziphash = result.strip().decode()
        return ziphash
