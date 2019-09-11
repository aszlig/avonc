import json
import requests

from typing import List, Dict, Optional, Any
from defusedxml import ElementTree as ET  # type: ignore
from semantic_version import Spec, Version  # type: ignore

from .progress import download_pbar
from .types import Nextcloud, AppId, App

UPDATE_SERVER_URL = 'https://updates.nextcloud.com/updater_server/'


def get_latest_nextcloud_version(curver: str,
                                 phpver: str) -> Optional[Nextcloud]:
    nc_version: List[str] = curver.split('.') + [''] * 4
    php_version = phpver.split('.') + [''] * 3

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
    except ET.ParseError:
        return None

    url = xml.find('url').text
    if url.lower().endswith('.zip'):
        url = url[:-4] + '.tar.bz2'

    return Nextcloud(xml.find('version').text, url)


def get_latest_release_for(
    nc_version: Version,
    releases: List[Dict[str, Any]]
) -> Optional[Dict[str, Any]]:
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


def get_changelogs(releases: List[Dict[str, Any]]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for release in releases:
        trans = release.get('translations', {}).get('en', {})
        result[str(release['version'])] = trans.get('changelog', '')
    return result


def get_available_apps(nc_version: str) -> Dict[AppId, App]:
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
        homepage: Optional[str] = None
        if len(appdata['website']) > 0:
            homepage = appdata['website']
        apprel = get_latest_release_for(Version(nc_semver),
                                        appdata['releases'])
        changelogs: Dict[str, str] = get_changelogs(appdata['releases'])
        if apprel is None:
            continue
        apps[AppId(appdata['id'])] = App(
            name,
            apprel['version'],
            summary,
            description,
            homepage,
            apprel['licenses'],
            apprel['download'],
            appdata['certificate'],
            apprel['signature'],
            changelogs,
        )
    return apps
