#!/usr/bin/env python3
"""A requested overlay must reach the terminal before the next collector tick.

The application uses the real native terminal and engine. Only the tick after
the selected input is held behind a pipe, so the observation does not depend
on the machine being fast enough to win a timing threshold.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
sys.path.insert(0, str(ROOT/'tests'))
import perf_benchmark as bench
from pty_smoke import VirtualScreen

LAUNCHER = r'''
local root = assert(os.getenv("WTOP_INPUT_TEST_ROOT"))
package.path = root.."/src/?.lua;"..root.."/src/?/init.lua;"..package.path
if arg and arg[1] == "--wtop-hardware-reader" then dofile(root.."/src/wtop.lua");return end
local Backend = require("wtop.ui.backend")
local Engine = require("wtop.engine")
local original_new, original_tick = Backend.new, Engine.tick
local armed, used = false, false
Backend.new = function(...)
    local backend = original_new(...)
    local original_poll = backend.poll
    backend.poll = function(...)
        local result, reason = original_poll(...)
        if not used and result and result.data == os.getenv("WTOP_INPUT_TEST_KEY") then
            local ready = io.open(assert(os.getenv("WTOP_INPUT_TEST_READY")), "rb")
            if ready then ready:close();armed, used = true, true end
        end
        return result, reason
    end
    return backend
end
Engine.tick = function(...)
    if armed then
        armed = false
        local marker = assert(io.open(assert(os.getenv("WTOP_INPUT_TEST_BLOCKED")), "wb"))
        assert(marker:write("blocked\n"));assert(marker:close())
        local release = assert(io.open(assert(os.getenv("WTOP_INPUT_TEST_PIPE")), "rb"))
        assert(release:read(1) == "r");assert(release:close())
    end
    return original_tick(...)
end
dofile(root.."/src/wtop.lua")
'''


def screen_text(session):
    ending = session.output.rfind(bench.FRAME_END)
    if ending < 0:
        return ''
    screen = VirtualScreen(bench.COLUMNS, bench.ROWS)
    screen.feed(bytes(session.output[:ending+len(bench.FRAME_END)]))
    return screen.text()


def run_case(work, name, key, marker, expect_blocked, lua, native):
    work.mkdir()
    (work/'entry.lua').write_text(LAUNCHER)
    fifo, blocked, ready = work/'release.pipe', work/'tick-blocked', work/'gate-ready'
    os.mkfifo(fifo, 0o600)
    release = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    variables = {'WTOP_INPUT_TEST_ROOT': str(ROOT), 'WTOP_INPUT_TEST_PIPE': str(fifo),
                 'WTOP_INPUT_TEST_BLOCKED': str(blocked), 'WTOP_INPUT_TEST_KEY': key,
                 'WTOP_INPUT_TEST_READY': str(ready),
                 'LUA_CPATH': str(native/'?.so')+';;'}
    command = '#!/bin/sh\n'+''.join('export '+k+'='+shlex.quote(v)+'\n'for k,v in variables.items())
    command += 'exec '+shlex.join([str(lua),str(work/'entry.lua')])+' "$@"\n'
    launcher = work/'wtop-input-test'
    launcher.write_text(command);launcher.chmod(0o700)
    bench.EXECUTABLE = str(launcher)
    session = bench.Session(interval_ms=1000)
    released = False
    def wait_marker(expected):
        deadline = time.monotonic()+8
        while expected not in screen_text(session):
            assert time.monotonic()<deadline, name+': preparation frame missing '+expected
            session.pump(.01)
    def matches(text):
        if name == 'power-close':
            return marker not in text and 'Kernel' in text
        if name == 'bandwidth-resume':
            return marker not in text and '1 s/column' in text
        return marker in text
    try:
        wait_marker('Kernel')
        if name == 'power-close':
            session.send(b'p');wait_marker('Sample / configured cap;')
        elif name in ['bandwidth-pause','bandwidth-resume']:
            session.send(b'b');wait_marker('System aggregate')
            if '1 s/column' not in screen_text(session):
                session.send(b'\r');wait_marker('1 s/column')
            if name == 'bandwidth-resume':
                session.send(b' ');wait_marker('Paused')
        session.pump(.2)
        ready.write_text('ready\n')
        session.send(key.encode('ascii'))
        deadline = time.monotonic()+5
        while not blocked.exists():
            assert time.monotonic()<deadline, name+': the controlled tick was not reached'
            session.pump(.01)
        # Drain anything the program wrote before entering the held tick.
        # No release byte is sent until after the terminal is inspected.
        session.pump(.15)
        text = screen_text(session)
        visible = matches(text)
        (work/'while-tick-held.txt').write_text(text)
        os.write(release,b'r');released = True
        deadline = time.monotonic()+5
        while not matches(screen_text(session)):
            assert time.monotonic()<deadline,name+': overlay missing after the tick was released'
            session.pump(.01)
        assert visible != expect_blocked, name+': overlay did not precede the held collector tick'
        session.send(b'\x1b');session.pump(.2)
        code,_,_ = session.exit()
        assert code==0,(name,'subject exit',code)
        return {'case':name,'visible_before_tick_released':visible,'subject_exit':code}
    finally:
        if not released:
            os.write(release,b'r')
        try:
            if os.waitpid(session.pid,os.WNOHANG)==(0,0):
                session.send(b'\x1b');session.pump(.2);session.exit()
        except (OSError,ChildProcessError):
            pass
        (work/'capture.pty').write_bytes(session.output)
        remaining=[]
        from perf_process_family import read_stat
        for attempt in range(40):
            remaining=[]
            for pid,birth in session.resources.seen.items():
                try:
                    if read_stat(pid)['birth']==birth:
                        remaining.append(pid)
                except (FileNotFoundError,ProcessLookupError):
                    pass
            if not remaining:
                break
            time.sleep(.05)
        (work/'cleanup.json').write_text(json.dumps({'identities':session.resources.seen,
                                                    'remaining':remaining},indent=2)+'\n')
        os.close(session.master);os.close(release)
        assert not remaining,(name,'observed application/reader identities still present',remaining)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lua-prefix',type=Path,default=ROOT/'.tools/lua-5.5.1')
    parser.add_argument('--native-directory',type=Path,default=ROOT/'build/native')
    parser.add_argument('--output',type=Path)
    parser.add_argument('--expect-blocked',action='store_true',help=argparse.SUPPRESS)
    args=parser.parse_args()
    lua=(args.lua_prefix/'bin/lua').resolve();native=args.native_directory.resolve()
    assert lua.is_file() and (native/'wtop_native.so').is_file()
    with tempfile.TemporaryDirectory(prefix='wtop-input-before-sampling-') as temporary:
        work=args.output.resolve() if args.output else Path(temporary)
        if args.output:
            work.mkdir(exist_ok=False)
        results=[]
        for name,key,marker in [('help','?','Navigation'),('power','p','Sample / configured cap;'),
                                ('bandwidth-picker','b','System aggregate'),
                                ('power-close','q','Sample / configured cap;'),
                                ('bandwidth-pause',' ','Paused'),('bandwidth-resume',' ','Paused')]:
            results.append(run_case(work/name,name,key,marker,args.expect_blocked,lua,native))
        (work/'proof.json').write_text(json.dumps({'status':'passed','negative_control':args.expect_blocked,
                                                  'cases':results},indent=2)+'\n')
        print('ok: six real-terminal overlay interactions observed before collector release; negative control =',args.expect_blocked)


if __name__=='__main__':
    os.umask(0o077)
    main()
