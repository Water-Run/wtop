"""Re-envelope upstream register dumps; this does not simulate an OS probe."""
from pathlib import Path
import argparse
import tarfile
import hashlib
import json
import re
import struct
import xml.etree.ElementTree as ET

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-dir', type=Path, required=True, help='Pinned original archives and XML from sources.json')
parser.add_argument('--output', type=Path, default=here)
options = parser.parse_args()
root = options.source_dir
metadata = json.loads((here / 'sources.json').read_text())
for source in metadata['files']:
    if not source['name'].endswith(('.tar.bz2', '.xml')):
        continue
    assert hashlib.sha256((root / source['name']).read_bytes()).hexdigest() == source['sha256']
output = options.output / 'replay'
output.mkdir(parents=True, exist_ok=True)
manifest = []
for source in metadata['files']:
    if not source['name'].endswith('.tar.bz2'):
        continue
    name = source['name'].removesuffix('.tar.bz2')
    with tarfile.open(root / source['name']) as archive:
        cpu_files = sorted([(int(Path(item.name).name[2:]), archive.extractfile(item).read().decode('ascii'))
                            for item in archive.getmembers() if item.isfile() and re.fullmatch(r'pu[0-9]+', Path(item.name).name)], key=lambda item: item[0])
    body = bytearray()
    ids = []
    for cpu_id, capture in cpu_files:
        ids.append(cpu_id)
        values = {}
        for line in capture.splitlines():
            match = re.fullmatch(r'([0-9a-fA-F ]+) => ([0-9a-fA-F ]+)', line)
            if not match:
                continue
            inputs = [int(v, 16) for v in match[1].split()]
            registers = tuple(int(v, 16) for v in match[2].split())
            assert len(inputs) == 5 and len(registers) == 4
            mask, eax, ebx, ecx, edx = inputs
            assert mask & 1 and not mask & ~5
            key = (eax, ecx if mask & 4 else 0)
            assert key not in values
            values[key] = registers
        # Only the bounded production reader's register families are included.
        fixed = {0, 1, 2, 5, 6, 0x15, 0x16, 0x1a, 0x80000000, 0x8000001e}
        fixed.update(range(0x80000001, 0x80000009))
        selected = sorted((key, value) for key, value in values.items()
                          if key[0] in fixed and key[1] == 0
                          or key[0] == 7 and key[1] <= 2
                          or key[0] == 0xd and key[1] <= 1
                          or key[0] in {0xb, 0x1f, 0x80000026} and key[1] < 16
                          or key[0] == 0x8000001d and key[1] < 32)
        assert 0 < len(selected) <= 96
        first = values[(1, 0)]
        # Flags are synthetic framing only: CPUID, verified OS id, restored.
        # XCR0 and OS SIMD state are deliberately not fabricated from dumps.
        body.extend(struct.pack('<12I', cpu_id, 0, cpu_id, 0, len(selected),
                                values[(0, 0)][0], values[(0x80000000, 0)][0],
                                0x98, 0, 0, first[0], first[1] >> 24))
        for (number, sub), registers in selected:
            body.extend(struct.pack('<6I', number, sub, *registers))
    checksum = 2166136261
    for byte in body:
        checksum = ((checksum ^ byte) * 16777619) & 0xffffffff
    packet = struct.pack('<8I', 0x50435457, 2, 32 + len(body), len(ids), 64, 0, checksum, 0) + body
    binary = output / (name + '.bin')
    binary.write_bytes(packet)
    tree = ET.parse(root / (name + '.xml'))
    expected = []
    for obj in tree.iter('object'):
        if obj.get('type') not in {'Package', 'Core', 'L1Cache', 'L1iCache', 'L2Cache', 'L3Cache'}:
            continue
        members = sorted(int(p.get('os_index')) for p in obj.iter('object')
                         if p.get('type') == 'PU')
        expected.append({'type': obj.get('type'), 'cpu_ids': members,
                         **{k: v for k, v in obj.attrib.items()
                            if k in {'cache_size', 'cache_linesize', 'cache_associativity', 'cache_type', 'depth'}}})
    (output / (name + '.expected.json')).write_text(json.dumps(expected, indent=2) + '\n')
    manifest.append({'dataset': name, 'path': str(binary.relative_to(options.output)),
                     'sha256': hashlib.sha256(packet).hexdigest(), 'cpu_ids': ids,
                     'expected_counts': {kind: sum(obj.get('type') == kind for obj in tree.iter('object')) for kind in ['Machine', 'Package', 'Die', 'Core', 'PU', 'L1Cache', 'L2Cache', 'L3Cache']},
                     'scope': 'Upstream CPUID replay; synthetic transport and affinity flags; no XCR0/OS usability or wtop real-host acceptance'})
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Prepared four bounded register replay fixtures with independent expected XML memberships')
