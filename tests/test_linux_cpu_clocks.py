#!/usr/bin/env python3
"""Isolated CPU frequency counters, precise windows and warmed read failure."""
import argparse,os,shlex,struct,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--cc',default=os.environ.get('CC','cc'))
 p.add_argument('--cflags',default='-std=c17 -O2 -Wall -Wextra -Werror -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2')
 p.add_argument('--lua-prefix',type=Path,default=ROOT/'.tools/lua-5.5.1')
 p.add_argument('--module',type=Path,default=ROOT/'build/native/wtop_native.so')
 p.add_argument('--output',type=Path,default=ROOT/'build/native-cpu-clocks')
 args=p.parse_args();work=args.output.resolve();work.mkdir(parents=True,exist_ok=True)
 library=work/'cpu_clock_fake.so'
 subprocess.run(shlex.split(args.cc)+shlex.split(args.cflags)+['-shared','-fPIC',str(ROOT/'tests/native/cpu_clock_fake.c'),'-ldl','-o',str(library)],check=True)
 with tempfile.TemporaryDirectory(prefix='cpu-clock-',dir=work) as temp:
  directory=Path(temp);tree=directory/'cpu';topology=tree/'cpu0/topology';topology.mkdir(parents=True)
  (tree/'online').write_text('0\n');(topology/'physical_package_id').write_text('0\n');(topology/'core_id').write_text('0\n')
  info=directory/'cpuinfo';info.write_text('processor : 0\nvendor_id : GenuineIntel\ncpu family : 6\nmodel : 186\nflags : msr aperfmperf\n\n')
  devices=directory/'devices';devices.mkdir();counters=devices/'cpu0';counters.write_bytes(struct.pack('<QQ',1000000000,1000000000))
  control=directory/'control';control.write_text('0\n');entered=directory/'entered'
  env={**os.environ,'LUA_PATH':str(ROOT/'src/?.lua')+';'+str(ROOT/'src/?/init.lua')+';;',
       'LUA_CPATH':str(args.module.resolve().parent/'?.so')+';;',
       'LD_PRELOAD':(os.environ['LD_PRELOAD']+':' if os.environ.get('LD_PRELOAD') else '')+str(library),
       'WTOP_CPU_CLOCK_ROOT':str(devices),'WTOP_CPU_CLOCK_CONTROL':str(control),'WTOP_CPU_CLOCK_ENTERED':str(entered)}
  subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/cpu_clock_worker_smoke.lua'),str(ROOT),str(tree),str(info),str(counters),str(control),str(entered)],cwd=ROOT,env=env,check=True,timeout=25)
if __name__=='__main__':main()
