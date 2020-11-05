import json
import subprocess
import sys

from typing import Dict, List, Any

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


def enable_apps(appids: List[str]) -> None:
    subprocess.check_call(OCC_CMD + ['app:enable', '--'] + appids)


def disable_apps(appids: List[str]) -> None:
    subprocess.check_call(OCC_CMD + ['app:disable', '--'] + appids)


def enable_app_with_groups(appid: str, groups: List[str]) -> None:
    groupargs = [arg for group in groups for arg in ['-g', group]]
    subprocess.check_call(OCC_CMD + ['app:enable'] + groupargs + [appid])


oldconfig = get_appconfig()
oldstate = get_applist()

if 'enable' in NEWSTATE:
    newenabled = set(NEWSTATE['enable'].keys()) \
               - set(oldstate['enabled'].keys())

    to_enable = []
    for appid in newenabled:
        groups = NEWSTATE['enable'][appid]
        if groups is not None:
            enable_app_with_groups(appid, groups)
        else:
            to_enable.append(appid)

    if to_enable:
        enable_apps(to_enable)

    for appid, cfg in NEWSTATE.get('appconf', {}).items():
        oldcfg = oldconfig.get(appid, {})
        for key, val in cfg.items():
            oldval = oldcfg.get(key)
            if oldval is not None and oldval == val:
                continue
            set_appconfig(appid, key, val)

newdisabled = set(NEWSTATE['disable']) \
            - set(oldstate['disabled'].keys())

to_disable = []
for appid in newdisabled:
    if appid not in oldstate['enabled'] and \
       appid not in oldstate['disabled']:
        continue
    to_disable.append(appid)

if to_disable:
    disable_apps(to_disable)
