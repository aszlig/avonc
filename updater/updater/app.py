import base64
import re
import string
import os

from OpenSSL import crypto

from .progress import download_pbar
from .nix import hash_zip_content
from .types import App, InternalApp, SignatureInfo, Sha256

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


def fetch_app_hash(ncpath: str, app: App) -> Sha256:
    if isinstance(app, InternalApp):
        raise ValueError("Can't download internal app {repr(app)}.")
    if not isinstance(app.hash_or_sig, SignatureInfo):
        raise ValueError("Signature information missing for {repr(appdata)}")

    cert = verify_cert(ncpath, app.hash_or_sig.certificate)
    # Apps do have a signature, so even if the remote's cert check fails, we
    # can still proceed.
    data = download_pbar(app.download_url, verify=False,
                         desc='Downloading app {!r}'.format(app.name))
    sig = base64.b64decode(app.hash_or_sig.signature)
    crypto.verify(cert, sig, data, 'sha512')
    fname_base = app.download_url.rsplit('/', 1)[-1].rsplit('?', 1)[0]
    valid_chars = string.ascii_letters + string.digits + "._-"
    safename: str = ''.join(c for c in fname_base if c in valid_chars)
    return Sha256(hash_zip_content(safename.lstrip('.'), data))
