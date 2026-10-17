#!/usr/bin/env python3
"""Compile the real POSIX poll bodies and inject signals during Lua conversion."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def function(source, signature):
    start = source.index(signature)
    end = source.index('\n}', start) + 2
    return source[start:end]


PRELUDE = r'''#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <signal.h>
#include <poll.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include "wtop_terminal_signal.h"
static int selected_signal, position, armed, booleans;
static int push_errno(lua_State *L,const char *operation){(void)operation;lua_pushnil(L);return 1;}
static void injected_pushboolean(lua_State *L,int value){
    lua_pushboolean(L,value);
    if(armed && ++booleans==position){armed=0;raise(selected_signal);}
}
#define lua_pushboolean injected_pushboolean
'''
MAIN = r'''
#undef lua_pushboolean
static int observed(lua_State *L,const char *name){
    lua_getfield(L,-1,name);int result=lua_toboolean(L,-1);lua_pop(L,1);return result;
}
static int poll_flag(lua_State *L,const char *name){
    lua_settop(L,0);lua_pushinteger(L,0);l_poll(L);return observed(L,name);
}
int main(void){
    int descriptors[2];if(pipe(descriptors)||dup2(descriptors[0],STDIN_FILENO)<0)return 2;
    lua_State *L=luaL_newstate();if(!L)return 2;
    const int numbers[]={SIGWINCH,SIGINT,SIGTERM,SIGHUP};
    const char *fields[]={"resize","interrupt","terminate","hangup"};
    for(unsigned i=0;i<4;++i){
        struct sigaction action={0};action.sa_handler=TEST_HANDLER;
        sigemptyset(&action.sa_mask);if(sigaction(numbers[i],&action,NULL))return 2;
        for(position=0;position<=4;++position){
            wtop_terminal_signal_reset(0);selected_signal=numbers[i];booleans=0;armed=position!=0;
            if(!position)raise(selected_signal);
            int first=poll_flag(L,fields[i]);
            int second=poll_flag(L,fields[i]);
            int third=poll_flag(L,fields[i]);
            if((!position&&(first!=1||second!=0)) || (position&&(first!=0||second!=1)) || third){
                fprintf(stderr,"signal=%s position=%d first=%d second=%d third=%d\n",fields[i],position,first,second,third);
                return 1;
            }
        }
    }
    lua_close(L);close(descriptors[0]);close(descriptors[1]);
    puts("20 real signal interleavings preserved exactly once");return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--lua-prefix', type=Path, default=ROOT / '.tools/lua-5.5.1')
    parser.add_argument('--cc', default=os.environ.get('CC', 'cc'))
    parser.add_argument('--cflags', default='-std=c17 -O2 -Wall -Wextra -Werror')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/native-terminal-signals')
    args = parser.parse_args()
    root = args.root.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='terminal-signals-', dir=str(args.output)) as temp:
        folder = Path(temp)
        for name, handler in [('wtop_native.c', 'signal_handler'), ('wtop_macos.c', 'terminal_signal')]:
            source = (root / 'native' / name).read_text()
            declaration = ('static struct {int active,input_fd;} g_terminal={0,0};\n'
                           if name == 'wtop_native.c' else '')
            body = (PRELUDE + declaration
                    + function(source, 'static void ' + handler + '(int ') + '\n'
                    + function(source, 'static int l_poll(lua_State *L) {')
                    + MAIN.replace('TEST_HANDLER', handler))
            path = folder / (name + '.fixture.c')
            path.write_text(body)
            executable = folder / (name + '.fixture')
            command = (shlex.split(args.cc) + shlex.split(args.cflags)
                       + ['-I' + str(args.lua_prefix.resolve() / 'include'),
                          '-I' + str(root / 'native'), str(path),
                          str(args.lua_prefix.resolve() / 'lib/liblua.a'), '-lm', '-ldl',
                          '-o', str(executable)])
            subprocess.run(command, check=True)
            result = subprocess.run([str(executable)], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=5)
            if result.returncode:
                raise RuntimeError(name + ': ' + result.stderr.decode('utf-8', 'replace'))
            print(name + ': ' + result.stdout.decode('utf-8').strip(), flush=True)
    print('ok: real POSIX poll bodies, early/late signal delivery and no duplicate events', flush=True)


if __name__ == '__main__':
    main()
