#!/usr/bin/env python3
"""Packs channeltest/app into FMTChannelTest.ipk (an LG webOS app), with Free My TV's packager (no LG tools needed).

    python3 channeltest/build.py      -> channeltest/FMTChannelTest.ipk
    python3 install_ipk.py channeltest/FMTChannelTest.ipk
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tv', 'webos'))
from build import ar, tar_gz  # noqa: E402

APP = os.path.join(HERE, 'app')
with open(os.path.join(APP, 'appinfo.json')) as f:
    info = json.load(f)
app_id, version = info['id'], info['version']

base = 'usr/palm/applications/' + app_id
entries = [('usr', None), ('usr/palm', None), ('usr/palm/applications', None), (base, None)]
size = 0
for name in sorted(os.listdir(APP)):
    with open(os.path.join(APP, name), 'rb') as f:
        data = f.read()
    entries.append((base + '/' + name, data))
    size += len(data)
package = json.dumps({'id': app_id, 'version': version, 'app': app_id}, indent=2).encode('utf-8')
entries += [('usr/palm/packages', None), ('usr/palm/packages/' + app_id, None),
            ('usr/palm/packages/' + app_id + '/packageinfo.json', package)]
control = ('Package: %s\nVersion: %s\nSection: misc\nPriority: optional\nArchitecture: all\nInstalled-Size: %d\n'
           'Maintainer: Free My TV\nDescription: Phone-to-TV channel test.\n'
           'webOS-Package-Format-Version: 2\nwebOS-Packager-Version: 1.0.0\n' % (app_id, version, size + len(package)))
out = os.path.join(HERE, 'FMTChannelTest.ipk')
with open(out, 'wb') as f:
    f.write(ar([('debian-binary', b'2.0\n'), ('control.tar.gz', tar_gz([('control', control.encode('utf-8'))])),
                ('data.tar.gz', tar_gz(entries))]))
print('Built %s (%s %s, %d KB)' % (out, app_id, version, os.path.getsize(out) // 1024))
