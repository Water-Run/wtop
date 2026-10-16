#!/usr/bin/env python3
"""Embed read-only CPU workers and their digests in the x86 native module."""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path


def main() -> None:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--kind',choices=['cpuid','nvml','levelzero','adl'],default='cpuid')
    p.add_argument('--x86',type=Path,required=True)
    p.add_argument('--x64',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    lines=['/* Generated from the isolated CPUID workers. */','#ifndef WTOP_CPUID_HELPERS_H',
           '#define WTOP_CPUID_HELPERS_H']
    manifest=['WTOP_CPUID_WORKERS_V1']
    for name,path in [('x86',args.x86),('x64',args.x64)]:
        data=path.read_bytes()
        if not 0<len(data)<=512*1024:raise ValueError('unexpected worker size')
        lines.append('static const unsigned char wtop_cpuid_'+name+'[] = {')
        for offset in range(0,len(data),24):
            lines.append('  '+','.join('0x%02x'%byte for byte in data[offset:offset+24])+',')
        lines.append('};')
        lines.append('#define WTOP_CPUID_'+name.upper()+'_SHA256 "'+hashlib.sha256(data).hexdigest()+'"')
        manifest.append(name+':'+str(len(data))+':'+hashlib.sha256(data).hexdigest())
    manifest.append('END_WTOP_CPUID_WORKERS')
    lines.append('static const char wtop_cpuid_helpers_manifest[] __attribute__((used)) =')
    lines.extend('  "'+line+'\\n"' for line in manifest)
    lines.append(';')
    lines.append('#endif')
    if args.kind!='cpuid':lines=[line.replace('CPUID',args.kind.upper()).replace('cpuid',args.kind) for line in lines]
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text('\n'.join(lines)+'\n')


if __name__=='__main__':main()
