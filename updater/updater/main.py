from typing import Dict, List, Tuple, Set, Any
from defusedxml import ElementTree as ET  # type: ignore
from semantic_version import Version  # type: ignore
from tqdm import tqdm  # type: ignore
from xml.sax import saxutils

import copy
import hashlib
import json
import os
import sys
import subprocess
import textwrap
import unicodedata

from .progress import download_pbar
from .app import NcApp, fetch_app
from .nix import hash_zip_content
from .api import get_latest_nextcloud_version, get_available_apps

PHP_VERSION = '7.2.0'

INITIAL_UPSTREAM_STATE = {
    'nextcloud': {'version': '15'},
    'applications': {}
}


def filter_changelogs(changelogs: Dict[str, str],
                      oldver: str, newver: str) -> Dict[str, str]:
    result: Dict[str, str] = {}
    old_semver = Version(oldver)
    new_semver = Version(newver)
    for version, changelog in changelogs.items():
        if old_semver < Version(version) <= new_semver:
            result[version] = changelog
    return result


def hash_zip(url: str, sha256: str) -> str:
    fname: str = url.rsplit('/', 1)[-1]
    assert len(fname) > 0

    data = download_pbar(url, desc='Downloading ' + url)

    assert hashlib.sha256(data).hexdigest() == sha256
    return hash_zip_content(fname, data)


def download_nextcloud(version: str, url: str) -> Tuple[str, str]:
    if url.lower().endswith('.zip'):
        url = url[:-4] + '.tar.bz2'

    sha_response = download_pbar(url + '.sha256',
                                 desc='Fetching checksum for ' + url)
    sha256: str = sha_response.split(maxsplit=1)[0].decode()

    ziphash: str = hash_zip(url, sha256)
    return (ziphash, url)


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


def format_changelog(changelog: str, indent: str) -> str:
    if changelog == '':
        return indent + "No changelog provided.\n"
    else:
        wrapped = textwrap.indent(changelog.strip(), indent)
        return wrapped + "\n"


def main() -> None:
    basedir: str = os.getcwd()
    packagedir: str = os.path.join(basedir, 'package', 'current')
    info_file: str = os.path.join(packagedir, 'upstream.json')

    current_state: Dict[str, Any]
    try:
        with open(info_file, 'r') as current:
            current_state = json.load(current)
    except FileNotFoundError:
        current_state = INITIAL_UPSTREAM_STATE

    current_ver = current_state['nextcloud']['version']
    latest_ver, dl_url = get_latest_nextcloud_version(current_ver, PHP_VERSION)

    if dl_url is not None and is_newer_version(current_ver, latest_ver):
        msg = 'New version {!r} of Nextcloud found.'.format(latest_ver)
        tqdm.write(msg, file=sys.stderr)
        ziphash, url = download_nextcloud(latest_ver, dl_url)
        current_state['nextcloud']['version'] = latest_ver
        current_state['nextcloud']['url'] = url
        current_state['nextcloud']['sha256'] = ziphash

    ncpath: str = get_nextcloud_store_path(current_state['nextcloud'])

    updated: Set[str] = set()
    added: Set[str] = set()
    removed: Set[str] = set()

    old_appstate: Dict[str, Any] = copy.deepcopy(current_state['applications'])

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
        stats.append("Apps added:\n")
        for appid in added:
            stats.append(f"  {appid} ({apps[appid].version})")
        stats.append("")

    if updated:
        stats.append("Apps updated:\n")
        for appid in updated:
            old_ver: str = old_appstate[appid]['version']
            new_ver: str = str(apps[appid].version)
            stats.append(f"  {appid} ({old_ver} -> {new_ver}):\n")
            changelogs = filter_changelogs(apps[appid].changelogs,
                                           old_ver, str(new_ver))
            if len(changelogs) > 1:
                for version in sorted(changelogs.keys(), reverse=True):
                    changelog: str = changelogs[version]
                    stats.append(f"    Changes for version {version}:\n")
                    stats.append(format_changelog(changelog, '      '))
            else:
                stats.append(format_changelog(changelogs[new_ver], '    '))

    if removed:
        stats.append("Apps removed:\n")
        stats.append("  " + "\n  ".join(removed) + "\n")

    if stats:
        tqdm.write("\n" + "\n".join(stats), file=sys.stderr)

    with open(info_file, 'w') as newstate:
        json.dump(current_state, newstate, indent=2, sort_keys=True)
        newstate.write('\n')
