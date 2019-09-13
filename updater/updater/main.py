from typing import Dict, Any
from semantic_version import Version
from tqdm import tqdm

import json
import os
import sys

from .types import AppId, App, InternalApp, ExternalApp, Nextcloud, \
                   ReleaseInfo, Sha256, SignatureInfo
from .app import fetch_app_hash
from . import api, nix
from .diff import ReleaseDiff

INITIAL_UPSTREAM_STATE = {
    'nextcloud': {'version': '15'},
    'applications': {}
}


def import_data(data: Dict[str, Any]) -> ReleaseInfo:
    nextcloud_data = data.get('nextcloud', {})
    nextcloud = Nextcloud(
        Version.coerce(nextcloud_data.get('version')),
        nextcloud_data.get('url'),
        nextcloud_data.get('sha256'),
    )
    app_data = data.get('applications', {})
    apps: Dict[AppId, App] = {}
    for appid, attrs in app_data.items():
        meta = attrs.get('meta', {})

        name = meta.get('name')
        if name is None:
            continue

        if meta.get('isShipped', False):
            apps[AppId(appid)] = InternalApp(
                name,
                meta.get('summary', ''),
                meta.get('description', ''),
                meta.get('licenses', []),
                meta.get('defaultEnable', False),
            )
        else:
            apps[AppId(appid)] = ExternalApp(
                name,
                Version(attrs['version']),
                meta.get('summary', ''),
                meta.get('description', ''),
                meta.get('homepage'),
                meta.get('licenses', []),
                attrs['url'],
                Sha256(attrs['sha256'])
            )
    return ReleaseInfo(nextcloud, apps)


def export_data(info: ReleaseInfo) -> Dict[str, Any]:
    apps: Dict[str, Any] = {}

    for appid, app in info.apps.items():
        meta: Dict[str, Any] = {
            'name': app.name,
            'summary': app.summary,
            'description': app.description,
            'licenses': app.licenses,
            'isShipped': isinstance(app, InternalApp),
        }

        if isinstance(app, InternalApp):
            meta['defaultEnable'] = app.enabled_by_default
            apps[appid] = {'meta': meta}
        elif isinstance(app.hash_or_sig, SignatureInfo):
            raise ValueError(f"Can't serialise {app} without a hash.")
        else:
            if app.homepage is not None:
                meta['homepage'] = app.homepage
            apps[appid] = {
                'url': app.download_url,
                'sha256': app.hash_or_sig,
                'version': str(app.version),
                'meta': meta,
            }

    ncver = info.nextcloud.version
    ncverstr = f"{ncver.major}.{ncver.minor}.{ncver.patch}.{ncver.build[0]}"
    return {
        'nextcloud': {
            'version': ncverstr,
            'sha256': info.nextcloud.sha256,
            'url': info.nextcloud.download_url,
        },
        'applications': apps,
    }


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

    old = import_data(current_state)
    new = api.upgrade(old)
    diff = ReleaseDiff(old, new)

    has_differences = diff.has_differences()
    if not has_differences:
        return

    ncpath: str = nix.get_nextcloud_store_path(new.nextcloud)
    joined = diff.join()

    to_download: Dict[AppId, ExternalApp] = {}
    for appid, app in joined.apps.items():
        if not isinstance(app, ExternalApp):
            continue

        if isinstance(app.hash_or_sig, SignatureInfo):
            to_download[appid] = app

    if to_download:
        for appid, app in tqdm(to_download.items(),
                               desc='Fetching updated and new applications',
                               ascii=True):

            try:
                sha256: Sha256 = fetch_app_hash(ncpath, app)
            except Exception as e:
                msg = f"Exception occured while fetching {repr(app)}: {e}"
                tqdm.write(msg, file=sys.stderr)
                joined.apps[appid] = old.apps[appid]
                continue

            joined.apps[appid] = app._replace(hash_or_sig=sha256)

    pretty_printed: str = diff.pretty_print()
    if pretty_printed:
        tqdm.write("\n" + pretty_printed, file=sys.stderr)

    with open(info_file, 'w') as newstate:
        json.dump(export_data(joined), newstate, indent=2, sort_keys=True)
        newstate.write('\n')
