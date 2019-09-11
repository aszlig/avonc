from typing import NewType, NamedTuple, List, Dict, Optional


AppId = NewType('AppId', str)


class App(NamedTuple):
    name: str
    version: str
    summary: str
    description: str
    homepage: Optional[str]
    licenses: List[str]
    download_url: str

    certificate: Optional[str] = None
    signature: Optional[str] = None
    changelogs: Dict[str, str] = {}


class Nextcloud(NamedTuple):
    version: str
    download_url: Optional[str] = None
    sha256: Optional[str] = None


class Spec(NamedTuple):
    nextcloud: Nextcloud = Nextcloud('15')
    apps: Dict[AppId, App] = {}
