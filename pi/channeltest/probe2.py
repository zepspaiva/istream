#!/usr/bin/env python3
"""Copies, read only, the TV's second-screen gateway and API adapter (JavaScript services) and their permission files
to channeltest/gateway.tgz, to read how app-to-app channels work. Nothing on the TV changes.

    python3 channeltest/probe2.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tv', 'webos'))
import install  # noqa: E402

TV_IP = '192.168.1.34'
CMD = ('cd / && tar czf - '
       'usr/palm/services/com.webos.service.secondscreen.gateway '
       'usr/palm/services/com.webos.service.apiadapter '
       'usr/share/luna-service2/api-permissions.d/com.webos.service.secondscreen.gateway.api.json '
       'usr/share/luna-service2/groups.d '
       '2>/dev/null')


def main():
    key = install.fetch_key(TV_IP)
    args = ['ssh'] + install.SSH_OPTS + ['-i', key, 'prisoner@' + TV_IP, CMD]
    res = subprocess.run(args, capture_output=True)
    path = os.path.join(HERE, 'gateway.tgz')
    with open(path, 'wb') as f:
        f.write(res.stdout)
    print('Wrote %s (%d KB)%s' % (path, len(res.stdout) // 1024, ('; ' + res.stderr.decode('utf-8', 'replace')[:300]) if res.stderr else ''))


if __name__ == '__main__':
    main()
