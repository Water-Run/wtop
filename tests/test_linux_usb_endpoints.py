#!/usr/bin/env python3
"""Read-only cached USB attributes: coherent identities, faults, budgets and OOM."""
import argparse
import os
import shlex
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fixture(root, scenario):
    # Keep the UTF-8 path test usable with Python 3.6's ASCII filesystem locale.
    interface = root / os.fsdecode('接口-3-1:1.0'.encode('utf-8'))
    interface.mkdir()
    fields = {'bInterfaceNumber': '00', 'bAlternateSetting': '00', 'bNumEndpoints': '03',
              'bInterfaceClass': '03', 'bInterfaceSubClass': '01', 'bInterfaceProtocol': '02',
              'interface': 'Cached interface'}
    for name, value in fields.items():
        (interface/name).write_text(value+'\n', encoding='utf-8')
    for name, attributes, interval in [('ep_01', '00', '0ms'), ('ep_02', '02', '0ms'), ('ep_81', '03', '125us')]:
        ep = interface/name
        ep.mkdir()
        fields = {'bLength':'07','bEndpointAddress':name[3:], 'bmAttributes':attributes,
                  'wMaxPacketSize':'0040','bInterval':'01','interval':interval}
        for key, value in fields.items():
            (ep/key).write_text(value+'\n', encoding='ascii')
    if scenario == 'scan-limit':
        for index in range(140): (interface/('unused-%d'%index)).write_text('')
    if scenario == 'malformed-name': (interface/'ep_ff').mkdir()
    if scenario == 'endpoint-symlink':
        (interface/'ep_02').rename(interface/'outside')
        (interface/'ep_02').symlink_to('outside', target_is_directory=True)
    if scenario in ('attribute-symlink', 'attribute-fifo'):
        field = interface/'ep_81/bInterval'
        field.unlink()
        if scenario == 'attribute-fifo': os.mkfifo(str(field))
        else: field.symlink_to('/dev/zero')
    if scenario == 'oversized-field': (interface/'ep_81/bInterval').write_bytes(b'1'*33)
    if scenario in ('source-symlink','source-symlink-retarget','oom'):
        (interface/'driver').symlink_to('../../drivers/usbhid',target_is_directory=True)
        alias=root/'interface-link';alias.symlink_to(interface.name,target_is_directory=True);interface=alias
    return interface


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cc', default=os.environ.get('CC','cc'))
    parser.add_argument('--cflags', default='-std=c17 -O2 -Wall -Wextra -Werror')
    parser.add_argument('--lua-prefix', type=Path, default=ROOT/'.tools/lua-5.5.1')
    parser.add_argument('--output', type=Path, default=ROOT/'build/native-usb-endpoints')
    args = parser.parse_args()
    work = args.output.resolve();work.mkdir(parents=True,exist_ok=True)
    binary = work/'usb-endpoint-fixture'
    subprocess.run(shlex.split(args.cc)+shlex.split(args.cflags)+[
        '-I'+str(args.lua_prefix.resolve()/'include'), str(ROOT/'tests/native/linux_usb_endpoints.c'),
        str(args.lua_prefix.resolve()/'lib/liblua.a'), '-lm','-ldl','-o',str(binary)], check=True)
    cases = [('normal',30),('normal',2),('normal',0),('short-read',30),
             ('field-denied',30),('open-denied',30),('directory-memory',30),('directory-error',30),
             ('interrupt-storm',30),('scan-limit',30),('malformed-name',30),('endpoint-symlink',30),
             ('attribute-symlink',30),('attribute-fifo',30),('oversized-field',30),
             ('alternate-change',30),('class-change',30),('field-change',30),('endpoint-replace',30),
             ('alternate-aba',30),('interface-replace',30),('endpoint-remove',30),('endpoint-add',30),
             ('attribute-replace',30),('fd-limit',30),('source-symlink',30),('source-symlink-retarget',30),('oom',30),
             ('argument-limit-low',-1),('argument-limit-high',31),('argument-nul',30),
             ('argument-type',30),('argument-relative',30),('argument-fraction',30),('argument-boolean',30)]
    for scenario, limit in cases:
        with tempfile.TemporaryDirectory(prefix='usb-',dir=work) as temporary:
            interface = fixture(Path(temporary),scenario)
            subprocess.run([str(binary),str(interface),scenario,str(limit)],check=True,timeout=10,cwd=ROOT)
    print('USB native: %d cases passed; cached reads, path/endpoint/alternate races, symlinks/FIFO, partial reads, FD/OOM cleanup'%len(cases))


if __name__ == '__main__': main()
