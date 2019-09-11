import requests
import warnings

from tqdm import tqdm  # type: ignore
from requests.packages.urllib3.exceptions import InsecureRequestWarning


def download_pbar(url, **kwargs) -> bytes:
    verify = kwargs.pop('verify', True)

    if verify:
        response = requests.get(url, stream=True)
    else:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", InsecureRequestWarning)
            response = requests.get(url, stream=True, verify=False)

    response.raise_for_status()

    file_size = int(response.headers.get('content-length', 0))
    kwargs['total'] = file_size
    kwargs['unit'] = 'B'
    kwargs['unit_scale'] = True
    kwargs['ascii'] = True
    buf: bytes = b''
    pbar = tqdm(**kwargs)
    chunksize: int = max(file_size // 100, 8192)
    try:
        for data in response.iter_content(chunk_size=chunksize):
            buf += data
            pbar.update(len(data))
    finally:
        pbar.close()
    return buf
