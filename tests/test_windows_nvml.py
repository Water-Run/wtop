#!/usr/bin/env python3
"""Build and run independent Windows SDK fixtures without an installed GPU driver.

The instrumented DLL and reader path overrides stay in this test directory.
Production runtime files are read as inputs and are not replaced.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

ROOT=Path(__file__).resolve().parents[1]

def build(runtime: Path, output: Path) -> None:
    output.mkdir(parents=True,exist_ok=False)
    common=['-std=c17','-O2','-Wall','-Wextra','-Werror','-static-libgcc']
    for arch,cc,version in [('x86','i686-w64-mingw32-gcc',1),('x64','x86_64-w64-mingw32-gcc',2)]:
        obj=output/('nvml-'+arch+'.o')
        subprocess.run([cc,*common,'-DWTOP_GPU_WORKER','-include',str(ROOT/'tests/native/windows_nvml_paths.h'),
                        '-c',str(ROOT/'native/wtop_nvml.c'),'-o',str(obj)],check=True)
        subprocess.run([cc,*common,'-s','-municode','-DWTOP_GPU_WORKER',
                        f'-Wl,--no-insert-timestamp,--major-os-version,5,--minor-os-version,{version},--major-subsystem-version,5,--minor-subsystem-version,{version}',
                        str(ROOT/'native/wtop_windows_nvml_helper.c'),str(obj),'-o',str(output/('reader-'+arch+'.exe'))],check=True)
        for variant in range(4):
            folder=output/('sdk-'+arch+'-'+str(variant))/'system';folder.mkdir(parents=True)
            subprocess.run([cc,*common,'-shared','-DWTOP_NVML_VARIANT='+str(variant),'-Wl,--export-all-symbols',
                            str(ROOT/'tests/native/nvml_fake.c'),'-o',str(folder/'nvml.dll')],check=True)
    cc='x86_64-w64-mingw32-gcc'
    subprocess.run([cc,*common,'-DWTOP_GPU_WORKER','-include',str(ROOT/'tests/native/windows_watcher_delay.h'),
                    '-c',str(ROOT/'native/wtop_windows_nvml_helper.c'),'-o',str(output/'watcher-ready.o')],check=True)
    subprocess.run([cc,*common,'-municode',str(output/'watcher-ready.o'),str(output/'nvml-x64.o'),
                    str(ROOT/'tests/native/windows_watcher_delay.c'),'-o',str(output/'watcher-ready.exe')],check=True)
    subprocess.run(['i686-w64-mingw32-gcc',*common,str(ROOT/'tests/native/windows_watcher_ready.c'),
                    '-o',str(output/'watcher-test.exe')],check=True)
    subprocess.run([sys.executable,str(ROOT/'tools/embed_cpuid_helpers.py'),'--kind','nvml',
                    '--x86',str(output/'reader-x86.exe'),'--x64',str(output/'reader-x64.exe'),
                    '--output',str(output/'wtop_nvml_helpers.h')],check=True)
    cc='i686-w64-mingw32-gcc'
    flags=[*common,'-I'+str(output),'-I'+str(runtime/'include'),'-I'+str(ROOT/'build/native'),'-I'+str(ROOT/'build/windows-x86')]
    obj=output/'worker.o'
    subprocess.run([cc,*flags,'-include',str(ROOT/'tests/native/windows_nvml_arch.h'),'-c',
                    str(ROOT/'native/wtop_windows_worker.c'),'-o',str(obj)],check=True)
    units=['wtop_windows.c','wtop_windows_net.c','wtop_windows_hw.c','wtop_windows_cpu.c','wtop_windows_disk.c','wtop_windows_cpuid.c']
    (output/'fixture').mkdir()
    subprocess.run([cc,*flags,'-shared',*[str(ROOT/'native'/name) for name in units],str(obj),
                    str(runtime/'liblua55.dll.a'),'-lpsapi','-liphlpapi','-lsetupapi','-o',str(output/'fixture/wtop_native.dll')],check=True)
    for name in ['lua.exe','lua55.dll']:shutil.copyfile(runtime/name,output/name)
    shutil.copytree(ROOT/'src',output/'src')
    for source,name in [('windows_nvml_cases.lua','cases.lua'),('windows_nvml_cache.lua','cache.lua'),('windows_gpu_scan.lua','scan.lua')]:
        shutil.copyfile(ROOT/'tests/native'/source,output/name)
    with zipfile.ZipFile(output.with_suffix('.zip'),'x',zipfile.ZIP_DEFLATED)as archive:
        for path in sorted(output.rglob('*')):
            if path.is_file() and path.suffix not in ['.o','.h']:archive.write(path,path.relative_to(output).as_posix())
    print('Windows NVML fixture archive built',flush=True)

def run(folder: Path) -> None:
    assert os.name=='nt','execute the prepared fixtures on Windows'
    variants={0:[0,1,2,3,7,8,9,10,11,12,13,14,15,16,17,18,19,*range(20,26),26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52],
              1:[0,7,8,12,18,30,40],2:[0,7,8],3:[0]}
    rows=[]
    for bits,arch in [(32,'x86'),(64,'x64')]:
        profile=folder/'profiles'/str(bits);profile.mkdir(parents=True)
        for variant,modes in variants.items():
            for mode in modes:
                env={**os.environ,'LUA_PATH':str(folder/'src/?.lua')+';'+str(folder/'src/?/init.lua')+';;',
                     'LUA_CPATH':str(folder/'fixture/?.dll')+';;','APPDATA':str(profile),
                     'WTOP_NVML_TEST_ROOT':str(folder/('sdk-'+arch+'-'+str(variant))),
                     'WTOP_NVML_TEST_BITS':str(bits),'WTOP_NVML_FIXTURE_MODE':str(mode)}
                result=subprocess.run([str(folder/'lua.exe'),str(folder/'cases.lua'),'process'],env=env,capture_output=True,timeout=10)
                log=folder/f'case-{bits}-{variant}-{mode}.log';log.write_bytes(result.stdout+result.stderr)
                assert result.returncode==0,log
                text=result.stdout.decode('utf-8');match=re.search(r'^NVML_MATRIX_RESULT (.+)$',text,re.M);assert match,log
                value=json.loads(match[1]);data=value.get('data');reason=value.get('reason')
                assert 'driver stdout'not in text and b'driver stderr'not in result.stderr
                if variant==3:assert reason=='nvml_symbols_missing' and not data
                elif mode in [45,46,47,48]:assert reason=='nvml_query_timeout' and not data
                elif mode==51:assert reason=='nvml_worker_exited' and not data
                elif mode==1:assert reason=='nvml_initialization_failed' and not data
                elif mode in [2,3,34]:assert reason=='nvml_device_count_failed' and not data
                else:
                    assert data and data['devices'],log
                    device=data['devices'][0]
                    if variant==2:assert 'power_watts'not in device
                    elif mode in [7,33,37]:assert 'power_watts'not in device
                    elif mode==8:assert device['power_watts']==0
                    elif variant==1 or mode in [17,18,19]:
                        assert device['power_watts']==123.456 and device['power_measurement']=='device_sample'
                    elif mode in [16,40]:
                        assert device['power_watts']==42.25 and device['power_measurement']=='average'
                        assert device['power_interval_ns']==1000000000
                    else:assert device['power_watts']==300
                    if variant!=2 and mode not in [7,33]:assert device['power_limit_watts']==355.5
                    if variant==0 and mode==41:assert device['power_quality']=='stale'
                    if variant==0 and mode in [42,43]:assert device['power_quality']=='gap'
                rows.append({'bits':bits,'variant':variant,'mode':mode,'max_ms':value['maximum_foreground_ms']})
        # A fresh directory exercises simultaneous first creation of the image.
        profile=folder/'cache-profiles'/str(bits);profile.mkdir(parents=True)
        body=(folder/('reader-'+arch+'.exe')).read_bytes();checksum=2166136261
        for byte in body:checksum=((checksum^byte)*16777619)&0xffffffff
        env={**os.environ,'LUA_PATH':str(folder/'src/?.lua')+';'+str(folder/'src/?/init.lua')+';;',
             'LUA_CPATH':str(folder/'fixture/?.dll')+';;','APPDATA':str(profile),
             'WTOP_NVML_TEST_ROOT':str(folder/('sdk-'+arch+'-0')),'WTOP_NVML_TEST_BITS':str(bits),
             'WTOP_NVML_FIXTURE_MODE':'0','WTOP_NVML_CACHE_IMAGE':str(profile/'wtop/readers'/f'nvml-x{bits}-{checksum:08x}.exe'),
             'WTOP_NVML_EXPECT_IMAGE':str(folder/('reader-'+arch+'.exe'))}
        result=subprocess.run([str(folder/'lua.exe'),str(folder/'cache.lua')],env=env,capture_output=True,timeout=15)
        (folder/f'cache-{bits}.log').write_bytes(result.stdout+result.stderr);assert result.returncode==0
        print('Windows NVML',bits,'SDK semantics/faults/cache passed',flush=True)
    profile=folder/'scan-profile';profile.mkdir(parents=True)
    env={**os.environ,'LUA_PATH':str(folder/'src/?.lua')+';'+str(folder/'src/?/init.lua')+';;',
         'LUA_CPATH':str(folder/'fixture/?.dll')+';;','APPDATA':str(profile)}
    result=subprocess.run([str(folder/'lua.exe'),str(folder/'scan.lua'),str(folder/'src/wtop.lua')],
                          env=env,capture_output=True,timeout=15)
    (folder/'scan.log').write_bytes(result.stdout+result.stderr);assert result.returncode==0
    print('Windows GPU actual child process scan cycles passed',flush=True)
    controlled=folder/'watcher-ready-test';controlled.mkdir()
    env={**os.environ,'WTOP_NVML_TEST_ROOT':str(folder/'sdk-x64-0')}
    result=subprocess.run([str(folder/'watcher-test.exe'),'ready',str(folder/'watcher-ready.exe'),str(controlled)],
                          env=env,capture_output=True,timeout=15)
    (folder/'watcher-ready.log').write_bytes(result.stdout+result.stderr)
    assert result.returncode==0 and b'reader_reaped_before_release=1'in result.stdout
    print('Windows SDK watcher ready before blocked DLL constructor passed',flush=True)
    (folder/'result.json').write_text(json.dumps({'cases':rows,'physical_power_readings':False},indent=2)+'\n')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build',action='store_true');parser.add_argument('--runtime',type=Path,default=ROOT/'dist/windows-x86')
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    if args.build:build(args.runtime.resolve(),args.output.resolve())
    else:run(args.output.resolve())
