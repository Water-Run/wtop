#!/usr/bin/env python3
"""Verify fixed nl80211 requests, malformed replies and isolated worker lifecycle."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cc', default=os.environ.get('CC', 'cc'))
    parser.add_argument('--cflags', default='-std=c17 -O2 -Wall -Wextra -Werror')
    parser.add_argument('--lua-prefix', type=Path, default=ROOT/'.tools/lua-5.5.1')
    parser.add_argument('--module', type=Path, default=ROOT/'build/native/wtop_native.so')
    parser.add_argument('--output', type=Path, default=ROOT/'build/native-wifi')
    args = parser.parse_args()
    work = args.output.resolve();work.mkdir(parents=True, exist_ok=True)
    flags = shlex.split(args.cc) + shlex.split(args.cflags)
    binary = work/'protocol-fixtures'
    subprocess.run(flags+['-I'+str(ROOT/'native'),str(ROOT/'tests/native/linux_wifi.c'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=10)
    library = work/'wifi-netlink-fake.so'
    subprocess.run(flags+['-shared','-fPIC','-I'+str(ROOT/'native'),str(ROOT/'tests/native/wifi_netlink_fake.c'),'-ldl','-o',str(library)],check=True)
    with tempfile.TemporaryDirectory(prefix='wifi-reader-',dir=work) as directory:
        stage=Path(directory);tree=stage/'net';device=tree/'wlan0';(device/'phy80211').mkdir(parents=True)
        (device/'ifindex').write_text('3\n');(device/'phy80211/index').write_text('0\n')
        control=stage/'control';control.write_text('0\n');entered=stage/'entered'
        env={**os.environ,'LUA_PATH':str(ROOT/'src/?.lua')+';'+str(ROOT/'src/?/init.lua')+';;',
             'LUA_CPATH':str(args.module.resolve().parent/'?.so')+';;',
             'LD_PRELOAD':(os.environ['LD_PRELOAD']+':' if os.environ.get('LD_PRELOAD') else '')+str(library),
             'WTOP_WIFI_FIXTURE':'1','WTOP_WIFI_CONTROL':str(control),'WTOP_WIFI_ENTERED':str(entered)}
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/wifi_worker_smoke.lua'),
                        str(ROOT),str(tree),str(control),str(entered)],env=env,cwd=ROOT,check=True,timeout=15)


if __name__=='__main__':
    main()
