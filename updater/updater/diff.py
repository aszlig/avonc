from typing import Dict, Tuple

from .types import ReleaseInfo, AppChanges, AppCollection, AppId, App, \
                   ExternalApp, Changelogs, VersionChanges, InternalOrVersion


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
    def changed_apps(self) -> Dict[AppId, ExternalApp]:
        common = set(self.old.apps.keys()).intersection(self.new.apps.keys())
        result: Dict[AppId, ExternalApp] = {}
        for appid in common:
            old = self.old.apps[appid]
            new = self.new.apps[appid]
            if not isinstance(old, ExternalApp) or \
               not isinstance(new, ExternalApp):
                continue
            if old.version != new.version:
                result[appid] = new
        return result

    def _filter_changelogs(self, changelogs: Changelogs,
                           oldver: InternalOrVersion,
                           newver: InternalOrVersion) -> Changelogs:
        result: Changelogs = {}
        for version, changelog in changelogs.items():
            if newver is not None and version > newver:
                continue
            if oldver is not None and version <= oldver:
                continue
            result[version] = changelog
        return result

    def get_changes(self) -> AppChanges:
        up: Dict[AppId, VersionChanges] = {}
        down: Dict[AppId, Tuple[InternalOrVersion, InternalOrVersion]] = {}
        for appid, app in self.changed_apps.items():
            old_app: App = self.old.apps[appid]

            oldver: InternalOrVersion = None
            if isinstance(old_app, ExternalApp):
                oldver = old_app.version

            newver: InternalOrVersion = None
            if isinstance(app, ExternalApp):
                newver = app.version

            if oldver < newver:
                up[appid] = VersionChanges(
                    old_version=oldver,
                    new_version=newver,
                    changelogs=self._filter_changelogs(
                        app.changelogs, oldver, newver
                    )
                )
            else:
                down[appid] = (oldver, newver)

        return AppChanges(
            added={appid: app.version if isinstance(app, ExternalApp) else None
                   for appid, app in self.added_apps.items()},
            removed=set(self.removed_apps.keys()),
            updated=up, downgraded=down,
        )

    def has_differences(self) -> bool:
        if self.old.nextcloud.version != self.new.nextcloud.version:
            return True

        return bool(self.removed_apps or self.added_apps or self.changed_apps)

    def join(self) -> ReleaseInfo:
        updated_ids = self.changed_apps.keys()
        apps: AppCollection = self.new.apps.copy()
        for appid, app in apps.items():
            if appid not in self.old.apps:
                continue
            if appid in updated_ids:
                continue
            apps[appid] = self.old.apps[appid]

        return ReleaseInfo(self.new.nextcloud, apps, self.old.constraints)
