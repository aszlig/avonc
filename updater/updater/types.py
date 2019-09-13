from semantic_version import Version
from typing import NewType, NamedTuple, List, Dict, Optional, Union


AppId = NewType('AppId', str)
Sha256 = NewType('Sha256', str)

App = Union['InternalApp', 'ExternalApp']
AppCollection = Dict[AppId, App]


class InternalApp(NamedTuple):
    name: str
    summary: str
    description: str
    licenses: List[str]
    enabled_by_default: bool


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
    changelogs: Dict[Version, str] = {}


class Nextcloud(NamedTuple):
    version: Version
    download_url: str
    sha256: str


class ReleaseInfo(NamedTuple):
    nextcloud: Nextcloud
    apps: AppCollection = {}