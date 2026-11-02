#!/usr/bin/env python3
"""Looks up, on the TV (Developer Mode's shell, read only), how LG's second-screen gateway passes messages between a
phone and a TV app: its methods and permissions. Writes what it finds to channeltest/probe.txt.

    python3 channeltest/probe.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tv', 'webos'))
import install  # noqa: E402

TV_IP = '192.168.1.34'

COMMANDS = [
    ('who am I', 'id; uname -a; cat /var/run/nyx/os_info.json 2>/dev/null | head -c 600'),
    ('luna-service2 config dirs', 'ls -d /usr/share/luna-service2/*.d /etc/luna-service2/*.d 2>/dev/null'),
    ('files that mention secondscreen',
     'grep -ril "secondscreen" /usr/share/luna-service2 /etc/luna-service2 /usr/share/dbus-1 2>/dev/null | head -40'),
    ('their contents', 'for f in $(grep -ril "secondscreen" /usr/share/luna-service2 /etc/luna-service2 2>/dev/null | head -12); '
                       'do echo "== $f"; head -c 3000 "$f"; echo; done'),
    ('gateway program', 'ls -la /usr/sbin /usr/bin 2>/dev/null | grep -i -E "second|ssap|gateway" | head'),
    ('strings: methods and keys', 'B=$(ls /usr/sbin/*second* /usr/bin/*second* 2>/dev/null | head -1); echo "binary: $B"; '
                                   '[ -n "$B" ] && strings "$B" | grep -E "^/?(app|webapp)|webAppId|p2p|connectToApp|joinWebApp|'
                                   'launchWebApp|clientKey|appSubscribe|onMessage|sendMessage|appId" | sort -u | head -120'),
    ('web app manager mentions', 'grep -rl -i "p2p\\|connectToApp" /usr/lib/*.so* /usr/sbin 2>/dev/null | head -10'),
]


def main():
    key = install.fetch_key(TV_IP)
    out = []
    for title, cmd in COMMANDS:
        res = install.ssh(TV_IP, key, cmd)
        text = (res.stdout or '') + (('\n[stderr] ' + res.stderr) if res.stderr else '')
        out.append('##### %s\n$ %s\n%s\n' % (title, cmd, text.strip()))
        print('done:', title)
    path = os.path.join(HERE, 'probe.txt')
    with open(path, 'w') as f:
        f.write('\n'.join(out))
    print('Wrote', path)


if __name__ == '__main__':
    main()
