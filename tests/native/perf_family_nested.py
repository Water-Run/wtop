from pathlib import Path
import json,os,subprocess,sys,time
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
import perf_process_family as family
w=Path(sys.argv[1])
busy="import time; memory=bytearray(16*1024*1024);print('ready',flush=True);end=time.monotonic()+10\nwhile time.monotonic()<end:pass"
controller="""import subprocess,sys,json
child=subprocess.Popen([sys.executable,'-c',BUSY],stdout=subprocess.PIPE,universal_newlines=True)
assert child.stdout.readline().strip()=='ready'
print(json.dumps({'grandchild':child.pid}),flush=True)
assert sys.stdin.readline().strip()=='reapgrandchild'
child.terminate();child.wait(timeout=3);print('grandchildreaped',flush=True)
assert sys.stdin.readline().strip()=='quit'
""".replace('BUSY',repr(busy))
root="""import subprocess,sys,threading,json
ready=threading.Event();done=threading.Event();state={}
def spawn():
 state['child']=subprocess.Popen([sys.executable,'-c',CONTROLLER],stdin=subprocess.PIPE,stdout=subprocess.PIPE,universal_newlines=True)
 state['metadata']=json.loads(state['child'].stdout.readline());ready.set();done.wait();state['child'].wait(timeout=3)
thread=threading.Thread(target=spawn);thread.start();ready.wait(timeout=3)
child=state['child'];print(json.dumps({'child':child.pid,**state['metadata']}),flush=True)
assert sys.stdin.readline().strip()=='reapgrandchild'
child.stdin.write('reapgrandchild\\n');child.stdin.flush();assert child.stdout.readline().strip()=='grandchildreaped';print('grandchildreaped',flush=True)
assert sys.stdin.readline().strip()=='reapchild'
child.stdin.write('quit\\n');child.stdin.flush();done.set();thread.join(timeout=3);assert not thread.is_alive();print('childreaped',flush=True)
assert sys.stdin.readline().strip()=='quit'
""".replace('CONTROLLER',repr(controller))
p=subprocess.Popen([sys.executable,'-c',root],stdin=subprocess.PIPE,stdout=subprocess.PIPE,universal_newlines=True)
metadata={};descendant_births={}
try:
    metadata=json.loads(p.stdout.readline());birth=family.read_stat(p.pid)['birth']
    descendant_births={pid:family.read_stat(pid)['birth']for pid in metadata.values()}
    main_children=(Path('/proc')/str(p.pid)/'task'/str(p.pid)/'children').read_text().split()
    assert str(metadata['child'])not in main_children,'fixture failed to spawn from non-leader thread'
    before=family.snapshot(p.pid,birth);assert before['status']=='observed'and before['processes']==3,before
    time.sleep(.6)
    live=family.snapshot(p.pid,birth);assert live['status']=='observed'and live['family_ticks']>=before['family_ticks']+20,live
    p.stdin.write('reapgrandchild\n');p.stdin.flush();assert p.stdout.readline().strip()=='grandchildreaped'
    descendant_births.pop(metadata['grandchild'])
    middle=family.snapshot(p.pid,birth);assert middle['status']=='observed'and middle['processes']==2,middle
    p.stdin.write('reapchild\n');p.stdin.flush();assert p.stdout.readline().strip()=='childreaped'
    descendant_births.pop(metadata['child'])
    after=family.snapshot(p.pid,birth);assert after['status']=='observed'and after['processes']==1,after
    assert before['family_ticks']<=live['family_ticks']<=middle['family_ticks']<=after['family_ticks']
    assert after['family_ticks']-live['family_ticks']<10,'reaped grandchildren counted twice'
    replaced=family.snapshot(p.pid,birth+1);assert replaced['status']=='incomplete'and'family_ticks'not in replaced
    original=family.memory
    def denied(*args,**kwargs):raise PermissionError('fixture memory denied')
    family.memory=denied
    unavailable=family.snapshot(p.pid,birth);family.memory=original
    assert unavailable['status']=='partial'and unavailable['cpu_status']=='observed'and unavailable['memory_status']=='denied'and'pss_kib'not in unavailable
    result={'scope':'Private controlled prototype checks, not wtop performance acceptance',
            'non_leader_thread_spawn_verified':True,'samples':[before,live,middle,after],
            'PID_reuse_rejected':True,'denied_memory_not_zeroed':True}
    (w/'prototype-nested.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Prototype non-leader fork/nested CPU/reap transfers/no doublecount/PID reuse/denied memory checks passed')
finally:
    if p.poll()is None:
        try:p.stdin.write('quit\n');p.stdin.flush();p.wait(timeout=3)
        except Exception:p.kill();p.wait()
    for pid,birth in descendant_births.items():
        try:
            if family.read_stat(pid)['birth']==birth:os.kill(pid,15)
        except ProcessLookupError:pass
        except FileNotFoundError:pass
