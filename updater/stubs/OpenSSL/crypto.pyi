from typing import Union, NewType

FileType = NewType('FileType', int)
StoreFlagType = NewType('StoreFlagType', int)

FILETYPE_PEM: FileType = ...
FILETYPE_ASN1: FileType = ...


class CRL:
    pass


class X509:
    pass


class X509StoreFlags:
    CRL_CHECK: StoreFlagType = ...


class X509Store:
    def add_cert(self, cert: X509) -> None: ...
    def add_crl(self, crl: CRL) -> None: ...
    def set_flags(self, flags: StoreFlagType) -> None: ...


class X509StoreContext:
    def __init__(self, store: X509Store, certificate: X509): ...
    def verify_certificate(self) -> None: ...


class PKey:
    pass


def load_certificate(type: FileType, buffer: Union[bytes, str]) -> X509: ...


def load_crl(type: FileType, buffer: Union[bytes, str]) -> CRL: ...


def verify(cert: X509, signature: bytes, data: bytes,
           digest: Union[bytes, str]) -> None: ...
