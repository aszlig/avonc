import base64
import re
import string
import os

from typing import Dict
from OpenSSL import crypto

from .progress import download_pbar
from .nix import hash_zip_content
from .types import App

PEM_RE = re.compile('-----BEGIN .+?-----\r?\n.+?\r?\n-----END .+?-----\r?\n?',
                    re.DOTALL)


def verify_cert(ncpath: str, certdata: str) -> crypto.X509:
    capath = os.path.join(ncpath, 'resources/codesigning/root.crt')
    crlpath = os.path.join(ncpath, 'resources/codesigning/root.crl')

    store = crypto.X509Store()
    with open(capath, 'r') as cafile:
        for match in PEM_RE.finditer(cafile.read()):
            ca = crypto.load_certificate(crypto.FILETYPE_PEM, match.group(0))
            store.add_cert(ca)

    with open(crlpath, 'r') as crlfile:
        crl = crypto.load_crl(crypto.FILETYPE_PEM, crlfile.read())
    store.add_crl(crl)
    store.set_flags(crypto.X509StoreFlags.CRL_CHECK)

    cert = crypto.load_certificate(crypto.FILETYPE_PEM, certdata)
    ctx = crypto.X509StoreContext(store, cert)
    ctx.verify_certificate()
    return cert


def fetch_app(ncpath: str, appid: str, appdata: App) -> Dict[str, str]:
    if appdata.certificate is None or appdata.signature is None:
        raise ValueError("Signature information missing for {repr(appdata)}")

    cert = verify_cert(ncpath, appdata.certificate)
    # Apps do have a signature, so even if the remote's cert check fails, we
    # can still proceed.
    data = download_pbar(appdata.download_url, verify=False,
                         desc='Downloading app {!r}'.format(appdata.name))
    sig = base64.b64decode(appdata.signature)
    crypto.verify(cert, sig, data, 'sha512')
    fname_base = appdata.download_url.rsplit('/', 1)[-1].rsplit('?', 1)[0]
    valid_chars = string.ascii_letters + string.digits + "._-"
    safename: str = ''.join(c for c in fname_base if c in valid_chars)
    ziphash: str = hash_zip_content(safename.lstrip('.'), data)

    return {
        'version': str(appdata.version),
        'url': appdata.download_url,
        'sha256': ziphash
    }
