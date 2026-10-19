#!/usr/bin/env python3
"""Exercise real descendant accounting, old procfs and incomplete observations."""
import importlib.util
import errno
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import perf_process_family as family


def fixture(proc, pid=1, ppid=0, birth=111, own=10, children=None):
    base = proc / str(pid)
    task = base / 'task' / str(pid)
    task.mkdir(parents=True)
    fields = ['0'] * 22
    fields[0], fields[1], fields[11], fields[19] = 'S', str(ppid), str(own), str(birth)
    (base / 'stat').write_text(str(pid) + ' (name with ) spaces) ' + ' '.join(fields) + '\n')
    if children is not None:
        (task / 'children').write_text(children)
    (base / 'smaps').write_text(
        '1000-2000 rw-p 0000 00:00 0 /mapping:example\n'
        'Pss: 8 kB\nRss: 12 kB\nPrivate_Clean: 1 kB\nPrivate_Dirty: 2 kB\n')


def main():
    class TooManyTasks:
        count = 0
        def iterdir(self):
            for number in range(10000):
                self.count += 1
                assert self.count <= 4097, 'thread iterator read beyond its bound'
                yield pathlib.Path(str(number))
    tasks = TooManyTasks()
    try:
        family.bounded_tasks(tasks)
    except family.Incomplete:
        assert tasks.count == 4097
    else:
        raise AssertionError('thread enumeration bound was ignored')
    with tempfile.TemporaryDirectory(prefix='wtop-family-tests-') as temporary:
        work = pathlib.Path(temporary)
        proc = work / 'proc'; proc.mkdir()
        fixture(proc)
        fixture(proc, 2, 1, 222, 40)
        sample = family.snapshot(1, 111, proc)
        assert sample['status'] == 'observed' and sample['family_ticks'] == 50
        assert sample['discovery_source'] == 'proc_scan_fallback'
        assert sample['pss_kib'] == 16 and sample['private_resident_kib'] == 6
        assert sample['hugetlb_status'] == 'unavailable' and 'hugetlb_mapped_kib' not in sample
        assert family.snapshot(1, 112, proc)['status'] == 'incomplete'
        original = (proc/'1/smaps').read_text()
        for bad in (original.replace('Pss: 8', 'Pss: -8'),
                    original.replace('Pss: 8 kB\n', ''), original + 'Pss: 1 kB\n'):
            (proc/'1/smaps').write_text(bad)
            sample = family.snapshot(1, 111, proc)
            assert sample['cpu_status'] == 'observed' and sample['memory_status'] != 'observed'
            assert 'pss_kib' not in sample
        (proc/'1/smaps').write_text(original)
        # A startup memory-interface race can leave stat identity readable.
        # Recover only through a new complete sample, without carrying the
        # other member's earlier partial memory total into the result.
        memory = family.memory
        calls = []
        def transient_memory(*args, **kwargs):
            calls.append(args[0])
            if len(calls) == 1:
                raise ProcessLookupError(errno.ESRCH, 'fixture startup memory race')
            result = memory(*args, **kwargs)
            if len(calls) == 2:
                result['pss_kib'] = 999
            return result
        family.memory = transient_memory
        try:
            recovered = family.snapshot(1, 111, proc)
            assert recovered['status'] == 'observed' and recovered['attempts'] == 2
            assert recovered['pss_kib'] == 16 and len(calls) == 4, recovered
        finally:
            family.memory = memory
        # A persistent unavailable interface is still unknown after the
        # bounded retries. Permission failures do not trigger this retry.
        for exception, expected_status, expected_calls in [
            (ProcessLookupError(errno.ESRCH, 'fixture persistent race'), 'unavailable', 6),
            (FileNotFoundError(errno.ENOENT, 'fixture missing interface'), 'unavailable', 6),
            (PermissionError(errno.EACCES, 'fixture denied interface'), 'denied', 2),
        ]:
            calls = []
            def unavailable_memory(*args, **kwargs):
                calls.append(args[0])
                raise exception
            family.memory = unavailable_memory
            try:
                unavailable = family.snapshot(1, 111, proc)
                assert unavailable['cpu_status'] == 'observed'
                assert unavailable['memory_status'] == expected_status and 'pss_kib' not in unavailable
                assert len(calls) == expected_calls, calls
            finally:
                family.memory = memory
        # Reap races must not turn overlapping parent/child counters into a
        # normal sample. Retry is bounded and reports no invented zero.
        discover = family.discover
        def racing(*args, **kwargs):
            result = discover(*args, **kwargs)
            racing.count += 1
            result[1]['waited'] = racing.count
            return result
        racing.count = 0
        family.discover = racing
        try:
            sample = family.snapshot(1, 111, proc)
            assert sample['status'] == 'incomplete' and 'family_ticks' not in sample
            assert racing.count == 6
        finally:
            family.discover = discover
        # An observed child still alive after leaving the tree is a coverage
        # failure. It cannot vanish from the family rate and memory budget.
        sampler = family.Sampler(1, proc=proc)
        sampler.sample(force=True)
        (proc/'2/stat').write_text((proc/'2/stat').read_text().replace('S 1 ', 'S 99 '))
        sample = sampler.sample(force=True)
        assert sampler.escaped and sample['cpu_status'] == sample['memory_status'] == 'incomplete'
        assert sampler.record()['memory_status'] == 'incomplete'
        # A rejected race sample has no validated roster. It must not label
        # every previously seen live reader as an escaped descendant.
        (proc/'2/stat').write_text((proc/'2/stat').read_text().replace('S 99 ', 'S 1 '))
        sampler=family.Sampler(1,proc=proc);sampler.sample(force=True)
        snapshot=family.snapshot
        family.snapshot=lambda *args,**kwargs:{'status':'incomplete','reason':'fixture reap race'}
        try:
            sampler.sample(force=True)
            assert not sampler.escaped
        finally:family.snapshot=snapshot
        assert sampler.sample(force=True)['cpu_status']=='observed'
        for helper in ['perf_family_nested.py', 'perf_family_shared.py']:
            subprocess.run([sys.executable, str(ROOT/'tests/native'/helper), str(work)],
                           check=True, timeout=15, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True)
        # Exercise the actual benchmark producer. A quiet TUI parent with an
        # expensive reader used to produce an apparently cheap whole-program
        # record, even though its live child used a core and 32 MiB.
        reader = "import time; block=bytearray(32*1024*1024); print('ready',flush=True); end=time.monotonic()+15\nwhile time.monotonic()<end:pass"
        subject = work/'reader-tui'
        subject.write_text("#!"+sys.executable+"\n"+'''import os,subprocess,sys,tty
child=subprocess.Popen([sys.executable,'-c',READER],stdout=subprocess.PIPE)
try:
 assert child.stdout.readline().strip()==b'ready'
 tty.setraw(0);os.write(1,b'wtop Kernel\\x1b[0m')
 while True:
  key=os.read(0,1)
  if key==b'q':break
  if key in [b'1',b'2']:os.write(1,(b'Kernel'if key==b'1'else b'Command')+b'\\x1b[0m')
finally:
 if child.poll()is None:child.terminate()
 child.wait(timeout=3)
'''.replace('READER',repr(reader)))
        subject.chmod(0o755)
        result_path=work/'producer.json'
        environment=os.environ.copy();environment['WTOP_BENCH_EXECUTABLE']=str(subject)
        subprocess.run([sys.executable,str(ROOT/'tools/perf_benchmark.py'),'--pages','1',
                        '--window-seconds','.5','--latency-samples','2','--json',str(result_path)],
                       env=environment,check=True,timeout=15,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                       universal_newlines=True)
        produced=json.loads(result_path.read_text())
        assert produced['measurement_version']==4 and produced['exit_code']==0
        assert produced['steady_cpu_percent']['page_1']>20,produced['steady_cpu_percent']
        assert produced['steady_cpu_percent']['page_1']>produced['parent_cpu_percent']['page_1']+20
        resources=produced['resource_accounting']
        assert resources['cpu_status']==resources['memory_status']=='observed',resources
        assert produced['family_sampled_pss_peak_kib']>32768
        assert any(row['processes']==2 for row in resources['samples'])
    print('process-family: nested/non-leader/reap CPU, shared memory, PID reuse, permissions, old procfs, invalid fields and reap races passed')


if __name__ == '__main__':
    main()
