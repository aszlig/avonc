from semantic_version import Version, Spec
from typing import NewType, NamedTuple, List, Dict, Optional, Union, Set


AppId = NewType('AppId', str)
Sha256 = NewType('Sha256', str)

App = Union['InternalApp', 'ExternalApp']
AppCollection = Dict[AppId, App]
FetchMethod = Union['FetchFromGitHub']
Changelogs = Dict[Version, str]
InternalOrVersion = Optional[Version]


class InternalApp(NamedTuple):
    name: str
    summary: str
    description: str
    licenses: List[str]
    enabled_by_default: bool
    always_enabled: bool


class SignatureInfo(NamedTuple):
    certificate: str
    signature: str


class ExternalApp(NamedTuple):
    name: str
    version: Version
    summary: str
    description: str
    homepage: Optional[str]
    licenses: List[str]
    download_url: str
    hash_or_sig: Union[Sha256, SignatureInfo]
    changelogs: Changelogs = {}


class FetchFromGitHub(NamedTuple):
    owner: str
    repo: str
    rev: Optional[str] = None
    sha256: Optional[Sha256] = None


class Nextcloud(NamedTuple):
    version: Optional[Version]
    download_url: str
    sha256: Sha256


class ReleaseInfo(NamedTuple):
    nextcloud: Nextcloud
    apps: AppCollection
    constraints: Dict[AppId, Spec]


class VersionChanges(NamedTuple):
    old_version: InternalOrVersion
    new_version: InternalOrVersion
    changelogs: Changelogs


class AppChanges(NamedTuple):
    added: Dict[AppId, InternalOrVersion]
    removed: Set[AppId]
    updated: Dict[AppId, VersionChanges]
