#!/usr/bin/env python3
"""Isolated DRM driver reads, dynamic fdinfo policy and warmed fault recovery."""
import argparse,os,shlex,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def fixture(directory):
    drm=directory/'drm';card=drm/'card0';card.mkdir(parents=True)
    device=directory/'devices/0000:01:00.0';device.mkdir(parents=True)
    (card/'device').symlink_to('../../devices/0000:01:00.0',target_is_directory=True)
    (device/'driver').symlink_to('../drivers/amdgpu',target_is_directory=True)
    for path,text in {'vendor':'0x1002\n','device':'0x744c\n','subsystem_vendor':'0x1002\n',
                      'subsystem_device':'0x0e3b\n','revision':'0xc8\n','class':'0x030000\n',
                      'gpu_busy_percent':'73\n','pp_dpm_sclk':'0: 1500Mhz *\n'}.items():
        (device/path).write_text(text)
    (card/'dev').write_text('226:0\n');(card/'uevent').write_text('MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\n')
    proc=directory/'proc';pid=proc/'100';(pid/'fdinfo').mkdir(parents=True)
    fields=['0']*40;fields[0:3]=['1','100','100'];fields[16]='1';fields[18]='1000'
    (pid/'stat').write_text('100 (render-worker) R '+' '.join(fields)+'\n')
    (pid/'status').write_text('Name:\trender-worker\nUid:\t1000\t1000\t1000\t1000\n')
    fdinfo=pid/'fdinfo/3'
    fdinfo.write_text('drm-driver: amdgpu\ndrm-client-id: 7\ndrm-pdev: 0000:01:00.0\ndrm-engine-gfx: 100000000 ns\n')
    return drm,proc,fdinfo

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cc',default=os.environ.get('CC','cc'))
    p.add_argument('--cflags',default='-std=c17 -O2 -Wall -Wextra -Werror')
    p.add_argument('--lua-prefix',type=Path,default=ROOT/'.tools/lua-5.5.1')
    p.add_argument('--module',type=Path,default=ROOT/'build/native/wtop_native.so')
    p.add_argument('--output',type=Path,default=ROOT/'build/native-drm-worker')
    p.add_argument('--native-only',action='store_true')
    args=p.parse_args();work=args.output.resolve();work.mkdir(parents=True,exist_ok=True)
    library=work/'drm_io_fake.so'
    subprocess.run(shlex.split(args.cc)+shlex.split(args.cflags)+['-fPIC','-shared',str(ROOT/'tests/native/hardware_io_fake.c'),'-ldl','-o',str(library)],check=True)
    with tempfile.TemporaryDirectory(prefix='drm-reader-',dir=work) as temporary:
        directory=Path(temporary);drm,proc,fdinfo=fixture(directory)
        control=directory/'control';control.write_text('0\n');entered=directory/'entered'
        env={**os.environ,'LD_PRELOAD':(os.environ['LD_PRELOAD']+':' if os.environ.get('LD_PRELOAD') else '')+str(library),
             'LUA_PATH':str(ROOT/'src/?.lua')+';'+str(ROOT/'src/?/init.lua')+';;',
             'LUA_CPATH':str(args.module.resolve().parent/'?.so')+';;',
             'WTOP_DRM_FIXTURE_ROOT':str(drm),'WTOP_GPU_PROC_FIXTURE_ROOT':str(proc),
             'WTOP_DRM_FIXTURE_CONTROL':str(control),'WTOP_DRM_FIXTURE_ENTERED':str(entered)}
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/gpu_drm_worker_smoke.lua'),
                        str(ROOT),str(control),str(entered),str(fdinfo)],cwd=ROOT,env=env,check=True,timeout=25)
        if not args.native_only:
            control.write_text('0\n');entered.unlink(missing_ok=True)
            previous=os.environ.copy();os.environ.update(env)
            os.environ.update(WTOP_ROOT=str(ROOT),WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
            sys.path.insert(0,str(ROOT/'tests'))
            import pty_smoke as pty
            original=pty._markers_visible;armed=False;captured={}
            def visible(markers,data,columns,rows):
                nonlocal armed
                if not markers:return True
                screen=pty.VirtualScreen(columns,rows);screen.feed(bytes(data));text=screen.text()
                captured['last']=text
                if markers==('drm-ready',):
                    if not any('card0' in line and '73' in line and 'Stale' not in line for line in text.splitlines()):return False
                    if not armed:control.write_text('1\n');armed=True
                    return True
                if markers==('drm-stale',):
                    if not entered.exists() or not any('card0' in line and 'Stale' in line for line in text.splitlines()):return False
                    captured['stale']=text;return True
                return all(marker in text for marker in markers)
            pty._markers_visible=visible
            try:
                data=pty.run_session(240,60,exercise=False,cli_options=('--lang','en-US','--no-color','--interval','100'),
                    script=[(b'7',('CPU','Memory')),(('sleep',1.0),('drm-ready',)),
                            (('sleep',0.2),('drm-stale',)),(b'2',None),(b'9',('PID','Command')),
                            (b'q',('Host','Kernel'))])
                assert armed and 'stale' in captured
                for suffix,content in [('pty',data),('txt',captured['stale'].encode())]:
                    path=work/('warmed-drm-stale.'+suffix);path.write_bytes(content);path.chmod(0o600)
            finally:
                last=work/'drm-last-screen.txt';last.write_text(captured.get('last',''));last.chmod(0o600)
                pty._markers_visible=original;os.environ.clear();os.environ.update(previous)
            print('ok: real TUI warmed blocked DRM: retained stale GPU, process/system navigation and quit responsive',flush=True)

if __name__=='__main__':main()
