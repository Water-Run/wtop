from pathlib import Path
import json,subprocess,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
import perf_process_family as family
w=Path(sys.argv[1])
program='''import os,mmap,sys,json
size=32*1024*1024
memory=mmap.mmap(-1,size,flags=mmap.MAP_SHARED)
for index in range(0,size,4096):memory[index]=1
control_read,control_write=os.pipe();ready_read,ready_write=os.pipe()
child=os.fork()
if child==0:
 os.close(control_write);os.close(ready_read)
 for index in range(0,size,4096):assert memory[index]==1
 os.write(ready_write,b'1');os.close(ready_write);os.read(control_read,1);os._exit(0)
os.close(control_read);os.close(ready_write);assert os.read(ready_read,1)==b'1';os.close(ready_read)
print(json.dumps({'child':child}),flush=True)
assert sys.stdin.readline().strip()=='reap';os.close(control_write);assert os.waitpid(child,0)[1]==0;print('reaped',flush=True)
assert sys.stdin.readline().strip()=='quit'
'''
p=subprocess.Popen([sys.executable,'-c',program],stdin=subprocess.PIPE,stdout=subprocess.PIPE,universal_newlines=True)
try:
    metadata=json.loads(p.stdout.readline());birth=family.read_stat(p.pid)['birth']
    shared=family.snapshot(p.pid,birth);assert shared['status']=='observed'and shared['processes']==2,shared
    assert shared['rss_sum_kib']-shared['pss_kib']>32768,shared
    assert shared['pss_kib']-shared['private_resident_kib']>30000,shared
    p.stdin.write('reap\n');p.stdin.flush();assert p.stdout.readline().strip()=='reaped'
    single=family.snapshot(p.pid,birth);assert single['status']=='observed'and single['processes']==1,single
    assert abs(shared['pss_kib']-single['pss_kib'])<4096
    assert shared['rss_sum_kib']>single['rss_sum_kib']+20000
    result={'scope':'Controlled shared32MiB mapping; not actual wtop memory budget',
            'shared_mapping':shared,'after_child_reaped':single,'PSS_preserves_simultaneous_ownership':True}
    (w/'prototype-shared-memory.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Private prototype shared mapping: RSS sum doublecounts while family PSS stays stable through child reap')
finally:
    if p.poll()is None:
        try:p.stdin.write('quit\n');p.stdin.flush();p.wait(timeout=3)
        except Exception:p.kill();p.wait()
