import textwrap

from typing import List, Optional

from .types import AppChanges


def _format_changelog(changelog: str, indent: str) -> str:
    if changelog == '':
        return indent + "No changelog provided.\n"
    else:
        return textwrap.indent(changelog.strip(), indent) + "\n"


def pretty_print_changes(major: Optional[int], changes: AppChanges) -> str:
    out: List[str] = []

    if changes.added:
        if major is None:
            out.append("Apps added for all major versions:\n")
        else:
            out.append(f"Apps added for major version {major}:\n")
        for appid, version in sorted(changes.added.items()):
            if version is not None:
                out.append(f"  {appid} ({version})")
            else:
                out.append(f"  {appid}")
        out.append("")

    if changes.updated:
        if major is None:
            out.append("Apps updated for all major versions:\n")
        else:
            out.append(f"Apps updated for major version {major}:\n")
        for appid, vinfo in sorted(changes.updated.items()):
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

    if changes.removed:
        if major is None:
            out.append("Apps removed for all major versions:\n")
        else:
            out.append(f"Apps removed for major version {major}:\n")
        out.append("  " + "\n  ".join(sorted(changes.removed)) + "\n")

    return "\n".join(out)
