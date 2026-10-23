#!/usr/bin/env python3
"""Check native status decoding, bounded reduction, Lua fallback and OOM cleanup."""
import argparse,os,shlex,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--cc',default=os.environ.get('CC','cc'))
 p.add_argument('--cflags',default='-std=c17 -O2 -Wall -Wextra -Werror')
 p.add_argument('--lua-prefix',type=Path,default=ROOT/'.tools/lua-5.5.1')
 p.add_argument('--module',type=Path,default=ROOT/'build/native/wtop_native.so')
 p.add_argument('--output',type=Path,default=ROOT/'build/native-process-status')
 a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True);lua=a.lua_prefix.resolve()
 binary=out/'process-status';fixture=ROOT/'tests/native/linux_process_status.lua'
 subprocess.run(shlex.split(a.cc)+shlex.split(a.cflags)+['-no-pie','-I'+str(lua/'include'),str(ROOT/'tests/native/linux_process_status.c'),str(lua/'lib/liblua.a'),'-lm','-ldl','-pthread','-o',str(binary)],cwd=ROOT,check=True)
 env={**os.environ,'ASAN_OPTIONS':'detect_leaks=1:halt_on_error=1','UBSAN_OPTIONS':'halt_on_error=1:print_stacktrace=1','LSAN_OPTIONS':'exitcode=23'}
 subprocess.run([str(binary),str(fixture)],cwd=ROOT,env=env,check=True,timeout=30)
 env={**os.environ,'LUA_PATH':str(ROOT/'src/?.lua')+';'+str(ROOT/'src/?/init.lua')+';;','LUA_CPATH':str(a.module.resolve().parent/'?.so')+';;'}
 subprocess.run([str(lua/'bin/lua'),str(fixture)],cwd=ROOT,env=env,check=True,timeout=30)
 print('Linux status metadata: native decode/reduction, actual module exports, Lua field/error equivalence and allocation cleanup passed')
if __name__=='__main__':main()
