#!/usr/bin/env python3
"""Installs any webOS app package (.ipk) on the LG TV through Developer Mode, the way Free My TV is installed.

    python3 install_ipk.py NuvioTV-webOS-1.2.10.ipk            # TV at 192.168.1.34
    python3 install_ipk.py NuvioTV-webOS-1.2.10.ipk 192.168.1.34
    python3 install_ipk.py --uninstall space.nuvio.webos

Reuses Free My TV's installer (../tv/webos/install.py) and its saved Developer Mode key, so no passphrase
is asked when Free My TV was installed from this Mac.
"""
import io
import json
import os
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tv', 'webos'))
import build    # noqa: E402
import install  # noqa: E402

TV_IP = '192.168.1.34'


def app_id_of(package):
    for name, part in build.ar_members(package):
        if name.startswith('data.tar'):
            with tarfile.open(fileobj=io.BytesIO(part)) as tar:
                for member in tar.getmembers():
                    if build._is_appinfo(member.name):
                        return json.loads(tar.extractfile(member).read().decode('utf-8'))['id']
    sys.exit('No appinfo.json in that package.')


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    ip = next((a for a in args if a.count('.') == 3 and a.replace('.', '').isdigit()), TV_IP)
    args = [a for a in args if a != ip]
    if not args:
        sys.exit(__doc__)
    key = install.fetch_key(ip)

    if '--uninstall' in sys.argv:
        out = install.luna(ip, key, 'luna://com.webos.appInstallService/dev/remove', {'id': args[0]}, replies=3, wait=30)
        print('Removed.' if '"returnValue":true' in out else 'The TV said: ' + out.strip())
        return

    with open(args[0], 'rb') as f:
        package = f.read()
    app_id = app_id_of(package)
    temp = '/media/developer/temp/%s.ipk' % app_id
    print('Copying %s (%d MB) to the TV ...' % (app_id, len(package) // 1_000_000))
    copy = install.ssh(ip, key, 'mkdir -p /media/developer/temp && cat > ' + temp, data=package)
    if copy.returncode != 0:
        err = copy.stderr.decode('utf-8', 'replace') if isinstance(copy.stderr, bytes) else copy.stderr
        sys.exit("Couldn't copy it: %s\nIs Developer Mode still on?" % err.strip())
    print('Installing ...')
    out = install.luna(ip, key, 'luna://com.webos.appInstallService/dev/install',
                       {'id': app_id, 'ipkUrl': temp, 'subscribe': True}, replies=30, wait=120)
    if '"state":"installed"' not in out:
        sys.exit("The TV didn't finish installing. It said:\n" + out.strip())
    install.ssh(ip, key, 'rm -f ' + temp)
    install.luna(ip, key, 'luna://com.webos.applicationManager/launch', {'id': app_id})
    print('Installed and open on the TV: %s' % app_id)


if __name__ == '__main__':
    main()
