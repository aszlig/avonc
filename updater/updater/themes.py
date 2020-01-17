import requests

from typing import Dict, Union, NamedTuple, Callable, cast
from tqdm import tqdm

from .nix import fetch_from_github
from .types import ThemeCollection, ThemeId, Theme, FetchMethod, \
                   FetchFromGitHub, Sha256

__all__ = ['upgrade', 'import_data', 'export_data']


class ThemeInfo(NamedTuple):
    upstream: FetchMethod
    directory: str
    branch_fun: Callable[[int], str]


THEME_INFO_MAP: Dict[ThemeId, ThemeInfo] = {
    ThemeId('breeze-dark'): ThemeInfo(
        FetchFromGitHub('mwalbeck', 'nextcloud-breeze-dark'),
        'nextcloud-breeze-dark',
        lambda nc_major: str(nc_major),
    ),
}


def _get_github_branch_head(owner: str, repo: str, branch: str) -> str:
    url = f'https://api.github.com/repos/{owner}/{repo}/branches/{branch}'
    response = requests.get(url)
    response.raise_for_status()
    return response.json()['commit']['sha']


def _update_theme(branch: str, old_theme: Theme) -> Theme:
    if isinstance(old_theme.upstream, FetchFromGitHub):
        github_info = old_theme.upstream
        new_head = _get_github_branch_head(github_info.owner, github_info.repo,
                                           branch)
        if new_head == github_info.rev:
            return old_theme
        else:
            sha: Sha256 = fetch_from_github(github_info.owner,
                                            github_info.repo, new_head)
            upstream = FetchFromGitHub(github_info.owner, github_info.repo,
                                       new_head, sha)
            return Theme(upstream, old_theme.directory)
    else:
        raise TypeError(f"Unknown upstream info {repr(old_theme.upstream)}.")


def upgrade(nc_major: int, old: ThemeCollection) -> ThemeCollection:
    old_themes: ThemeCollection = old.copy()
    for themeid, attrs in THEME_INFO_MAP.items():
        if themeid not in old_themes:
            continue
        old_themes[themeid] = Theme(attrs.upstream, attrs.directory)

    if len(old_themes) == 0:
        return old_themes

    themes: ThemeCollection = {}
    desc = f'Updating themes for Nextcloud {nc_major}'
    for themeid in tqdm(old_themes, desc=desc, ascii=True):
        if themeid in THEME_INFO_MAP:
            updated = _update_theme(
                THEME_INFO_MAP[themeid].branch_fun(nc_major),
                old_themes[themeid]
            )
        else:
            raise KeyError(f"Unknown theme identifier {repr(themeid)}.")
        themes[themeid] = updated

    return themes


# XXX: Use TypedDict once it lands in typing and remove all the casts below.
RawData = Dict[str, Dict[str, Union[str, Dict[str, str]]]]


def import_data(data: RawData) -> ThemeCollection:
    result: ThemeCollection = {}
    for theme_name, attrs in data.items():
        if 'github' in attrs:
            github = cast(Dict[str, str], attrs['github'])
            upstream = FetchFromGitHub(
                github['owner'],
                github['repo'],
                github['rev'],
                Sha256(github['sha256']),
            )
        else:
            raise KeyError(f"Unsupported upstream info for {repr(attrs)}.")
        result[ThemeId(theme_name)] = Theme(upstream,
                                            cast(str, attrs['directory']))
    return result


def export_data(themes: ThemeCollection) -> RawData:
    result: RawData = {}
    for themeid, theme in themes.items():
        attrs: Dict[str, Union[str, Dict[str, str]]] = {
            'directory': theme.directory
        }
        if isinstance(theme.upstream, FetchFromGitHub):
            assert theme.upstream.rev is not None
            assert theme.upstream.sha256 is not None
            attrs['github'] = {
                'owner': theme.upstream.owner,
                'repo': theme.upstream.repo,
                'rev': theme.upstream.rev,
                'sha256': theme.upstream.sha256,
            }
        else:
            raise TypeError(f"Unknown upstream info {repr(theme.upstream)}.")
        result[themeid] = attrs
    return result
