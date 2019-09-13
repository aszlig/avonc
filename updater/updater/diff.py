import textwrap

from semantic_version import Version
from typing import Tuple, Dict, List
from .types import ReleaseInfo, AppCollection, AppId, App, ExternalApp


class ReleaseDiff:
    old: ReleaseInfo
    new: ReleaseInfo

    def __init__(self, old: ReleaseInfo, new: ReleaseInfo):
        self.old = old
        self.new = new

    @property
    def removed_apps(self) -> AppCollection:
        return dict.fromkeys(self.old.apps.keys() - self.new.apps.keys())

    @property
    def added_apps(self) -> AppCollection:
        return dict.fromkeys(self.new.apps.keys() - self.old.apps.keys())

    @property
    def updated_apps(self) -> Dict[AppId, ExternalApp]:
        common = set(self.old.apps.keys()).intersection(self.new.apps.keys())
        result: Dict[AppId, ExternalApp] = {}
        for appid in common:
            old = self.old.apps[appid]
            new = self.new.apps[appid]
            if not isinstance(old, ExternalApp) or \
               not isinstance(new, ExternalApp):
                continue
            if old.version < new.version:
                result[appid] = new
        return result

    def get_changes(self) -> Tuple[AppCollection, AppCollection,
                                   Dict[AppId, ExternalApp]]:
        return self.removed_apps, self.added_apps, self.updated_apps

    def has_differences(self) -> bool:
        if self.old.nextcloud.version != self.new.nextcloud.version:
            return True

        return bool(self.removed_apps or self.added_apps or self.updated_apps)

    def join(self) -> ReleaseInfo:
        updated_ids = self.updated_apps.keys()
        apps: AppCollection = self.new.apps.copy()
        for appid, app in apps.items():
            if appid not in self.old.apps:
                continue
            if appid in updated_ids:
                continue
            apps[appid] = self.old.apps[appid]

        return ReleaseInfo(self.new.nextcloud, apps, self.old.constraints)

    def _format_changelog(self, changelog: str, indent: str) -> str:
        if changelog == '':
            return indent + "No changelog provided.\n"
        else:
            return textwrap.indent(changelog.strip(), indent) + "\n"

    def _filter_changelogs(self, changelogs: Dict[Version, str],
                           oldver: Version,
                           newver: Version) -> Dict[Version, str]:
        result: Dict[Version, str] = {}
        for version, changelog in changelogs.items():
            if oldver < version <= newver:
                result[version] = changelog
        return result

    def pretty_print(self) -> str:
        removed, added, updated = self.get_changes()
        out: List[str] = []

        if added:
            out.append("Apps added:\n")
            for appid, app in sorted(added.items()):
                if isinstance(app, ExternalApp):
                    out.append(f"  {appid} ({app.version})")
                else:
                    out.append(f"  {appid}")
            out.append("")

        if updated:
            out.append("Apps updated:\n")
            for appid, app in sorted(updated.items()):
                old_app: App = self.old.apps[appid]
                if isinstance(old_app, ExternalApp):
                    old_ver: Version = old_app.version
                    new_ver: Version = app.version
                    out.append(f"  {appid} ({old_ver} -> {new_ver}):\n")
                    changelogs = self._filter_changelogs(app.changelogs,
                                                         old_ver, new_ver)
                    if len(changelogs) > 1:
                        for version in sorted(changelogs.keys(), reverse=True):
                            changelog: str = changelogs[version]
                            out.append(f"    Changes for version {version}:\n")
                            out.append(self._format_changelog(changelog,
                                                              '      '))
                    else:
                        out.append(self._format_changelog(changelogs[new_ver],
                                                          '    '))
                else:
                    out.append(f'  {appid} (internal -> {app.version})\n')
                    changelog = 'The app has been moved out of Nextcloud' \
                                ' server and is now an external app.'
                    out.append(self._format_changelog(changelog, '    '))

        if removed:
            out.append("Apps removed:\n")
            out.append("  " + "\n  ".join(sorted(removed.keys())) + "\n")

        return "\n".join(out)
