#!/usr/bin/env python3
"""Check Linux CPUID native boundaries and real isolated-reader lifecycle."""
import argparse,json,os,platform,re,shlex,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def birth(pid):
 try:return Path('/proc/'+str(pid)+'/stat').read_text().rsplit(')',1)[1].split()[19]
 except FileNotFoundError:return None
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--cc',default=os.environ.get('CC','cc'));p.add_argument('--cflags',default='-std=c17 -O2 -Wall -Wextra -Werror -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2')
 p.add_argument('--lua-prefix',type=Path,default=ROOT/'.tools/lua-5.5.1');p.add_argument('--module',type=Path,default=ROOT/'build/native/wtop_native.so')
 p.add_argument('--output',type=Path,default=ROOT/'build/native-cpuid');p.add_argument('--native-only',action='store_true')
 a=p.parse_args();w=a.output.resolve();w.mkdir(parents=True,exist_ok=True);lua=a.lua_prefix.resolve();flags=shlex.split(a.cflags);cc=shlex.split(a.cc)
 binary=w/'native-cpuid'
 subprocess.run(cc+flags+['-no-pie','-I'+str(lua/'include'),str(ROOT/'tests/native/linux_cpuid.c'),str(lua/'lib/liblua.a'),'-lm','-ldl','-pthread','-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True,timeout=15)
 if platform.machine()in ['x86_64','i386','i486','i586','i686']:
  capture=w/'shared-cpuid-capture'
  subprocess.run(cc+flags+['-I'+str(ROOT/'tests/native/cpuid_fixture'),'-I'+str(ROOT/'native'),str(ROOT/'tests/native/cpuid_capture.c'),'-o',str(capture)],check=True)
  subprocess.run([str(capture)],check=True,timeout=10)
 if a.native_only:return
 library=w/'cpuid-block.so'
 subprocess.run(cc+flags+['-shared','-fPIC',str(ROOT/'tests/native/linux_cpuid_block.c'),'-ldl','-o',str(library)],check=True)
 if platform.machine()not in ['x86_64','i386','i486','i586','i686']:return
 rows=[]
 for mode in ['warm','quit']:
  case=w/(mode+'-'+str(time.time_ns()));case.mkdir();control=case/'control';control.write_text('0\n');marker=case/'entered'
  sensor=case/'sensors/hwmon0';sensor.mkdir(parents=True);(sensor/'name').write_text('CPUID-independent sensor\n');(sensor/'temp1_input').write_text('42000\n')
  env={**os.environ,'LUA_PATH':str(ROOT/'src/?.lua')+';'+str(ROOT/'src/?/init.lua')+';;','LUA_CPATH':str(a.module.resolve().parent/'?.so')+';;',
       'WTOP_CPUID_BLOCK_CONTROL':str(control),'WTOP_CPUID_BLOCK_MARKER':str(marker),
       'LD_PRELOAD':(os.environ['LD_PRELOAD']+':'if os.environ.get('LD_PRELOAD')else'')+str(library)}
  began=time.monotonic();r=subprocess.run([str(lua/'bin/lua'),str(ROOT/'tests/native/linux_cpuid_worker.lua'),str(ROOT),str(control),str(marker),mode,str(sensor.parent)],cwd=ROOT,env=env,capture_output=True,timeout=20)
  log=case/'parent.log';log.write_bytes(r.stdout+r.stderr);assert r.returncode==(19 if mode=='quit'else 0),log
  if mode=='quit':
   match=re.search(rb'CPUID_BLOCKED\s+(\d+)\s+(\d+)',r.stdout);assert match,log
   pid=int(match[1]);start=match[2].decode();deadline=time.monotonic()+1
   while birth(pid)==start and time.monotonic()<deadline:time.sleep(.01)
   assert birth(pid)!=start,'parent exit left blocked CPUID reader alive'
   assert time.monotonic()-began<8,'reader waited for blocked API release'
  rows.append({'mode':mode,'returncode':r.returncode,'seconds':time.monotonic()-began});print('Linux CPUID',mode,'actual API lifecycle passed',flush=True)
 (w/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
if __name__=='__main__':main()
