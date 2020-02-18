from typing import Dict, Any, Optional, Tuple
from semantic_version import Version, Spec
from tqdm import tqdm

import json
import os
import sys

from .types import AppId, App, InternalApp, ExternalApp, Nextcloud, \
                   ReleaseInfo, Sha256, SignatureInfo, AppChanges
from .app import fetch_app_hash
from . import api, nix, themes
from .diff import ReleaseDiff
from .changelogs import pretty_print_changes


def import_data(data: Dict[str, Any], major: int) -> ReleaseInfo:
    nextcloud_data = data.get('nextcloud', {})
    version_str = nextcloud_data.get('version')
    version = None if version_str is None else Version.coerce(version_str)
    nextcloud = Nextcloud(
        version,
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
    themes_ = themes.import_data(data.get('themes', {}))
    constraints_data = data.get('constraints', {})
    constraints = {AppId(appid): Spec(exprs)
                   for appid, exprs in constraints_data.items()}
    return ReleaseInfo(nextcloud, apps, themes_, constraints)


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
    assert ncver is not None, "Can't export non-existing Nextcloud version"
    ncverstr = f"{ncver.major}.{ncver.minor}.{ncver.patch}.{ncver.build[0]}"
    result = {
        'nextcloud': {
            'version': ncverstr,
            'sha256': info.nextcloud.sha256,
            'url': info.nextcloud.download_url,
        },
        'applications': apps,
        'themes': themes.export_data(info.themes),
    }
    if info.constraints:
        result['constraints'] = {appid: str(spec)
                                 for appid, spec in info.constraints.items()}
    return result


def update_major(major: int, info_file: str) -> Optional[
    Tuple[str, AppChanges]
]:
    current_state: Dict[str, Any]
    try:
        with open(info_file, 'r') as current:
            current_state = json.load(current)
    except FileNotFoundError:
        current_state = {}

    old: ReleaseInfo = import_data(current_state, major)
    new_apps: ReleaseInfo = api.upgrade(major, old)
    new: ReleaseInfo = new_apps._replace(
        themes=themes.upgrade(major, new_apps.themes)
    )
    diff = ReleaseDiff(old, new)

    has_differences = diff.has_differences()
    if not has_differences:
        return None

    ncpath: str = nix.get_nextcloud_store_path(new.nextcloud)
    joined: ReleaseInfo = diff.join()

    to_download: Dict[AppId, ExternalApp] = {}
    for appid, app in joined.apps.items():
        if not isinstance(app, ExternalApp):
            continue

        if isinstance(app.hash_or_sig, SignatureInfo):
            to_download[appid] = app

    if to_download:
        desc = f'Fetching updated and new applications for' \
               f' major version {major}'
        for appid, app in tqdm(to_download.items(), desc=desc, ascii=True):
            try:
                sha256: Sha256 = fetch_app_hash(ncpath, app)
            except Exception as e:
                msg = f"Exception occured while fetching {repr(app)}: {e}"
                tqdm.write(msg, file=sys.stderr)
                if appid in old.apps:
                    joined.apps[appid] = old.apps[appid]
                else:
                    del joined.apps[appid]
                continue

            joined.apps[appid] = app._replace(hash_or_sig=sha256)

    result = json.dumps(export_data(joined), indent=2, sort_keys=True) + "\n"
    return result, diff.get_changes()


def main() -> None:
    basedir: str = os.path.join(os.getcwd(), 'packages')
    outfiles: Dict[str, str] = {}
    changeset: Dict[int, AppChanges] = {}
    for dirname in os.listdir(basedir):
        if not dirname.isdigit():
            continue

        packagedir: str = os.path.join(basedir, dirname)

        if not os.path.isdir(packagedir):
            continue

        info_file: str = os.path.join(packagedir, 'upstream.json')
        info = update_major(int(dirname), info_file)
        if info is not None:
            outfiles[info_file] = info[0]
            changeset[int(dirname)] = info[1]

    for path, data in outfiles.items():
        with open(path, 'w') as newstate:
            newstate.write(data)

    for major, changes in changeset.items():
        pretty_printed: str = pretty_print_changes(major, changes)
        if pretty_printed:
            tqdm.write("\n" + pretty_printed, file=sys.stderr)
