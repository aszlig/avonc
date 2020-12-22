import textwrap

from collections import defaultdict
from typing import List, Optional, Dict, Tuple, FrozenSet, TypeVar, \
                   Hashable, Callable, DefaultDict, NamedTuple, overload

from .types import AppChanges, AppId, InternalOrVersion, VersionChanges

T = TypeVar('T')
TH = TypeVar('TH', bound=Hashable)

RegroupOut = Dict[Optional[FrozenSet[int]], List[TH]]


class AppChangeCollection(NamedTuple):
    added: RegroupOut[Tuple[AppId, InternalOrVersion]]
    removed: RegroupOut[AppId]
    updated: RegroupOut[Tuple[AppId, VersionChanges]]
    downgraded: RegroupOut[Tuple[AppId, InternalOrVersion, InternalOrVersion]]


def _format_changelog(changelog: str, indent: str) -> str:
    if changelog == '':
        return indent + "No changelog provided.\n"
    else:
        return textwrap.indent(changelog.strip(), indent) + "\n"


@overload
def _regroup(items: Dict[int, List[TH]]) -> RegroupOut[TH]:
    ...


@overload
def _regroup(items: Dict[int, List[T]],
             key: Callable[[T], TH]) -> RegroupOut[T]:
    ...


def _regroup(items, key=None):
    """
    >>> values = {
    ...     12: ["app1", "app2", "app4"],
    ...     13: ["app2", "api4"],
    ...     14: ["app1", "app3", "app4"],
    ... }
    >>> result = _regroup(values)
    >>> len(result)
    4
    >>> result[frozenset({12, 14})]
    ['app1', 'app4']
    >>> result[frozenset({12, 13})]
    ['app2']
    >>> result[frozenset({13})]
    ['api4']
    >>> result[frozenset({14})]
    ['app3']
    >>> result = _regroup(values, key=lambda x: x[3])
    >>> len(result)
    4
    >>> result[frozenset({12, 14})]
    ['app1']
    >>> result[frozenset({12, 13})]
    ['app2']
    >>> result[frozenset({14})]
    ['app3']
    >>> result[None]
    ['app4']
    """
    all_majors = frozenset(items.keys())
    result: DefaultDict[Optional[FrozenSet[int]], List[T]] = defaultdict(list)

    realvals: Dict[TH, T] = {}
    for values in items.values():
        for value in values:
            if key is None:
                realvals[value] = value
            else:
                realvals[key(value)] = value

    for value in frozenset(realvals.keys()):
        majors = frozenset([
            major for major, vals in items.items()
            if value in (vals if key is None else map(key, vals))
        ])
        if majors == all_majors:
            result[None].append(realvals[value])
        else:
            result[majors].append(realvals[value])

    return dict(result)


def _narrow_changes(changeset: Dict[int, AppChanges]) -> AppChangeCollection:
    return AppChangeCollection(
        added=_regroup(
            {major: list(changes.added.items())
             for major, changes in changeset.items()}
        ),
        removed=_regroup(
            {major: list(changes.removed)
             for major, changes in changeset.items()}
        ),
        updated=_regroup(
            {major: list(changes.updated.items())
             for major, changes in changeset.items()},
            key=lambda x: (x[0], x[1].old_version, x[1].new_version)
        ),
        downgraded=_regroup(
            {major: [(k, v[0], v[1]) for k, v in changes.downgraded.items()]
             for major, changes in changeset.items()},
        ),
    )


def _format_description(action: str, majors: Optional[FrozenSet[int]]) -> str:
    if majors is None:
        return f"Apps {action} for all major versions:\n"

    if len(majors) == 1:
        mstr = str(next(iter(majors)))
    else:
        majors_str = [str(m) for m in majors]
        mstr = ', '.join(majors_str[:-1]) + ' and ' + majors_str[-1]

    return f"Apps {action} for major version {mstr}:\n"


def pretty_print_changes(changeset: Dict[int, AppChanges]) -> str:
    changes: AppChangeCollection = _narrow_changes(changeset)
    out: List[str] = []

    for majors, added in changes.added.items():
        out.append(_format_description("added", majors))
        for appid, version in sorted(added):
            if version is not None:
                out.append(f"  {appid} ({version})")
            else:
                out.append(f"  {appid}")
        out.append("")

    for majors, updated in changes.updated.items():
        out.append(_format_description("updated", majors))
        for appid, vinfo in sorted(updated):
            changelog: str
            if vinfo.old_version is None:
                out.append(f'  {appid} (internal -> {vinfo.new_version})\n')
                changelog = 'The app has been moved out of Nextcloud' \
                            ' Server and is now an external app.'
                out.append(_format_changelog(changelog, '    '))
            elif vinfo.new_version is None:
                out.append(f'  {appid} ({vinfo.old_version} -> internal)\n')
                changelog = 'The app is now part of Nextcloud Server.'
                out.append(_format_changelog(changelog, '    '))
            else:
                out.append(f"  {appid} ({vinfo.old_version}"
                           f" -> {vinfo.new_version}):\n")
                if len(vinfo.changelogs) > 1:
                    for version in sorted(vinfo.changelogs.keys(),
                                          reverse=True):
                        changelog = vinfo.changelogs[version]
                        out.append(f"    Changes for version {version}:\n")
                        out.append(_format_changelog(changelog, '      '))
                else:
                    clentry = vinfo.changelogs[vinfo.new_version]
                    out.append(_format_changelog(clentry, '    '))

    for majors, downgraded in changes.downgraded.items():
        out.append(_format_description("downgraded", majors))
        maxlen = max(len(d[0]) for d in downgraded)
        for appid, prev_ver, next_ver in sorted(downgraded):
            label = f'{appid}:'.ljust(maxlen + 2)
            out.append(f"  {label}{prev_ver} -> {next_ver}\n")

    for majors, removed in changes.removed.items():
        out.append(_format_description("removed", majors))
        out.append("  " + "\n  ".join(sorted(removed)) + "\n")

    return "\n".join(out)
