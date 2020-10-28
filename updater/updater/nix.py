import json
import os
import subprocess
import tempfile

from defusedxml import ElementTree as ET
from typing import Dict, List

from .types import Nextcloud, AppId, InternalApp, Sha256


def hash_zip_content(fname: str, data: bytes) -> Sha256:
    with tempfile.TemporaryDirectory() as tempdir:
        destpath = os.path.join(tempdir, fname)
        open(destpath, 'wb').write(data)
        desturl = 'file://' + destpath
        cmd = ['nix-prefetch-url', '--type', 'sha256', '--unpack', desturl]
        result = subprocess.run(cmd, capture_output=True, check=True).stdout
        ziphash = result.strip().decode()
        return Sha256(ziphash)


def get_nextcloud_store_path(nextcloud: Nextcloud) -> str:
    data: Dict[str, str] = {
        'url': nextcloud.download_url,
        'sha256': nextcloud.sha256
    }
    expr = '''
    { attrs }:

    (import <nixpkgs> {}).fetchzip {
        inherit (builtins.fromJSON attrs) url sha256;
    }
    '''

    cmd = ['nix-build', '--no-out-link', '--builders', '',
           '-E', expr, '--argstr', 'attrs', json.dumps(data)]
    result = subprocess.run(cmd, capture_output=True, check=True).stdout
    return result.strip().decode()


def get_internal_apps(nextcloud: Nextcloud) -> Dict[AppId, InternalApp]:
    from .api import clean_meta
    ncpath: str = get_nextcloud_store_path(nextcloud)
    specpath: str = os.path.join(ncpath, 'core/shipped.json')
    spec: Dict[str, List[str]] = json.load(open(specpath, 'r'))

    result: Dict[AppId, InternalApp] = {}

    for appid in spec['shippedApps']:
        app_path: str = os.path.join(ncpath, 'apps', appid)
        info_path: str = os.path.join(app_path, 'appinfo/info.xml')
        xml = ET.parse(info_path)

        name: str = clean_meta(xml.findtext('name', appid))
        summary: str = xml.findtext('summary', name)

        default_enable = xml.find('default_enable') is not None
        always_enable = appid in spec['alwaysEnabled']

        result[AppId(appid)] = InternalApp(
            name=name,
            licenses=[xml.findtext('licence', 'unknown')],
            summary=clean_meta(summary),
            description=clean_meta(xml.findtext('description', '')),
            enabled_by_default=always_enable or default_enable,
            always_enabled=always_enable,
        )
    return result


def fetch_from_github(owner: str, repo: str, rev: str) -> Sha256:
    data: Dict[str, str] = {
        'owner': owner,
        'repo': repo,
        'rev': rev,
        'sha256': '0' * 52,
    }
    expr = b'''
    { attrs }: {
        src = (import <nixpkgs> {}).fetchFromGitHub (builtins.fromJSON attrs);
    }
    '''
    with tempfile.NamedTemporaryFile() as exprfile:
        exprfile.write(expr)
        exprfile.flush()
        cmd = ['nix-prefetch-url', exprfile.name,
               '--argstr', 'attrs', json.dumps(data),
               '-A', 'src']
        result = subprocess.run(cmd, capture_output=True, check=True).stdout
        return Sha256(result.strip().decode())
