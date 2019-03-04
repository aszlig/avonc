#!/usr/bin/env nix-shell
#!nix-shell -i python -p python3Packages.python --argstr # noqa
#!nix-shell -p python3Packages.requests         --argstr # noqa
#!nix-shell -p python3Packages.defusedxml       --argstr # noqa
#!nix-shell -p erlang                           --argstr # noqa
import hashlib
import io
import json
import os
import re
import requests
import subprocess
import tarfile

from defusedxml import ElementTree as ET  # type: ignore
from typing import Optional, Tuple, Dict, List, Any

BASEDIR = os.path.dirname(os.path.realpath(__file__))
RELEASE_URL = 'https://api.github.com/repos/esl/MongooseIM/releases/latest'
GITHUB_RE = re.compile(r'^https?://github\.com/([^/]+)/([^/]+)')


def get_latest_version() -> str:
    response = requests.get(RELEASE_URL)
    response.raise_for_status()
    return response.json()['tag_name']


def fetchgithub(repo_owner: str, rev: str) -> Tuple[str, str]:
    url = f'https://github.com/{repo_owner}/archive/{rev}.tar.gz'
    cmd = ['nix-prefetch-url', '--print-path', '--name', 'source', '--unpack',
           '--type', 'sha256', url]
    output = subprocess.run(cmd, capture_output=True, check=True).stdout
    sha, path = output.decode().splitlines()
    return (sha, path)


def fetch_version(tag: str) -> Tuple[str, str]:
    return fetchgithub('esl/MongooseIM', tag)


def is_version_newer(ver1: str, ver2: str) -> bool:
    return tuple(int(x) for x in ver1.split('.')) \
         < tuple(int(x) for x in ver2.split('.'))


def fetch_subdeps(path: str) -> List[str]:
    cfgfile = os.path.join(path, 'rebar.config')
    if not os.path.exists(cfgfile):
        return []
    cmd = ['escript', os.path.join(BASEDIR, 'tools', 'getdeps.erl'), cfgfile]
    xml = ET.fromstring(subprocess.check_output(cmd))
    result = []
    for dep in xml:
        assert dep.tag == "dep"
        result.append(dep.text)
    return result


def fetch_dep_version(path: str) -> str:
    cmd = ['escript', os.path.join(BASEDIR, 'tools', 'getversion.erl'), path]
    return subprocess.check_output(cmd).decode().rstrip()


def fetch_hex(pkg: str, version: str, sha: str) -> Tuple[str, List[str]]:
    tarball = requests.get(f'https://repo.hex.pm/tarballs/{pkg}-{version}.tar')
    tarball.raise_for_status()
    with tarfile.open(fileobj=io.BytesIO(tarball.content)) as tf:
        buf: bytes = b''
        for member in ['VERSION', 'metadata.config', 'contents.tar.gz']:
            extracted = tf.extractfile(member)
            assert extracted is not None, \
                "Unable to find {member} for package {pkg}."
            buf += extracted.read()
        newsha = hashlib.sha256(buf).hexdigest().lower()
        assert newsha == sha.lower(), \
            f"The hash for {pkg!r} is {newsha} but {sha.lower()} was expected."
    cmd = ['nix-hash', '--type', 'sha256', '--to-base32',
           hashlib.sha256(tarball.content).hexdigest()]
    result_sha = subprocess.check_output(cmd).decode().rstrip()
    expr = "(import <nixpkgs> {}).beamPackages.fetchHex"
    cmd = ['nix-build', '--argstr', 'pkg', pkg, '--argstr', 'version', version,
           '--argstr', 'sha256', result_sha, '-E', expr]
    storepath = subprocess.check_output(cmd).decode().rstrip()
    return result_sha, fetch_subdeps(storepath)


def fetch_deps(mim_path: str) -> Dict[str, Any]:
    cmd = ['escript', os.path.join(BASEDIR, 'tools', 'extract_lockfile.erl'),
           os.path.join(mim_path, 'rebar.lock')]
    xml = ET.fromstring(subprocess.check_output(cmd))
    deps: Dict[str, Any] = {}
    for dep in xml.iterfind('dependency'):
        name: str = dep.attrib['name']
        level: int = int(dep.attrib['level'])
        sha: Optional[str] = None
        src: Optional[Dict[str, str]] = None
        version: str = None
        subdeps: List[str] = []

        children = list(dep)
        assert len(children) == 1
        child = children[0]
        if child.tag == "git":
            github = GITHUB_RE.match(child.attrib['url'])
            if github is not None:
                repo_owner = github.group(1) + '/' + github.group(2)
                if repo_owner.endswith('.git'):
                    repo_owner = repo_owner[:-4]
                sha, path = fetchgithub(repo_owner, child.attrib['revision'])
                subdeps = fetch_subdeps(path)
                src = {
                    'fetchtype': 'github',
                    'repo': github.group(2),
                    'owner': github.group(1),
                    'rev': child.attrib['revision'],
                }
                version = fetch_dep_version(path)
        elif child.tag == "pkg":
            sha, subdeps = fetch_hex(child.attrib['name'],
                                     child.attrib['version'],
                                     child.attrib['hash'])
            src = {
                'fetchtype': 'hex',
                'name': child.attrib['name'],
            }
            version = child.attrib['version']
        else:
            msg = f"Unknown tag {child.tag} in dependency {name}"
            raise AssertionError(msg)

        assert src is not None, f"No source found for dependency {name}"
        assert sha is not None, f"No hash found for dependency {name}"
        assert version is not None, f"No version found for dependency {name}"

        deps[name] = {
            'src': src,
            'version': '0.0.0' if version == '%VSN%' else version,
            'level': level,
            'sha256': sha,
            'subdeps': subdeps,
        }

    return deps


def main(info_file: str) -> None:
    state: Dict[str, Any]
    try:
        with open(info_file, 'r') as current:
            state = json.load(current)
    except FileNotFoundError:
        state = {}

    latest: str = get_latest_version()
    mongooseim: Dict[str, str] = state.get('mongooseim', {})
    version: Optional[str] = mongooseim.get('version')

    if version is not None and not is_version_newer(version, latest):
        print("Nothing to update.")
        return

    print(f"Updating MongooseIM from {version} to {latest}.")
    version = mongooseim['version'] = latest

    sha, mim_path = fetch_version(version)
    mongooseim['sha256'] = sha
    state['dependencies'] = fetch_deps(mim_path)
    state['mongooseim'] = mongooseim

    with open(info_file, 'w') as newstate:
        json.dump(state, newstate, indent=2, sort_keys=True)
        newstate.write('\n')


if __name__ == '__main__':
    info_file: str = os.path.join(BASEDIR, 'upstream.json')
    main(info_file)
