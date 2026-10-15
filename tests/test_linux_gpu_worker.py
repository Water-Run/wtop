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
import tempfile

ROOT=Path(__file__).resolve().parents[1]

def tui_continuity(lua: Path, env: dict[str,str], source: str, baseline: dict, output: Path) -> None:
    previous_environment=os.environ.copy()
    os.environ.update(env)
    os.environ.update(WTOP_ROOT=str(ROOT),WTOP_LUA=str(lua/'bin/lua'))
    candidates={}
    for device in baseline['gpus']['devices']:
        vendor=device.get('metrics',{}).get('power_source')
        if vendor in ['nvml','amdsmi','levelzero'] and vendor not in candidates:
            candidates[vendor]=device
    assert len(candidates)==3
    card=candidates[source]['card']
    sys.path.insert(0,str(ROOT/'tests'))
    import pty_smoke as pty
    original=pty._markers_visible
    captured={}
    with tempfile.TemporaryDirectory(prefix='gpu-pty-continuity-',dir=output) as temporary:
        control=Path(temporary)/'control';control.write_text('0\n')
        os.environ['WTOP_'+source.upper()+'_FIXTURE_CONTROL']=str(control)
        armed=False
        def visible(markers, data, columns, rows):
            nonlocal armed
            if not markers:return True
            screen=pty.VirtualScreen(columns,rows);screen.feed(bytes(data));text=screen.text()
            if markers==('continuity-ready',):
                lines=[line for line in text.splitlines() if card in line]
                watts=f"{candidates[source]['metrics']['power_watts']:.1f} W"
                if not any(watts in line and 'Stale' not in line for line in lines):return False
                if not armed:
                    control.write_text({'nvml':'47\n','amdsmi':'41\n','levelzero':'42\n'}[source]);armed=True
                return True
            if markers==('continuity-stale',):
                if not any(card in line and 'Stale' in line for line in text.splitlines()):return False
                for vendor,device in candidates.items():
                    if vendor!=source and not any(device['card'] in line and 'Stale' not in line
                                                 for line in text.splitlines()):return False
                captured['stale']=text
                return True
            return all(marker in text for marker in markers)
        pty._markers_visible=visible
        try:
            data=pty.run_session(240,60,exercise=False,cli_options=('--lang','en-US','--no-color'),script=[
                (b'7',('CPU','Memory')),(('sleep',0.2),('continuity-ready',)),
                (('sleep',2.5),('continuity-stale',)),(b'p',('continuity-stale',)),
                (b'\x1b',('Power and limits',)),(b'2',None),(b'9',('PID','Command')),
                (b'q',('Host','Kernel'))])
            assert armed and 'stale' in captured
            for suffix,content in [('pty',data),('txt',captured['stale'].encode())]:
                path=output/(source+'-warmed-stale.'+suffix);path.write_bytes(content);path.chmod(0o600)
        finally:
            pty._markers_visible=original
            os.environ.clear();os.environ.update(previous_environment)
    print('ok: '+source+' warmed then hung: stale GPU stays visible, other vendors fresh, power/process/system/quit responsive',flush=True)

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
        for source in ['nvml','amdsmi','levelzero']:
            with tempfile.TemporaryDirectory(prefix='gpu-continuity-',dir=work) as temporary:
                control=Path(temporary)/'control';control.write_text('0\n')
                live_env={**env,'WTOP_'+source.upper()+'_FIXTURE_CONTROL':str(control)}
                subprocess.run([str(lua/'bin/lua'),str(ROOT/'tests/native/gpu_continuity_smoke.lua'),
                                source,str(control)],cwd=ROOT,env=live_env,check=True,timeout=25)
            tui_continuity(lua,env,source,data,work)
        sys.path.insert(0,str(ROOT/'tests'))
        from test_linux_nvml_worker import tui_hang
        for source in ['amdsmi','levelzero']:
            tui_hang(lua,env,source)
    print('ok: independent GPU SDK readers and mixed-vendor fault isolation')

if __name__=='__main__':main()
