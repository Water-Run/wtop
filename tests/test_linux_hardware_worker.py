#!/usr/bin/env python3
"""Warmed hardware I/O timeout, source independence, recovery and real TUI input."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cc', default=os.environ.get('CC', 'cc'))
    parser.add_argument('--cflags', default='-std=c17 -O2 -Wall -Wextra -Werror')
    parser.add_argument('--lua-prefix', type=Path, default=ROOT/'.tools/lua-5.5.1')
    parser.add_argument('--module', type=Path, default=ROOT/'build/native/wtop_native.so')
    parser.add_argument('--output', type=Path, default=ROOT/'build/native-hardware-worker')
    parser.add_argument('--native-only', action='store_true')
    parser.add_argument('--shutdown-rounds', type=int, default=3)
    args = parser.parse_args()
    assert 1 <= args.shutdown_rounds <= 100
    assert args.module.is_file(), 'native module not found: ' + str(args.module)
    work = args.output.resolve(); work.mkdir(parents=True, exist_ok=True)
    library = work/'hardware_io_fake.so'
    subprocess.run(shlex.split(args.cc)+shlex.split(args.cflags)+['-fPIC','-shared',
        str(ROOT/'tests/native/hardware_io_fake.c'),'-ldl','-o',str(library)],check=True)
    with tempfile.TemporaryDirectory(prefix='hardware-reader-',dir=work) as temporary:
        directory=Path(temporary); tree=directory/'hwmon'; device=tree/'hwmon0'; device.mkdir(parents=True)
        for name,value in {'name':'wtop-fixture\n','temp1_label':'Isolated sensor\n',
                           'temp1_input':'42000\n','temp1_crit':'95000\n'}.items():
            (device/name).write_text(value)
        control=directory/'control'; control.write_text('0\n'); entered=directory/'entered'
        power=directory/'power'; zone=power/'intel-rapl:0';zone.mkdir(parents=True)
        (power/'intel-rapl').mkdir();(power/'intel-rapl'/'enabled').write_text('1\n')
        for name,value in {'name':'package-0\n','energy_uj':'1000000\n',
                           'max_energy_range_uj':'1000000000\n','enabled':'1\n',
                           'constraint_0_name':'long_term\n','constraint_0_power_limit_uw':'25000000\n'}.items():
            (zone/name).write_text(value)
        firmware=directory/'firmware';firmware.mkdir()
        def record(kind,handle,body,strings=()):
            return bytes([kind,len(body)+4])+handle.to_bytes(2,'little')+body+b'\0'.join(strings)+b'\0\0'
        (firmware/'DMI').write_bytes(record(10,0x1000,bytes([133,1]),[b'Firmware Ethernet'])
            +record(8,0x0800,bytes([1,0,2,18,16]),[b'Internal',b'USB'])+record(127,0xffff,b''))
        spd=directory/'spd';spd.mkdir()
        for address,fixture in [('13-0050','AQD-D5V16GR48-SB'),('13-0052','MTC40F2046S1RC48BA1')]:
            dimm=spd/address;dimm.mkdir();(dimm/'name').write_text('spd5118\n')
            (dimm/'eeprom').write_bytes((ROOT/'tests/fixtures/spd'/(fixture+'.bin')).read_bytes()+bytes(512))
        spd_control=directory/'spd-control';spd_control.write_text('0\n')
        spd_entered=directory/'spd-entered';spd_reads=directory/'spd-reads'
        firmware_control=directory/'firmware-control';firmware_control.write_text('0\n')
        firmware_entered=directory/'firmware-entered';firmware_reads=directory/'firmware-reads'
        env={**os.environ,'LD_PRELOAD':(os.environ['LD_PRELOAD']+':' if os.environ.get('LD_PRELOAD') else '')+str(library),
             'LUA_PATH':str(ROOT/'src/?.lua')+';'+str(ROOT/'src/?/init.lua')+';;',
             'LUA_CPATH':str(args.module.resolve().parent/'?.so')+';;',
             'WTOP_HARDWARE_FIXTURE_ROOT':str(tree),'WTOP_HARDWARE_FIXTURE_CONTROL':str(control),
             'WTOP_HARDWARE_FIXTURE_ENTERED':str(entered)}
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/hardware_worker_smoke.lua'),
                        str(ROOT),str(control),str(entered),str(power)],cwd=ROOT,env=env,check=True,timeout=20)
        firmware_env={**env,'WTOP_SMBIOS_FIXTURE_ROOT':str(firmware),
                      'WTOP_SMBIOS_FIXTURE_CONTROL':str(firmware_control),
                      'WTOP_SMBIOS_FIXTURE_ENTERED':str(firmware_entered),
                      'WTOP_SMBIOS_FIXTURE_READS':str(firmware_reads)}
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/smbios_worker_smoke.lua'),
                        str(ROOT),str(firmware_control),str(firmware_entered),str(firmware_reads)],
                       cwd=ROOT,env=firmware_env,check=True,timeout=20)
        spd_env={**env,'WTOP_SPD_FIXTURE_ROOT':str(spd),
                 'WTOP_SPD_FIXTURE_CONTROL':str(spd_control),
                 'WTOP_SPD_FIXTURE_ENTERED':str(spd_entered),
                 'WTOP_SPD_FIXTURE_READS':str(spd_reads)}
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/spd_worker_smoke.lua'),
                        str(ROOT),str(spd_control),str(spd_entered),str(spd_reads)],
                       cwd=ROOT,env=spd_env,check=True,timeout=20)
        for _ in range(args.shutdown_rounds):
            subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/hardware_worker_shutdown.lua'),
                            str(ROOT)],cwd=ROOT,env=env,check=True,timeout=5)
        print('ok: '+str(args.shutdown_rounds)+' standalone Lua VM exits with all declared asynchronous readers being reaped',flush=True)
        if not args.native_only:
            control.write_text('0\n'); entered.unlink(missing_ok=True)
            saved=os.environ.copy(); os.environ.update(env)
            os.environ.update(WTOP_ROOT=str(ROOT),WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
            sys.path.insert(0,str(ROOT/'tests'))
            import pty_smoke as pty
            original=pty._markers_visible
            screens={}; armed=False
            def visible(markers, data, columns, rows):
                nonlocal armed
                if not markers:return True
                screen=pty.VirtualScreen(columns,rows);screen.feed(bytes(data));text=screen.text()
                screens['last']=text
                if markers==('hardware-ready',):
                    if not any('Isolated sensor' in line and '42' in line
                               for line in text.splitlines()):return False
                    if not armed: control.write_text('1\n');armed=True
                    return True
                if markers==('hardware-stale',):
                    if not entered.exists() or not any('Isolated sensor' in line and 'Stale' in line
                                                      for line in text.splitlines()):return False
                    screens['stale']=text;return True
                return all(marker in text for marker in markers)
            pty._markers_visible=visible
            try:
                data=pty.run_session(240,60,exercise=False,cli_options=('--lang','en-US','--no-color','--interval','100'),
                    script=[(b'3',('CPU','Memory')),(('sleep',1.5),('hardware-ready',)),
                            (b'p',('hardware-stale',)),(b'\x1b',('Power and limits',)),
                            (b'2',None),(b'9',('PID','Command')),(b'q',('Host','Kernel'))])
                assert armed and screens
                capture=work/'warmed-hardware-stale.pty';capture.write_bytes(data);capture.chmod(0o600)
            finally:
                capture=work/'hardware-last-screen.txt';capture.write_text(screens.get('last',''));capture.chmod(0o600)
                pty._markers_visible=original;os.environ.clear();os.environ.update(saved)
            print('ok: warmed blocked hardware reader: stale value, power/process/system pages and quit responsive',flush=True)
        if not args.native_only:
            spd_control.write_text('1\n');spd_entered.unlink(missing_ok=True)
            saved=os.environ.copy();os.environ.update(spd_env)
            os.environ.update(WTOP_ROOT=str(ROOT),WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
            sys.path.insert(0,str(ROOT/'tests'))
            import pty_smoke as pty
            original=pty._markers_visible;screens={}
            def visible_spd(markers,data,columns,rows):
                if not markers:return True
                screen=pty.VirtualScreen(columns,rows);screen.feed(bytes(data));text=screen.text();screens['last']=text
                if markers==('spd-read-blocked',):
                    ready=spd_entered.exists() and 'Memory devices' in text
                    if ready:screens['blocked']=text
                    return ready
                return all(marker in text for marker in markers)
            pty._markers_visible=visible_spd
            try:
                data=pty.run_session(200,50,exercise=False,cli_options=('--lang','en-US','--no-color','--interval','100'),
                    script=[(b'4',None),(b'2',('spd-read-blocked',)),
                            (b'9',('PID','Command')),(b'q',('Host','Kernel'))])
                (work/'blocked-spd.pty').write_bytes(data)
                assert spd_control.read_text().strip()=='1', 'SPD fixture released before quit'
                reader_pids={int(pid) for pid in spd_reads.read_text().splitlines()}
                assert int(spd_entered.read_text()) in reader_pids
                deadline=time.monotonic()+1
                while any(Path('/proc',str(pid)).exists() for pid in reader_pids):
                    assert time.monotonic()<deadline, 'quit left an SPD child alive'
                    time.sleep(.01)
                print('ok: blocked SPD EEPROM: Memory/Processes/System navigation, clean quit and reap before release',flush=True)
            finally:
                (work/'spd-read-pids.txt').write_text(spd_reads.read_text()if spd_reads.exists()else'no SPD opens')
                spd_control.write_text('0\n')
                (work/'blocked-spd-memory-screen.txt').write_text(screens.get('blocked',''))
                (work/'blocked-spd-last-screen.txt').write_text(screens.get('last',''))
                pty._markers_visible=original;os.environ.clear();os.environ.update(saved)
    print('ok: isolated Linux hardware collectors',flush=True)

if __name__=='__main__':main()
