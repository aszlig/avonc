from typing import Optional


class Version:
    major: int
    minor: int
    patch: int
    prerelease: int
    build: int

    partial: bool

    def __init__(self,
                 version_string: Optional[str] = ...,
                 major: Optional[int] = ...,
                 minor: Optional[int] = ...,
                 patch: Optional[int] = ...,
                 prerelease: Optional[str] = ...,
                 build: Optional[str] = ...,
                 partial: bool = ...): ...

    def __eq__(self, other: object) -> bool: ...
    def __ne__(self, other: object) -> bool: ...
    def __lt__(self, other: object) -> bool: ...
    def __le__(self, other: object) -> bool: ...
    def __gt__(self, other: object) -> bool: ...
    def __ge__(self, other: object) -> bool: ...


class Spec:
    def __init__(self, *expressions: str): ...
    def match(self, version: Version) -> bool: ...
