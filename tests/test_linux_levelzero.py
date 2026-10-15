#!/usr/bin/env python3
"""Exercise actual Sysman signatures, full structures and energy/cap semantics.

--sdk-root additionally checks the fixtures against hash-pinned, unmodified
upstream headers. The normal offline gate uses independent declaration excerpts.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cc',default=os.environ.get('CC','cc'))
    p.add_argument('--cflags',default='-O1 -g -std=c17 -Wall -Wextra -Werror')
    p.add_argument('--lua-prefix',type=Path,default=ROOT/'.tools/lua-5.5.1')
    p.add_argument('--output',type=Path,default=ROOT/'build/native-levelzero')
    p.add_argument('--sdk-root',type=Path)
    args=p.parse_args();cc=shlex.split(args.cc);flags=shlex.split(args.cflags)
    work=args.output.resolve();work.mkdir(parents=True,exist_ok=True);lua=args.lua_prefix.resolve()
    versions=json.loads((ROOT/'tests/fixtures/levelzero/versions.json').read_text())
    fixture=work/'fixture'
    subprocess.run(cc+flags+['-I'+str(lua/'include'),str(ROOT/'tests/native/linux_levelzero.c'),
                   str(lua/'lib/liblua.a'),'-ldl','-lm','-o',str(fixture)],check=True)
    for tag in sorted({v['tag'] for v in versions}):
        legacy=tag=='v1.5.0';directory=work/tag;directory.mkdir(exist_ok=True)
        definitions=['-DWTOP_LEVELZERO_LEGACY'] if legacy else []
        if args.sdk_root:
            for item in versions:
                if item['tag']==tag:
                    path=args.sdk_root/tag/item['file']
                    assert hashlib.sha256(path.read_bytes()).hexdigest()==item['sha256'],path
            definitions+=['-DWTOP_LEVELZERO_SDK_HEADER="'+str((args.sdk_root/tag/'zes_api.h').resolve())+'"']
        subprocess.run(cc+flags+['-fPIC','-shared']+definitions+[
                       str(ROOT/'tests/native/levelzero_fake.c'),str(ROOT/'tests/native/levelzero_layout.c'),
                       '-o',str(directory/'libze_loader.so.1')],check=True)
        env={**os.environ,'LD_LIBRARY_PATH':str(directory)+os.pathsep+os.environ.get('LD_LIBRARY_PATH',''),
             'ASAN_OPTIONS':os.environ.get('ASAN_OPTIONS','')+':detect_leaks=1:halt_on_error=1',
             'UBSAN_OPTIONS':os.environ.get('UBSAN_OPTIONS','')+':halt_on_error=1',
             'WTOP_LEVELZERO_FIXTURE_MODE':'0'}
        if legacy:env['ZES_ENABLE_SYSMAN']='1'
        else:env.pop('ZES_ENABLE_SYSMAN',None)
        subprocess.run([str(fixture),'1' if legacy else '0'],env=env,check=True,timeout=45)
    print('ok: Level Zero SDK layouts, standalone and legacy ABI, domain identity, energy timing, cap units and OOM')

if __name__=='__main__':main()
