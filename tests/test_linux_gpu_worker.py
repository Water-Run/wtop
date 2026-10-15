#!/usr/bin/env python3
"""Mixed GPU SDK isolation, independent quotas, Lua OOM and real driver faults."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cc',default=os.environ.get('CC','cc'))
    p.add_argument('--cflags',default='-std=c17 -O1 -g -Wall -Wextra -Werror')
    p.add_argument('--lua-prefix',type=Path,default=ROOT/'.tools/lua-5.5.1')
    p.add_argument('--module',type=Path,default=ROOT/'build/native/wtop_native.so')
    p.add_argument('--output',type=Path,default=ROOT/'build/native-gpu-worker')
    p.add_argument('--native-only',action='store_true')
    args=p.parse_args();cc=shlex.split(args.cc);flags=shlex.split(args.cflags)
    work=args.output.resolve();work.mkdir(parents=True,exist_ok=True);lua=args.lua_prefix.resolve()
    for sources,definitions,name in [
        (['nvml_fake.c'],['-DWTOP_NVML_VARIANT=0'],'libnvidia-ml.so.1'),
        (['amdsmi_fake.c','amdsmi_layout.c'],['-DWTOP_AMDSMI_PROFILE=262','-DWTOP_AMDSMI_VERSION_RELEASE=2'],'libamd_smi.so'),
        (['levelzero_fake.c','levelzero_layout.c'],[],'libze_loader.so.1'),
    ]:
        subprocess.run(cc+flags+['-fPIC','-shared']+definitions+[
                       str(ROOT/'tests/native'/source) for source in sources]+['-o',str(work/name)],check=True)
    fixture=work/'fixture'
    subprocess.run(cc+flags+['-I'+str(lua/'include'),str(ROOT/'tests/native/linux_gpu_worker.c'),
                   '-Wl,-E,--whole-archive',str(lua/'lib/liblua.a'),'-Wl,--no-whole-archive',
                   '-ldl','-lm','-pthread','-o',str(fixture)],check=True)
    env={**os.environ,'LD_LIBRARY_PATH':str(work)+os.pathsep+os.environ.get('LD_LIBRARY_PATH',''),
         'LUA_PATH':str(ROOT/'src/?.lua')+';'+str(ROOT/'src/?/init.lua')+';;',
         'LUA_CPATH':str(args.module.resolve().parent/'?.so')+';;',
         'WTOP_NVML_FIXTURE_MODE':'0','WTOP_AMDSMI_FIXTURE_MODE':'0','WTOP_LEVELZERO_FIXTURE_MODE':'0'}
    subprocess.run([str(fixture),str(args.module.resolve())],env=env,check=True,timeout=150)
    if not args.native_only:
        command=[str(lua/'bin/lua'),str(ROOT/'src/wtop.lua'),'--snapshot']
        result=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,check=True,timeout=20)
        data=json.loads(result.stdout)
        assert b'worker_pid' not in result.stdout and b'PRIVATE-' not in result.stdout
        for source in ['nvml','amdsmi','levelzero']:
            assert data['gpus']['providers'][source]['transport']=='process',source
        cards=[d for d in data['gpus']['devices'] if d.get('model_name','').startswith('SDK GPU ')]
        assert len(cards)==3 and {d['metrics']['power_limit_percent'] for d in cards}=={75,100,125}
        print('ok: three SDKs in real Snapshot, counter warmup, 75/100/125% configured-cap comparisons and private outputs')
        sys.path.insert(0,str(ROOT/'tests'))
        from test_linux_nvml_worker import tui_hang
        for source in ['amdsmi','levelzero']:
            tui_hang(lua,env,source)
    print('ok: independent GPU SDK readers and mixed-vendor fault isolation')

if __name__=='__main__':main()
