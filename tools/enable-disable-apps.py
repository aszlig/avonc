import json
import subprocess
import sys

from typing import Dict, List, Any, Optional

NEWSTATE: Dict[str, Dict[str, Any]] = json.load(open(sys.argv[1], 'r'))
OCC_CMD: List[str] = sys.argv[2:]


def get_appconfig() -> Dict[str, Any]:
    cmd = OCC_CMD + ['config:list', '--private', '--output=json']
    return json.loads(subprocess.check_output(cmd))['apps']


def set_appconfig(appid: str, key: str, value: str) -> None:
    args = ['config:app:set', appid, key, '--value=' + value]
    subprocess.check_call(OCC_CMD + args)


def get_applist() -> Dict[str, Any]:
    cmd = OCC_CMD + ['app:list', '--output=json']
    return json.loads(subprocess.check_output(cmd))


def enable_app(appid: str, groups: Optional[List[str]] = None) -> None:
    if groups is None:
        groups = []
    groupargs = [arg for group in groups for arg in ['-g', group]]
    subprocess.check_call(OCC_CMD + ['app:enable'] + groupargs + [appid])


def disable_app(appid: str) -> None:
    subprocess.check_call(OCC_CMD + ['app:disable', appid])


oldconfig = get_appconfig()
oldstate = get_applist()

if 'enable' in NEWSTATE:
    newenabled = set(NEWSTATE['enable'].keys()) \
               - set(oldstate['enabled'].keys())

    for appid in newenabled:
        groups = NEWSTATE['enable'][appid]
        if groups is not None:
            enable_app(appid, groups)
        else:
            enable_app(appid)

    for appid, cfg in NEWSTATE.get('appconf', {}).items():
        oldcfg = oldconfig.get(appid, {})
        for key, val in cfg.items():
            oldval = oldcfg.get(key)
            if oldval is not None and oldval == val:
                continue
            set_appconfig(appid, key, val)

newdisabled = set(NEWSTATE['disable']) \
            - set(oldstate['disabled'].keys())

for appid in newdisabled:
    if appid not in oldstate['enabled'] and \
       appid not in oldstate['disabled']:
        continue
    disable_app(appid)
