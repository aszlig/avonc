import hashlib
import json
import requests
import re
import os

from typing import List, Dict, Optional, Any
from semantic_version import Spec, Version
from bs4 import BeautifulSoup
from urllib.parse import urljoin

from .progress import download_pbar
from .types import Nextcloud, AppId, App, ExternalApp, ReleaseInfo, \
                   SignatureInfo
from .nix import get_internal_apps, hash_zip_content, get_nextcloud_store_path

RE_NEXTCLOUD_RELEASE = re.compile(r'^nextcloud-([0-9.]+)\.tar\.bz2$')
RE_NEXTCLOUD_INTERNAL_VERSION_DIGIT = re.compile(
    r'^\s*\$OC_Version\s*=\s*(?:\[|array\()(?:\s*\d+\s*,){3}\s*(\d+)',
    re.MULTILINE
)

__all__ = ['upgrade']


def _hash_zip(url: str, sha256: str) -> str:
    fname: str = url.rsplit('/', 1)[-1]
    assert len(fname) > 0

    data = download_pbar(url, desc='Downloading ' + url)

    assert hashlib.sha256(data).hexdigest() == sha256
    return hash_zip_content(fname, data)


def _get_nextcloud_versions() -> Dict[Version, str]:
    baseurl = 'https://download.nextcloud.com/server/releases/'
    response = requests.get(baseurl)
    response.raise_for_status()
    soup = BeautifulSoup(response.text, 'html.parser')
    versions: Dict[Version, str] = {}
    for link in soup.find_all("a"):
        match = RE_NEXTCLOUD_RELEASE.match(link["href"])
        if match is not None:
            ver = Version(match.group(1))
            versions[ver] = urljoin(baseurl, match.group(0))
    return versions


def _update_with_real_version(nc: Nextcloud) -> Nextcloud:
    storepath: str = get_nextcloud_store_path(nc)
    verfile: str = os.path.join(storepath, 'version.php')
    with open(verfile, 'r') as fp:
        for match in RE_NEXTCLOUD_INTERNAL_VERSION_DIGIT.finditer(fp.read()):
            newver = Version(str(nc.version))
            newver.build = (match.group(1),)
            return Nextcloud(newver, nc.download_url, nc.sha256)

    raise IOError(f"Unable to find full Nextcloud version in {verfile}.")


def _strip_build(version: Version) -> Version:
    return Version(f'{version.major}.{version.minor}.{version.patch}')


def _fetch_latest_nextcloud(curver: Version) -> Optional[Nextcloud]:
    versions = _get_nextcloud_versions()
    spec = Spec(f'<{curver.next_major()},>{_strip_build(curver)}')
    version = spec.select(versions.keys())
    if version is None:
        return None
    url = versions[version]

    sha_response = download_pbar(url + '.sha256',
                                 desc='Fetching checksum for ' + url)
    sha256: str = sha_response.split(maxsplit=1)[0].decode()
    ziphash: str = _hash_zip(url, sha256)

    nc = Nextcloud(version, url, ziphash)
    return _update_with_real_version(nc)


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
    data = download_pbar(url.format(str(_strip_build(nextcloud.version))),
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
        apprel = _get_latest_release_for(nextcloud.version,
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
    nextcloud = _fetch_latest_nextcloud(old_nc_version)
    if nextcloud is None:
        nextcloud = spec.nextcloud
    apps = _get_external_apps(nextcloud)
    apps.update(get_internal_apps(nextcloud))
    return ReleaseInfo(nextcloud, apps)