import hashlib
import json
import requests

from typing import List, Dict, Optional, Any
from defusedxml import ElementTree as ET
from semantic_version import Spec, Version

from .progress import download_pbar
from .types import Nextcloud, NextcloudVersion, AppId, App, ExternalApp, \
                   ReleaseInfo, SignatureInfo
from .misc import get_php_version
from .nix import get_internal_apps, hash_zip_content

UPDATE_SERVER_URL = 'https://updates.nextcloud.com/updater_server/'

__all__ = ['upgrade']


def hash_zip(url: str, sha256: str) -> str:
    fname: str = url.rsplit('/', 1)[-1]
    assert len(fname) > 0

    data = download_pbar(url, desc='Downloading ' + url)

    assert hashlib.sha256(data).hexdigest() == sha256
    return hash_zip_content(fname, data)


def _get_latest_nextcloud(curver: NextcloudVersion) -> Optional[Nextcloud]:
    php_version: Version = get_php_version()

    fields: List[str] = [
        # str(curver.major),        # major
        # XXX: Using hardcoded value here to make sure we stay at version 15
        #      until we have fixed the update proceduce to stay within version
        #      boundaries.
        '14',
        str(curver.minor),        # minor
        str(curver.maintenance),  # maintenance
        str(curver.revision),     # revision
        '',                       # installation time
        '',                       # last check
        'stable',                 # channel
        '',                       # edition
        '',                       # build
        str(php_version.major),   # PHP major
        str(php_version.minor),   # PHP minor
        str(php_version.patch),   # PHP release
    ]

    response = requests.get(UPDATE_SERVER_URL, params={
        'version': 'x'.join(fields)
    })
    response.raise_for_status()
    try:
        xml = ET.fromstring(response.text)
    except ET.ParseError:
        return None

    version = xml.findtext('version')
    if version is None:
        return None

    newver = NextcloudVersion.parse(version)
    if newver <= curver:
        return None

    url = xml.findtext('url')
    if url is None:
        return None

    if url.lower().endswith('.zip'):
        url = url[:-4] + '.tar.bz2'

    sha_response = download_pbar(url + '.sha256',
                                 desc='Fetching checksum for ' + url)
    sha256: str = sha_response.split(maxsplit=1)[0].decode()
    ziphash: str = hash_zip(url, sha256)

    return Nextcloud(newver, url, ziphash)


def _get_latest_release_for(
    nc_version: Version,
    releases: List[Dict[str, Any]]
) -> Optional[Dict[str, Any]]:
    latest: Optional[Dict[str, Any]] = None

    for release in releases:
        if '-' in release['version'] or release['isNightly']:
            continue

        spec = Spec(*release['rawPlatformVersionSpec'].split())
        if not spec.match(nc_version):
            continue

        if latest is None or \
           Version(latest['version']) < Version(release['version']):
            latest = release

    return latest


def _get_changelogs(releases: List[Dict[str, Any]]) -> Dict[Version, str]:
    result: Dict[Version, str] = {}
    for release in releases:
        trans = release.get('translations', {}).get('en', {})
        result[Version(str(release['version']))] = trans.get('changelog', '')
    return result


def _get_external_apps(nextcloud: Nextcloud) -> Dict[AppId, App]:
    url = "https://apps.nextcloud.com/api/v1/platform/{}/apps.json"
    data = download_pbar(url.format(str(nextcloud.version.semver)),
                         desc='Downloading Nextcloud app index')

    apps: Dict[AppId, App] = {}
    for appdata in json.loads(data):
        translations = appdata['translations'].get('en', {})
        name: str = translations['name']
        summary: str = translations['summary']
        description: str = translations['description']
        homepage: Optional[str] = None
        if len(appdata['website']) > 0:
            homepage = appdata['website']
        apprel = _get_latest_release_for(nextcloud.version.semver,
                                         appdata['releases'])
        changelogs: Dict[Version, str] = _get_changelogs(appdata['releases'])
        if apprel is None:
            continue
        apps[AppId(appdata['id'])] = ExternalApp(
            name,
            Version(apprel['version']),
            summary,
            description,
            homepage,
            apprel['licenses'],
            apprel['download'],
            SignatureInfo(
                appdata['certificate'],
                apprel['signature'],
            ),
            changelogs
        )
    return apps


def upgrade(spec: ReleaseInfo) -> ReleaseInfo:
    old_nc_version = spec.nextcloud.version
    nextcloud = _get_latest_nextcloud(old_nc_version)
    if nextcloud is None:
        nextcloud = spec.nextcloud
    apps = _get_external_apps(nextcloud)
    apps.update(get_internal_apps(nextcloud))
    return ReleaseInfo(nextcloud, apps)
