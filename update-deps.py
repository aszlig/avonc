#!/usr/bin/env nix-shell
#!nix-shell -i python -p python3Packages.python --argstr # noqa
#!nix-shell -p python3Packages.semantic-version --argstr # noqa
#!nix-shell -p python3Packages.requests         --argstr # noqa
#!nix-shell -p python3Packages.defusedxml       --argstr # noqa
#!nix-shell -p python3Packages.pyopenssl        --argstr # noqa
#!nix-shell -p python3Packages.tqdm             --argstr # noqa

from collections import namedtuple
from typing import Dict, List, Tuple, Set, Any, Optional
from semantic_version import Spec, Version  # type: ignore
from defusedxml import ElementTree as ET  # type: ignore
from OpenSSL import crypto  # type: ignore
from requests.packages.urllib3.exceptions import InsecureRequestWarning
from tqdm import tqdm  # type: ignore
from xml.sax import saxutils

import base64
import hashlib
import json
import os
import re
import requests
import sys
import subprocess
import tempfile
import unicodedata
import warnings

UPDATE_SERVER_URL = 'https://updates.nextcloud.com/updater_server/'
DOWNLOAD_URL = 'https://download.nextcloud.com/server/releases/'
PHP_VERSION = '7.2.0'

INITIAL_UPSTREAM_STATE = {
    'nextcloud': {'version': '15'},
    'applications': {}
}

DataDict = Dict[str, Any]


def download_pbar(url, **kwargs) -> bytes:
    verify = kwargs.pop('verify', True)

    if verify:
        response = requests.get(url, stream=True)
    else:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", InsecureRequestWarning)
            response = requests.get(url, stream=True, verify=False)

    response.raise_for_status()

    file_size = int(response.headers.get('content-length', 0))
    kwargs['total'] = file_size
    kwargs['unit'] = 'B'
    kwargs['unit_scale'] = True
    kwargs['ascii'] = True
    buf: bytes = b''
    pbar = tqdm(**kwargs)
    chunksize: int = max(file_size // 100, 8192)
    try:
        for data in response.iter_content(chunk_size=chunksize):
            buf += data
            pbar.update(len(data))
    finally:
        pbar.close()
    return buf


def get_latest_release_for(nc_version: Version,
                           releases: List[DataDict]) -> Optional[DataDict]:
    latest = None

    for release in releases:
        if '-' in release['version'] or release['isNightly']:
            continue

        spec = Spec(*release['rawPlatformVersionSpec'].split())
        if not spec.match(nc_version):
            continue

        release['version'] = Version(release['version'])

        if latest is None or latest['version'] < release['version']:
            latest = release

    return latest


NcApp = namedtuple('NcApp', ['name', 'version', 'summary', 'description',
                             'website', 'licenses', 'download', 'certificate',
                             'signature'])


def get_available_apps(nc_version: str) -> Dict[str, NcApp]:
    nc_semver: str = '.'.join(nc_version.split('.')[:3])
    url = "https://apps.nextcloud.com/api/v1/platform/{}/apps.json"
    data = download_pbar(url.format(nc_semver),
                         desc='Downloading Nextcloud app index')

    apps = {}
    for appdata in json.loads(data):
        translations = appdata['translations'].get('en', {})
        name: str = translations['name']
        summary: str = translations['summary']
        description: str = translations['description']
        apprel = get_latest_release_for(Version(nc_semver),
                                        appdata['releases'])
        if apprel is None:
            continue
        apps[appdata['id']] = NcApp(
            name,
            apprel['version'],
            summary,
            description,
            appdata['website'],
            apprel['licenses'],
            apprel['download'],
            appdata['certificate'],
            apprel['signature'],
        )
    return apps


def get_latest_nextcloud_version(current_ver: str, php_ver: str) -> str:
    nc_version: List[str] = current_ver.split('.') + [''] * 4
    php_version = php_ver.split('.') + [''] * 3

    fields: List[str] = [
        nc_version[0],   # major
        nc_version[1],   # minor
        nc_version[2],   # maintenance
        nc_version[3],   # revision
        '',              # installation time
        '',              # last check
        'stable',        # channel
        '',              # edition
        '',              # build
        php_version[0],  # PHP major
        php_version[1],  # PHP minor
        php_version[2],  # PHP release
    ]

    response = requests.get(UPDATE_SERVER_URL, params={
        'version': 'x'.join(fields)
    })
    response.raise_for_status()
    try:
        xml = ET.fromstring(response.text)
        return xml.find('version').text
    except ET.ParseError:
        return current_ver


def hash_zip_content(fname: str, data: bytes) -> str:
    with tempfile.TemporaryDirectory() as tempdir:
        destpath = os.path.join(tempdir, fname)
        open(destpath, 'wb').write(data)
        desturl = 'file://' + destpath
        cmd = ['nix-prefetch-url', '--type', 'sha256', '--unpack', desturl]
        result = subprocess.run(cmd, capture_output=True, check=True).stdout
        ziphash = result.strip().decode()
        return ziphash


def hash_zip(url: str, sha256: str) -> str:
    fname: str = url.rsplit('/', 1)[-1]
    assert len(fname) > 0

    data = download_pbar(url, desc='Downloading ' + url)

    assert hashlib.sha256(data).hexdigest() == sha256
    return hash_zip_content(fname, data)


def download_nextcloud(version: str) -> Tuple[str, str]:
    nc_version: List[str] = version.split('.')
    dl_version: str
    if len(nc_version) == 4 and int(nc_version[3]) == 0:
        dl_version = '.'.join(nc_version[:3])
    else:
        dl_version = '.'.join(nc_version[:4])

    fname: str = 'nextcloud-' + dl_version + '.tar.bz2'
    sha_response = download_pbar(DOWNLOAD_URL + fname + '.sha256',
                                 desc='Fetching checksum for ' + fname)
    sha256: str = sha_response.split(maxsplit=1)[0].decode()

    ziphash: str = hash_zip(DOWNLOAD_URL + fname, sha256)
    return (ziphash, DOWNLOAD_URL + fname)


def is_newer_version(current, latest):
    curver = tuple(int(c) for c in current.split('.'))
    lastver = tuple(int(c) for c in latest.split('.'))
    return curver < lastver


def get_nextcloud_store_path(data: Dict[str, str]) -> str:
    expr = '''
    { attrs }:

    (import <nixpkgs> {}).fetchzip {
        inherit (builtins.fromJSON attrs) url sha256;
    }
    '''
    cmd = ['nix-build', '-E', expr, '--argstr', 'attrs', json.dumps(data)]
    result = subprocess.run(cmd, capture_output=True, check=True).stdout
    return result.strip().decode()


PEM_RE = re.compile('-----BEGIN .+?-----\r?\n.+?\r?\n-----END .+?-----\r?\n?',
                    re.DOTALL)


def verify_cert(ncpath: str, certdata: str) -> crypto.X509:
    capath = os.path.join(ncpath, 'resources/codesigning/root.crt')
    crlpath = os.path.join(ncpath, 'resources/codesigning/root.crl')

    store = crypto.X509Store()
    with open(capath, 'r') as cafile:
        for match in PEM_RE.finditer(cafile.read()):
            ca = crypto.load_certificate(crypto.FILETYPE_PEM, match.group(0))
            store.add_cert(ca)

    with open(crlpath, 'r') as crlfile:
        crl = crypto.load_crl(crypto.FILETYPE_PEM, crlfile.read())
    store.add_crl(crl)
    store.set_flags(crypto.X509StoreFlags.CRL_CHECK)

    cert = crypto.load_certificate(crypto.FILETYPE_PEM, certdata)
    ctx = crypto.X509StoreContext(store, cert)
    ctx.verify_certificate()
    return cert


def fetch_app(ncpath: str, appid: str, appdata: NcApp) -> Dict[str, str]:
    cert = verify_cert(ncpath, appdata.certificate)
    # Apps do have a signature, so even if the remote's cert check fails, we
    # can still proceed.
    data = download_pbar(appdata.download, verify=False,
                         desc='Downloading app {!r}'.format(appdata.name))
    sig = base64.b64decode(appdata.signature)
    crypto.verify(cert, sig, data, 'sha512')
    ziphash: str = hash_zip_content(appdata.download.rsplit('/', 1)[-1], data)

    return {
        'version': str(appdata.version),
        'url': appdata.download,
        'sha256': ziphash
    }


def clean_meta(value: str) -> str:
    cleaned = unicodedata.normalize('NFKD', value).encode('ascii', 'ignore')
    return saxutils.escape(cleaned.decode())


def get_appmeta(appdata: NcApp) -> Dict[str, Any]:
    appmeta = {}

    if len(appdata.website) > 0:
        appmeta['homepage'] = appdata.website

    appmeta['name'] = clean_meta(appdata.name)
    appmeta['licenses'] = appdata.licenses
    appmeta['summary'] = clean_meta(appdata.summary)
    appmeta['description'] = clean_meta(appdata.description)
    appmeta['isShipped'] = False
    return appmeta


def update_appstate(state: Dict[str, Any], appid: str, appdata: NcApp) -> None:
    if appid not in state:
        return

    cruft = set(state[appid].keys()) - {'version', 'url', 'sha256'}
    for unknown_key in cruft:
        del state[appid][unknown_key]
    state[appid]['meta'] = get_appmeta(appdata)


def get_shipped_apps(ncpath: str):
    specpath: str = os.path.join(ncpath, 'core/shipped.json')
    spec: Dict[str, List[str]] = json.load(open(specpath, 'r'))

    result: Dict[str, Any] = {}

    for appid in spec['shippedApps']:
        if appid in spec['alwaysEnabled']:
            continue

        app_path: str = os.path.join(ncpath, 'apps', appid)
        info_path: str = os.path.join(app_path, 'appinfo/info.xml')
        xml = ET.parse(info_path)

        name: str = clean_meta(xml.find('name').text)
        summary = xml.find('summary')

        result[appid] = {'meta': {
            'name': name,
            'licenses': [xml.find('licence').text],
            'summary': name if summary is None else clean_meta(summary.text),
            'description': clean_meta(xml.find('description').text),
            'defaultEnable': xml.find('default_enable') is not None,
            'isShipped': True,
        }}
    return result


def main(info_file: str) -> None:
    current_state: DataDict
    try:
        with open(info_file, 'r') as current:
            current_state = json.load(current)
    except FileNotFoundError:
        current_state = INITIAL_UPSTREAM_STATE

    current_version = current_state['nextcloud']['version']
    latest_version = get_latest_nextcloud_version(current_version, PHP_VERSION)

    if is_newer_version(current_version, latest_version):
        msg = 'New version {!r} of Nextcloud found.'.format(latest_version)
        tqdm.write(msg, file=sys.stderr)
        ziphash, url = download_nextcloud(latest_version)
        current_state['nextcloud']['version'] = latest_version
        current_state['nextcloud']['url'] = url
        current_state['nextcloud']['sha256'] = ziphash

    ncpath: str = get_nextcloud_store_path(current_state['nextcloud'])

    updated: Set[str] = set()
    added: Set[str] = set()
    removed: Set[str] = set()

    apps = get_available_apps(current_state['nextcloud']['version'])
    for appid, appdata in tqdm(apps.items(), desc='Fetching applications',
                               ascii=True):
        current_appdata: Dict[str, Any]
        if appid in current_state['applications']:
            current_appdata = current_state['applications'][appid]
        else:
            added.add(appid)
            current_appdata = {'version': '0.0.0'}

        curver = Version(current_appdata['version'])
        if curver >= appdata.version:
            update_appstate(current_state['applications'], appid, appdata)
            continue

        if appid not in added:
            updated.add(appid)

        try:
            new_appdata: Dict[str, str] = fetch_app(ncpath, appid, appdata)
            current_state['applications'][appid] = new_appdata
        except Exception as e:
            msg = "Exception occured while fetching application: {}".format(e)
            tqdm.write(msg, file=sys.stderr)
        finally:
            update_appstate(current_state['applications'], appid, appdata)

    shipped = get_shipped_apps(ncpath)
    current_state['applications'].update(shipped)
    appids = set(apps.keys()) | set(shipped.keys())

    obsolete = set(current_state['applications'].keys()) - appids
    for appid in obsolete:
        removed.add(appid)
        del current_state['applications'][appid]

    stats: List[str] = []

    if added:
        stats.append("Apps added: " + ', '.join(added))

    if updated:
        stats.append("Apps updated: " + ', '.join(updated))

    if removed:
        stats.append("Apps removed: " + ', '.join(removed))

    tqdm.write("\n" + "\n".join(stats), file=sys.stderr)

    with open(info_file, 'w') as newstate:
        json.dump(current_state, newstate, indent=2, sort_keys=True)
        newstate.write('\n')


if __name__ == '__main__':
    basedir: str = os.path.dirname(os.path.realpath(__file__))
    info_file: str = os.path.join(basedir, 'deps', 'upstream.json')
    main(info_file)
