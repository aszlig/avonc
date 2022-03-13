import requests
import warnings

from typing import Optional
from tqdm import tqdm
from urllib3.exceptions import InsecureRequestWarning


def download_pbar(url: str, verify: bool = True,
                  desc: Optional[str] = None) -> bytes:
    if verify:
        response = requests.get(url, stream=True)
    else:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", InsecureRequestWarning)
            response = requests.get(url, stream=True, verify=False)

    response.raise_for_status()

    file_size = int(response.headers.get('content-length', 0))
    buf: bytes = b''
    pbar: tqdm = tqdm(desc=desc, total=file_size, unit='B', unit_scale=True,
                      ascii=True)
    chunksize: int = max(file_size // 100, 8192)
    try:
        for data in response.iter_content(chunk_size=chunksize):
            buf += data
            pbar.update(len(data))
    finally:
        pbar.close()
    return buf
