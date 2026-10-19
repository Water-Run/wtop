"""Bounded Linux process-family observations for the performance benchmark.

CPU covers observed descendants and waited-for children. Memory uses sampled
PSS, with RSS and private resident memory kept as separate diagnostics.
Snapshots bracket identity, membership and reap counters; they do not claim
that escaped or unobserved daemon descendants have been measured."""
import errno
import os
import pathlib
import re
import time

CPU_SCOPE = 'observed_descendants_and_waited_children'
MEMORY_SCOPE = 'sampled_family_pss'
MAX_SAMPLES = 32768


class Incomplete(Exception):
    pass


def read_stat(pid, proc=pathlib.Path('/proc')):
    with (proc / str(pid) / 'stat').open('rb') as stream:
        data = stream.read(65537)
    if len(data) > 65536:
        raise Incomplete('process stat byte bound')
    fields = data.rsplit(b')', 1)[1].split()
    if len(fields) < 22:
        raise Incomplete('short process stat')
    values = [int(fields[index]) for index in [1, 11, 12, 13, 14, 19]]
    if any(value < 0 for value in values):
        raise Incomplete('negative process counter')
    return {'pid': pid, 'ppid': values[0], 'own': values[1] + values[2],
            'waited': values[3] + values[4], 'birth': values[5],
            'state': fields[0].decode('ascii')}


def discover_scan(root, birth, proc, bound):
    records, children, count = {}, {}, 0
    for path in proc.iterdir():
        if not path.name.isdigit():continue
        count += 1
        if count > 65536:raise Incomplete('host process scan bound')
        try:record=read_stat(int(path.name),proc)
        except (FileNotFoundError,ProcessLookupError):continue
        records[record['pid']]=record
        children.setdefault(record['ppid'],[]).append(record['pid'])
    result,pending={},[root]
    while pending:
        pid=pending.pop()
        if pid in result:continue
        if len(result)>=bound:raise Incomplete('family process bound')
        if pid not in records:raise Incomplete('root or descendant missing during scan')
        result[pid]=records[pid];pending.extend(children.get(pid,[]))
    if result[root]['birth']!=birth or result[root]['state']in ['Z','X']:
        raise Incomplete('root replaced or exited')
    result[root]['discovery_source']='proc_scan_fallback'
    return result


def bounded_tasks(directory):
    tasks = []
    for task in directory.iterdir():
        if len(tasks) == 4096:
            raise Incomplete('thread enumeration bound')
        tasks.append(task)
    return sorted(tasks, key=lambda path: int(path.name))


def discover(root, birth, proc=pathlib.Path('/proc'), bound=256):
    pending, result = [root], {}
    while pending:
        pid = pending.pop()
        if pid in result:
            continue
        if len(result) >= bound:
            raise Incomplete('family process bound')
        record = read_stat(pid, proc)
        if pid == root and (record['birth'] != birth or record['state'] in ['Z', 'X']):
            raise Incomplete('root replaced or exited')
        result[pid] = record
        # fork() from a non-leader thread is visible in that task's children.
        tasks = bounded_tasks(proc / str(pid) / 'task')
        for task in tasks:
            try:
                with (task / 'children').open('rb') as stream:
                    data = stream.read(1048577)
            except FileNotFoundError:
                if task.exists()and(proc/str(pid)/'stat').exists():
                    return discover_scan(root,birth,proc,bound)
                raise
            if len(data) > 1048576:
                raise Incomplete('children byte bound')
            children = data.split()
            if any(not child.isdigit() for child in children):
                raise Incomplete('invalid child PID')
            pending.extend(int(child) for child in children)
    for pid, record in result.items():
        if pid != root and record['ppid'] not in result:
            raise Incomplete('descendant reparented')
    result[root]['discovery_source']='thread_children'
    return result


def memory(pid, proc=pathlib.Path('/proc')):
    fields = {}
    required = ['Pss', 'Rss', 'Private_Clean', 'Private_Dirty']
    path = proc / str(pid) / 'smaps_rollup'
    try:
        stream = path.open('rb')
        mode = 'smaps_rollup'
    except FileNotFoundError:
        stream = (proc / str(pid) / 'smaps').open('rb')
        mode = 'smaps'
    total, mapping_fields, mappings = 0, set(), 0
    with stream:
        while True:
            line = stream.readline(16385)
            if not line:
                break
            total += len(line)
            if total > 16777216 or len(line) > 16384:
                raise Incomplete('smaps read bound')
            if re.match(rb'^[0-9a-fA-F]+-[0-9a-fA-F]+\s', line):
                if mappings and not set(required).issubset(mapping_fields):
                    raise Incomplete('incomplete memory mapping')
                mappings += 1; mapping_fields = set()
            match = re.fullmatch(rb'([A-Za-z_]+):\s+(\d+)\s+kB\s*', line)
            if match:
                name, value = match[1].decode('ascii'), int(match[2])
                if name in mapping_fields:
                    raise Incomplete('duplicate memory field')
                mapping_fields.add(name)
                fields[name] = fields.get(name, 0) + value
            elif line.split(b':',1)[0] in [key.encode('ascii') for key in required]:
                raise Incomplete('malformed memory field')
    if mappings and not set(required).issubset(mapping_fields):
        raise Incomplete('truncated memory mapping')
    if any(key not in fields for key in required):
        raise Incomplete('memory field unavailable')
    huge_known = all(key in fields for key in ['Shared_Hugetlb', 'Private_Hugetlb'])
    return {'pss_kib': fields['Pss'], 'rss_sum_kib': fields['Rss'],
            'private_resident_kib': fields['Private_Clean'] + fields['Private_Dirty'],
            'hugetlb_mapped_kib': fields['Shared_Hugetlb'] + fields['Private_Hugetlb'] if huge_known else None,
            'hugetlb_status': 'observed' if huge_known else 'unavailable',
            'source': mode}


def snapshot(root, birth, proc=pathlib.Path('/proc'), attempts=3):
    last = None
    for attempt in range(attempts):
        began = time.monotonic()
        try:
            before = discover(root, birth, proc)
            resident, memory_errors = {}, []
            transient_memory = False
            for pid, record in before.items():
                try:
                    resident[pid] = None if record['state'] in ['Z', 'X'] else memory(pid, proc)
                except (OSError, ValueError, Incomplete) as error:
                    memory_errors.append({'status':'denied'if isinstance(error,PermissionError)else'unavailable','reason':str(error)})
                    transient_memory = transient_memory or (isinstance(error, OSError)
                        and error.errno in (errno.ESRCH, errno.ENOENT))
            after = discover(root, birth, proc)
            if set(before) != set(after):
                raise Incomplete('family roster changed')
            for pid, row in before.items():
                newer = after[pid]
                if any(row[key] != newer[key] for key in ['birth', 'ppid', 'waited']):
                    raise Incomplete('identity/reap changed')
                if (row['state'] in ['Z', 'X']) != (newer['state'] in ['Z', 'X']):
                    raise Incomplete('process exited during memory sample')
                if newer['own'] < row['own']:
                    raise Incomplete('process CPU counter decreased')
            # A task can keep its PID/start time while its memory interface
            # briefly disappears during startup. Retry the entire validated
            # sample, never reuse another attempt's partial memory totals.
            if transient_memory and attempt + 1 < attempts:
                continue
            # Each member contributes its own CPU and only the children it has
            # already waited for. Live members are separate, so no recursive
            # subtree total or per-process high-water memory is summed here.
            result = {'status': 'partial'if memory_errors else'observed', 'cpu_status':'observed',
                      'memory_status':memory_errors[0]['status']if memory_errors else'observed',
                      'own_ticks': after[root]['own'],
                      'family_ticks': sum(row['own'] + row['waited'] for row in after.values()),
                      'discovery_source':after[root]['discovery_source'],
                      'processes': len(after), 'sample_started': began,
                      'attempts': attempt + 1,
                      'sample_finished': time.monotonic(),
                      'scope': 'currently observed descendants plus their waited-for CPU; no escaped-process proof'}
            if memory_errors:
                result['memory_error_count']=len(memory_errors)
                result['memory_errors']=memory_errors[:8]
            else:
                for key in ['pss_kib', 'rss_sum_kib', 'private_resident_kib']:
                    result[key] = sum(row[key] for row in resident.values() if row is not None)
                known_huge = all(row['hugetlb_status']=='observed' for row in resident.values() if row is not None)
                result['hugetlb_status'] = 'observed' if known_huge else 'unavailable'
                if known_huge:
                    result['hugetlb_mapped_kib'] = sum(row['hugetlb_mapped_kib'] for row in resident.values() if row is not None)
            result['memory_sources'] = sorted(set(row['source'] for row in resident.values() if row is not None))
            result['_members'] = {pid: row['birth'] for pid,row in after.items()}
            return result
        except (OSError, ValueError, IndexError, Incomplete) as error:
            last = str(error)
    return {'status': 'incomplete', 'reason': last, 'attempts': attempts}


class Sampler:
    """Sample while the PTY is drained; preserve unavailable metrics as such."""
    def __init__(self, pid, period_ms=200, proc=pathlib.Path('/proc')):
        self.pid, self.proc, self.period_ms = pid, proc, period_ms
        try:
            self.birth = read_stat(pid, proc)['birth']
        except (OSError, ValueError, IndexError, Incomplete):
            self.birth = None
        self.samples, self.seen = [], {}
        self.next_due, self.observer_cpu_seconds = 0.0, 0.0
        self.active, self.overflow, self.escaped = True, False, False

    def sample(self, force=False):
        if not self.active or (not force and time.monotonic() < self.next_due):
            return self.samples[-1] if self.samples else None
        cpu_start = time.process_time()
        sample_started = time.monotonic()
        if self.birth is None:
            value = {'status':'incomplete','cpu_status':'unavailable','memory_status':'unavailable',
                     'reason':'root identity unavailable','sample_started':time.monotonic()}
        else:
            value = snapshot(self.pid,self.birth,self.proc)
        members = value.pop('_members', {})
        # A known descendant that is still alive outside this tree cannot be
        # silently discarded. Unknown short-lived daemon escapes remain outside
        # the explicitly sampled lineage scope.
        previous_members = self.seen.items() if value.get('cpu_status') == 'observed' else ()
        for pid, birth in previous_members:
            if pid in members or pid==self.pid:continue
            try:
                record=read_stat(pid,self.proc)
                if record['birth']==birth and record['state']not in ['Z','X']:
                    self.escaped=True
            except (FileNotFoundError,ProcessLookupError):pass
            except (OSError,ValueError,IndexError,Incomplete):self.escaped=True
        if len(set(self.seen).union(members))>4096:
            self.overflow=True
        else:
            self.seen.update(members)
        if self.escaped or self.overflow:
            value['cpu_status']='incomplete'
            value['status']='incomplete'
            value['memory_status']='incomplete'
            value['reason']='known descendant escaped or observer bound exceeded'
        value.setdefault('cpu_status','unavailable')
        value.setdefault('memory_status','unavailable')
        value.setdefault('sample_started',sample_started)
        value.setdefault('sample_finished',time.monotonic())
        value['sample_cpu_seconds']=time.process_time()-cpu_start
        self.observer_cpu_seconds+=value['sample_cpu_seconds']
        if len(self.samples)<MAX_SAMPLES:
            self.samples.append(value)
        else:
            self.overflow=True
            self.active=False
        self.next_due=time.monotonic()+self.period_ms/1000.0
        return value

    def finish(self):
        self.sample(force=True)
        self.active=False

    def record(self):
        memory = [row for row in self.samples if row['memory_status']=='observed']
        cpu_ok=bool(self.samples)and all(row['cpu_status']=='observed'for row in self.samples)
        memory_ok=bool(self.samples)and len(memory)==len(self.samples)
        result={'cpu_scope':CPU_SCOPE,'memory_scope':MEMORY_SCOPE,
                'lineage_scope':'sampled descendants; unobserved daemon escapes not proven absent',
                'sample_period_ms':self.period_ms,'clock_ticks_per_second':os.sysconf('SC_CLK_TCK'),
                'cpu_status':'observed'if cpu_ok and not self.overflow else'incomplete',
                'memory_status':'observed'if memory_ok and not self.overflow else'incomplete',
                'observer_cpu_seconds':self.observer_cpu_seconds,'sample_bound_exceeded':self.overflow,
                'samples':self.samples}
        if memory_ok and not self.overflow:
            for key in ['pss_kib','private_resident_kib','rss_sum_kib']:
                result['sampled_peak_'+key]=max(row[key]for row in memory)
            huge_ok=all(row.get('hugetlb_status')=='observed'and row.get('hugetlb_mapped_kib')==0 for row in memory)
            result['hugetlb_status']='known_zero'if huge_ok else'unavailable_or_nonzero'
        return result
