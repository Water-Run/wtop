#!/usr/bin/env python3
"""Exercise the actual macOS process transport without requiring GPU/energy hardware."""
from pathlib import Path
import ctypes,json,os,select,signal,subprocess,sys,time

ROOT=Path(__file__).resolve().parents[1]
def main():
    if sys.platform!="darwin":
        raise SystemExit("macOS reader test requires macOS")
    os.umask(0o077)
    work=ROOT/'build/macos-worker-test';work.mkdir(parents=True,exist_ok=True)
    lua=ROOT/'.tools/lua-5.5.1/bin/lua'
    env={**os.environ,'LUA_CPATH':str(ROOT/'dist/macos/?.so')+';;'}
    library=ctypes.CDLL('/usr/lib/libproc.dylib')
    library.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
    images={};readers=set()

    def path_for(pid):
        buffer=ctypes.create_string_buffer(4096)
        assert library.proc_pidpath(pid,buffer,len(buffer))>0
        path=Path(os.fsdecode(buffer.value));metadata=path.stat()
        assert path.name.startswith('wtop-hardware-') and metadata.st_uid==os.geteuid()
        assert metadata.st_mode&0o777==0o500
        images[path]=(metadata.st_dev,metadata.st_ino);readers.add(pid)
        return path

    def gone(pid):
        deadline=time.monotonic()+2
        while time.monotonic()<deadline:
            try:os.kill(pid,0)
            except ProcessLookupError:return
            time.sleep(.01)
        raise AssertionError('owned reader was not reaped: '+str(pid))

    for suspended in ['powercap','hwmon']:
        with (work/('transport-'+suspended+'.stderr')).open('wb') as error_log:
            parent=subprocess.Popen([str(lua),str(ROOT/'tests/native/macos_worker_smoke.lua'),str(ROOT),suspended],
                cwd=ROOT,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=error_log,text=True,bufsize=1)
            def event(expected):
                ready,_,_=select.select([parent.stdout],[],[],20)
                assert ready,'reader test event timed out: '+expected
                text=parent.stdout.readline();assert text,'reader test exited before '+expected
                value=json.loads(text);assert value['event']==expected,value
                return value
            try:
                initial=event('ready')['pids'];assert len(set(initial.values()))==4
                for pid in initial.values():path_for(pid)
                stopped=initial[suspended];os.kill(stopped,signal.SIGSTOP)
                parent.stdin.write('stopped\n');parent.stdin.flush()
                assert event('timeout')['source']==suspended;gone(stopped)
                parent.stdin.write('recover\n');parent.stdin.flush()
                recovered=event('recovered')['pids'];assert recovered[suspended]!=stopped
                path_for(recovered[suspended])
                parent.stdin.write('close\n');parent.stdin.flush()
                assert parent.wait(timeout=4)==0
            finally:
                if parent.poll()is None:parent.kill();parent.wait(timeout=3)
    for pid in readers:gone(pid)
    for path,identity in images.items():
        assert not path.exists()or (path.stat().st_dev,path.stat().st_ino)!=identity,'reader image leaked: '+str(path)
    for iteration in range(3):
        with (work/('shutdown-'+str(iteration)+'.stderr')).open('wb') as log:
            process=subprocess.Popen([str(lua),str(ROOT/'tests/native/hardware_worker_shutdown.lua'),str(ROOT),'hold'],
                cwd=ROOT,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True)
            try:
                ready,_,_=select.select([process.stdout],[],[],3);assert ready
                assert int(process.stdout.readline())==process.pid
                deadline=time.monotonic()+2;owned=[]
                while time.monotonic()<deadline:
                    result=subprocess.run(['/bin/ps','-axo','pid=,ppid=,comm='],capture_output=True,text=True,check=True)
                    owned=[]
                    for line in result.stdout.splitlines():
                        columns=line.split(None,2)
                        if len(columns)==3 and columns[1]==str(process.pid) and 'wtop-hardware-' in columns[2]:owned.append(int(columns[0]))
                    if len(owned)==4:break
                    time.sleep(.01)
                assert len(owned)==4,'shutdown fixture did not start all four readers'
                vm_images=[path_for(pid) for pid in owned]
                process.stdin.write('close\n');process.stdin.flush();assert process.wait(timeout=3)==0
                for pid in owned:gone(pid)
                for path in vm_images:assert not path.exists(),'VM shutdown leaked its reader image'
            finally:
                if process.poll()is None:process.kill();process.wait(timeout=3)
    print('ok: macOS four independent readers, monotonic frames, power/sensor timeout/reap, independent recovery, malformed config, private-image cleanup and three standalone VM exits')


if __name__=="__main__":
    main()
