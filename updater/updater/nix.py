import json
import os
import subprocess
import tempfile
import unicodedata

from defusedxml import ElementTree as ET
from typing import Dict, List
from xml.sax import saxutils

from .types import Nextcloud, AppId, InternalApp


def hash_zip_content(fname: str, data: bytes) -> str:
    with tempfile.TemporaryDirectory() as tempdir:
        destpath = os.path.join(tempdir, fname)
        open(destpath, 'wb').write(data)
        desturl = 'file://' + destpath
        cmd = ['nix-prefetch-url', '--type', 'sha256', '--unpack', desturl]
        result = subprocess.run(cmd, capture_output=True, check=True).stdout
        ziphash = result.strip().decode()
        return ziphash


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

    cmd = ['nix-build', '-E', expr, '--argstr', 'attrs', json.dumps(data)]
    result = subprocess.run(cmd, capture_output=True, check=True).stdout
    return result.strip().decode()


def _clean_meta(value: str) -> str:
    cleaned = unicodedata.normalize('NFKD', value).encode('ascii', 'ignore')
    return saxutils.escape(cleaned.decode())


def get_internal_apps(nextcloud: Nextcloud) -> Dict[AppId, InternalApp]:
    ncpath: str = get_nextcloud_store_path(nextcloud)
    specpath: str = os.path.join(ncpath, 'core/shipped.json')
    spec: Dict[str, List[str]] = json.load(open(specpath, 'r'))

    result: Dict[AppId, InternalApp] = {}

    for appid in spec['shippedApps']:
        if appid in spec['alwaysEnabled']:
            continue

        app_path: str = os.path.join(ncpath, 'apps', appid)
        info_path: str = os.path.join(app_path, 'appinfo/info.xml')
        xml = ET.parse(info_path)

        name: str = _clean_meta(xml.findtext('name', appid))
        summary: str = xml.findtext('summary', name)

        result[AppId(appid)] = InternalApp(
            name=name,
            licenses=[xml.findtext('licence', 'unknown')],
            summary=_clean_meta(summary),
            description=_clean_meta(xml.findtext('description', '')),
            enabled_by_default=xml.find('default_enable') is not None,
        )
    return result
