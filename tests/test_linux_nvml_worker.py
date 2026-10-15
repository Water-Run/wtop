#!/usr/bin/env python3
"""Use real exec/IPC processes with normal, hanging and crashing NVML DSOs."""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def tui_hang(lua: Path, env: dict[str, str]) -> None:
    # The script gates each key on the current screen, so a stream of redraws
    # cannot pass as responsive navigation while the driver is stuck.
    os.environ.update(env)
    os.environ.update(WTOP_ROOT=str(ROOT), WTOP_LUA=str(lua/'bin/lua'),
                      WTOP_NVML_FIXTURE_MODE='45')
    sys.path.insert(0,str(ROOT/'tests'))
    import pty_smoke as pty
    original=pty._markers_visible
    def all_visible(markers, output, columns, rows):
        if markers is None:return True
        screen=pty.VirtualScreen(columns,rows);screen.feed(bytes(output))
        return all(marker in screen.text() for marker in markers)
    pty._markers_visible=all_visible
    try:
        pty.run_session(120,40,exercise=False,cli_options=('--lang','en-US','--no-color'),script=[
            (('sleep',0.4),('CPU','Memory')),(b'2',('CPU','Memory')),
            (b'9',('PID','Command')),(b'7',('Host','Kernel')),(b'p',None),
            (b'\x1b',('Power and limits','configured cap')),(b'1',None),
            (b'q',('CPU','Memory')),
        ])
    finally:pty._markers_visible=original
    print('ok: hung NVML constructor leaves overview/process/system/GPU/power navigation and quit responsive')

def main() -> None:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cc',default=os.environ.get('CC','cc'))
    p.add_argument('--cflags',default='-std=c17 -O2 -g -Wall -Wextra -Werror')
    p.add_argument('--module',type=Path,default=ROOT/'build/native/wtop_native.so')
    p.add_argument('--lua-prefix',type=Path,default=ROOT/'.tools/lua-5.5.1')
    p.add_argument('--output',type=Path,default=ROOT/'build/native-nvml-worker')
    p.add_argument('--native-only',action='store_true',help='native sanitizer harness; no uninstrumented Lua child')
    args=p.parse_args();cc=shlex.split(args.cc);flags=shlex.split(args.cflags)
    work=args.output.resolve();work.mkdir(parents=True,exist_ok=True);lua=args.lua_prefix.resolve()
    subprocess.run(cc+flags+['-fPIC','-shared','-DWTOP_NVML_VARIANT=0',str(ROOT/'tests/native/nvml_fake.c'),'-o',str(work/'libnvidia-ml.so.1')],check=True)
    fixture=work/'worker-fixture'
    subprocess.run(cc+flags+['-I'+str(lua/'include'),str(ROOT/'tests/native/linux_nvml_worker.c'),'-Wl,-E,--whole-archive',str(lua/'lib/liblua.a'),'-Wl,--no-whole-archive','-lm','-ldl','-pthread','-o',str(fixture)],check=True)
    env={**os.environ,'LD_LIBRARY_PATH':str(work)+os.pathsep+os.environ.get('LD_LIBRARY_PATH',''),
         'LUA_PATH':str(ROOT/'src/?.lua')+';'+str(ROOT/'src/?/init.lua')+';;',
         'LUA_CPATH':str(args.module.resolve().parent/'?.so')+';;'}
    subprocess.run([str(fixture),str(args.module.resolve())],env=env,check=True,timeout=90)
    subprocess.run([str(fixture),str(args.module.resolve()),'--legacy-syscalls'],env=env,check=True,timeout=90)
    for mode in ([] if args.native_only else [0,45,46,47,48,49,50,51,52,56,57,58]):
        run_env={**env,'WTOP_NVML_FIXTURE_MODE':str(mode)}
        with tempfile.TemporaryFile() as private:
            private.write(b'parent-only test descriptor');private.flush()
            os.dup2(private.fileno(),20,inheritable=True)
            run_env['WTOP_NVML_TEST_FD_INO']=str(os.fstat(20).st_ino)
            try:
                subprocess.run([str(lua/'bin/lua'),str(ROOT/'tests/native/nvml_worker_smoke.lua'),str(mode)],cwd=ROOT,env=run_env,pass_fds=(20,),check=True,timeout=8)
            finally:os.close(20)
    if not args.native_only:tui_hang(lua,env)
    print('ok: isolated NVML process transport, persistent cursors, Lua OOM, hang/crash/noise and lifecycle')

if __name__=='__main__':main()
