import json
import subprocess
import sys

occ_cmd = sys.argv[2:]
cmd = occ_cmd + ['app:list', '--output=json']
applist = subprocess.check_output(cmd)
oldstate = json.loads(applist)
newstate = json.load(open(sys.argv[1], 'r'))

if 'enable' in newstate:
    newenabled = set(newstate['enable'].keys()) \
               - set(oldstate['enabled'].keys())

    group_deferred = {}

    for appid in newenabled:
        groups = newstate['enable'][appid]
        if groups is not None:
            group_deferred[appid] = groups
            continue
        subprocess.check_call(occ_cmd + ['app:enable', appid])

    for appid, groups in group_deferred.items():
        groupargs = [arg for group in groups for arg in ['-g', group]]
        subprocess.check_call(occ_cmd + ['app:enable'] + groupargs + [appid])

    for appid in newenabled:
        for key, value in newstate.get('appconf', {}).get(appid, {}).items():
            args = ['config:app:set', appid, key, '--value=' + value]
            subprocess.check_call(occ_cmd + args)

newdisabled = set(newstate['disable']) \
            - set(oldstate['disabled'].keys())

for appid in newdisabled:
    if appid not in oldstate['enabled'] and \
       appid not in oldstate['disabled']:
        continue
    subprocess.check_call(occ_cmd + ['app:disable', appid])
