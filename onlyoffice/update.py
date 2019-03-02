#!/usr/bin/env nix-shell
#!nix-shell -i python --argstr # noqa
#!nix-shell -p nix --argstr # noqa
#!nix-shell -p python3Packages.python --argstr # noqa
#!nix-shell -p nodePackages.node2nix --argstr # noqa

import json
import os
import subprocess
import tempfile

from typing import List, Dict

BASEDIR = os.path.dirname(os.path.realpath(__file__))
OUTDIR = os.path.join(BASEDIR, 'node-deps')

PACKAGES: Dict[str, str] = {
    'sdkjs': 'sdkjs/build',
    'webapps': 'web-apps/build',
    'server': 'server',
    'server-common': 'server/Common',
    'server-docservice': 'server/DocService',
    'server-fileconverter': 'server/FileConverter',
    'server-metrics': 'server/Metrics',
    'server-spellchecker': 'server/SpellChecker',
}


def get_source() -> str:
    expr = '((import <nixpkgs> {}).callPackage ./source.nix {}).src'
    cmd = ['nix-build', '--no-out-link', '-E', expr]
    result = subprocess.run(cmd, cwd=BASEDIR, capture_output=True, check=True)
    return result.stdout.strip().decode()


def get_package_desc(descfile: str) -> List[Dict[str, str]]:
    contents = json.load(open(descfile, 'r'))
    return [{k: v} for k, v in contents['dependencies'].items()]


def node2nix(desc: List[Dict[str, str]], prefix: str) -> None:
    os.makedirs(os.path.join(OUTDIR, prefix), exist_ok=True)
    with tempfile.NamedTemporaryFile('w+') as fp:
        json.dump(desc, fp)
        fp.flush()
        cmd = [
            'node2nix', '--nodejs-10',
            '-e', os.path.join(OUTDIR, 'node-env.nix'),
            '-o', os.path.join(OUTDIR, prefix, 'node-packages.nix'),
            '-c', os.path.join(OUTDIR, prefix, 'default.nix'),
            '-i', fp.name
        ]
        subprocess.run(cmd, check=True)


def update() -> None:
    src = get_source()
    for pname, path in PACKAGES.items():
        desc = get_package_desc(os.path.join(src, path, 'package.json'))
        node2nix(desc, pname)


if __name__ == '__main__':
    update()
