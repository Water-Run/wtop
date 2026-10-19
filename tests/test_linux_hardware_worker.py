#!/usr/bin/env python3
"""Warmed hardware I/O timeout, source independence, recovery and real TUI input."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def verify_cta_application(args, env, work):
    """Exercise decoded claims in the production CLI and terminal, via fake sysfs."""
    command = ([str(args.executable.resolve())] if args.executable else
               [str(args.lua_prefix.resolve()/'bin/lua'), str(ROOT/'src/wtop.lua')])
    records, observations = {}, set()
    for mode in ['snapshot', 'agent', 'report', 'stream']:
        extra = ['--count', '8', '--interval', '1000'] if mode == 'stream' else []
        result = subprocess.run(command+['--'+mode]+extra, cwd=ROOT, env=env,
                                capture_output=True, timeout=40)
        for suffix, data in [('out', result.stdout), ('stderr', result.stderr)]:
            path = work/('cta-'+mode+'.'+suffix);path.write_bytes(data);path.chmod(0o600)
        result.check_returncode()
        records[mode] = hashlib.sha256(result.stdout).hexdigest()
        if mode == 'report':
            for text in [b'CTA video declarations', b'CTA audio declarations', b'CTA static HDR declarations',
                         b'CTA HDMI declarations', b'CTA extension detailed timings', b'smpte_st2084']:
                assert text in result.stdout, text
            continue
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(rows) == (8 if mode == 'stream' else 1)
        for data in rows:
            displays = data['metrics']['displays'] if mode == 'agent' else data['displays']
            panel = next(x for x in displays['devices'] if x['id'] == 'card1-eDP-1')
            if mode == 'stream':observations.add(panel['observed_at_ns'])
            ext = panel['edid']['extensions'][0]
            assert ext['decoded'] and ext['quality'] == 'fresh'
            assert ext['video_formats'][1]['vic'] == 97 and ext['video_formats'][1]['ycbcr420_capable']
            assert ext['audio_formats'][0]['maximum_channels'] == 2
            assert ext['hdr_static_metadata'][0]['desired_maximum_luminance_cdm2'] == 400
            assert ext['vendors'][1]['vrr_minimum_hz'] == 40 and ext['vendors'][1]['vrr_maximum_hz'] == 120
            assert ext['detailed_timings'][0]['refresh_hz'] == 60
            assert panel['current_mode']['refresh_hz'] == 60 and panel['current_mode']['pixel_width'] == 1920
            assert 'PRIVATE' not in json.dumps(panel) and 'physical_address' not in json.dumps(panel)
    assert len(observations) >= 2, 'CTA stream never received a second display observation'
    saved = os.environ.copy()
    os.environ.update(env, WTOP_ROOT=str(ROOT), WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
    if args.executable:os.environ['WTOP_EXECUTABLE'] = str(args.executable.resolve())
    sys.path.insert(0, str(ROOT/'tests'))
    import pty_smoke as pty
    original = pty._markers_visible
    tty = []
    try:
        for columns, rows, locale, ascii_mode in [(80, 24, 'en-US', False), (80, 24, 'zh-CN', False), (100, 30, 'en-US', True)]:
            screens = {}
            def visible(markers, data, width, height):
                screen = pty.VirtualScreen(width, height);screen.feed(bytes(data));text = screen.text()
                if 'card1-eDP-1' in text:screens[hashlib.sha256(text.encode()).hexdigest()] = text
                return not markers or all(marker in text for marker in markers)
            pty._markers_visible = visible
            detail = 'Device:' if locale == 'en-US' else '设备：'
            script = [(b'9', None), (('sleep', 1), None), (b'/', None), (b'id:display:card1-eDP-1', None),
                      (b'\r', None), (('sleep', .3), None), (b'\r', None), (('sleep', .3), (detail, 'card1-eDP-1'))]
            for _ in range(10):script.extend([(b'\x1b[6~', None), (('sleep', .12), None)])
            script.extend([(b'\x1b', None), (b'2', None), (('sleep', .2), ('Processes',) if locale == 'en-US' else ('进程',)), (b'q', None)])
            environment = {'TERM':'dumb', 'COLORTERM':None, 'LANG':'C', 'LC_ALL':'C', 'LC_CTYPE':'C'} if ascii_mode else None
            raw = pty.run_session(columns, rows, exercise=False, cli_options=('--lang', locale, '--no-color'),
                                  terminal_environment=environment, script=script)
            # Preserve the exact failed screen too; an assertion before saving
            # otherwise leaves no evidence of which detail the scroll reached.
            stem = 'cta-'+str(columns)+'-'+locale+('-ascii' if ascii_mode else '')
            path = work/(stem+'.pty');path.write_bytes(raw);path.chmod(0o600)
            path = work/(stem+'-screens.json');path.write_text(json.dumps(screens));path.chmod(0o600)
            normalized = ' '.join(' '.join(screens.values()).split())
            for text in ['CTA-861', 'VIC 97', 'VIC 193', 'Linear PCM', 'PQ', '400', '40 - 120 Hz']:
                assert text in normalized, (locale, text)
            if ascii_mode:assert all(byte < 128 for byte in raw)
            hashes = {}
            for index, (digest, text) in enumerate(screens.items()):
                path = work/(stem+'-screen-'+str(index)+'.txt');path.write_text(text);path.chmod(0o600);hashes[path.name] = digest
            tty.append({'columns':columns, 'rows':rows, 'locale':locale, 'ascii':ascii_mode,
                        'pty_sha256':hashlib.sha256(raw).hexdigest(), 'screens':hashes})
    finally:
        pty._markers_visible = original;os.environ.clear();os.environ.update(saved)
    readers = {int(pid) for pid in Path(env['WTOP_DISPLAY_FIXTURE_READS']).read_text().splitlines()}
    deadline = time.monotonic()+2
    while any(Path('/proc', str(pid)).exists() for pid in readers):
        assert time.monotonic()<deadline, 'CTA reader survived application exit'
        time.sleep(.01)
    path = work/'CTA-application-acceptance.json'
    path.write_text(json.dumps({'status':'passed', 'scope':'software sysfs declarations through production reader/CLI/TUI',
                               'CLI_sha256':records, 'stream_snapshots':8, 'distinct_display_observations':len(observations),
                               'display_readers_reaped':True, 'TTY':tty}, indent=2)+'\n');path.chmod(0o600)
    print('ok: CTA production CLI/8 stream snapshots/three terminal cases: video, audio, color, HDR, VRR and configured-mode separation', flush=True)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cc', default=os.environ.get('CC', 'cc'))
    parser.add_argument('--cflags', default='-std=c17 -O2 -Wall -Wextra -Werror')
    parser.add_argument('--lua-prefix', type=Path, default=ROOT/'.tools/lua-5.5.1')
    parser.add_argument('--module', type=Path, default=ROOT/'build/native/wtop_native.so')
    parser.add_argument('--executable', type=Path, help='Installed program for the application checks')
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
        drm=directory/'drm';panel=drm/'card1-eDP-1';panel.mkdir(parents=True)
        (drm/'card1').mkdir();(drm/'card1/dev').write_text('226:1\n')
        for name,value in {'status':'connected\n','enabled':'enabled\n','dpms':'On\n',
                           'connector_id':'95\n','modes':'1920x1080\n'}.items():
            (panel/name).write_text(value)
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),'-e',
            r'''package.path="./tests/?.lua;"..package.path
local D=require("support.display_fixtures");local B=D.cta_block
local data=B(2,"\144\97\193")..B(1,"\9\7\7")..B(4,"\1\0\0")
  ..B(7,"\5\224\192")..B(7,"\6\15\1\96\64\128")
  ..B(3,"\3\12\0\16\0\56\30")..B(3,"\216\93\196\1\120\128\3\2\40\120")..B(7,"\15\2")
local bytes=D.edid({extensions=1,tail=D.cta({data=data,flags=0xf1,timings=D.edid():sub(55,72)})})
local f=assert(io.open(os.getenv("WTOP_TEST_EDID_OUTPUT"),"wb"));assert(f:write(bytes));assert(f:close())'''],
            input=b'',env={**os.environ,'WTOP_TEST_EDID_OUTPUT':str(panel/'edid')},cwd=ROOT,check=True,timeout=5)
        display_control=directory/'display-control';display_control.write_text('0\n')
        display_entered=directory/'display-entered';display_reads=directory/'display-reads'
        mode_control=directory/'mode-control';mode_control.write_text('0\n')
        mode_entered=directory/'mode-entered';mode_reads=directory/'mode-reads'
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
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/spd_hidden_worker_smoke.lua'),
                        str(ROOT),str(spd_control),str(spd_entered),str(spd_reads)],
                       cwd=ROOT,env=spd_env,check=True,timeout=20)
        display_env={**env,'WTOP_DRM_FIXTURE_ROOT':str(drm),
                     'WTOP_DISPLAY_FIXTURE_CONTROL':str(display_control),
                     'WTOP_DISPLAY_FIXTURE_ENTERED':str(display_entered),
                     'WTOP_DISPLAY_FIXTURE_READS':str(display_reads),
                     'WTOP_DRM_MODE_FIXTURE_CONTROL':str(mode_control),
                     'WTOP_DRM_MODE_FIXTURE_ENTERED':str(mode_entered),
                     'WTOP_DRM_MODE_FIXTURE_READS':str(mode_reads)}
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/display_worker_smoke.lua'),
                        str(ROOT),str(display_control),str(display_entered),str(display_reads),str(mode_control),str(mode_entered)],
                       cwd=ROOT,env=display_env,check=True,timeout=35)
        if not args.native_only:
            display_control.write_text('0\n');mode_control.write_text('0\n')
            verify_cta_application(args, display_env, work)
        for _ in range(args.shutdown_rounds):
            subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/hardware_worker_shutdown.lua'),
                            str(ROOT)],cwd=ROOT,env=env,check=True,timeout=5)
        print('ok: '+str(args.shutdown_rounds)+' standalone Lua VM exits with all declared asynchronous readers being reaped',flush=True)
        if not args.native_only:
            display_control.write_text('0\n');mode_control.write_text('0\n');mode_entered.unlink(missing_ok=True)
            saved=os.environ.copy();os.environ.update(display_env)
            os.environ.update(WTOP_ROOT=str(ROOT),WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
            sys.path.insert(0,str(ROOT/'tests'))
            import pty_smoke as pty
            original=pty._markers_visible;screens={};armed=False
            def visible_mode(markers,data,columns,rows):
                nonlocal armed
                if not markers:return True
                screen=pty.VirtualScreen(columns,rows);screen.feed(bytes(data));text=screen.text();screens['last']=text
                if markers==('mode-ready',):
                    ready='Configured output size'in text and '1920 x 1080'in text and 'FixturePanel'in text
                    if ready and not armed:mode_control.write_text('1\n');armed=True
                    if ready:screens['ready']=text
                    return ready
                if markers==('mode-stale',):
                    ready=mode_entered.exists()and 'Configured output size'in text and 'Stale'in text and '60 Hz'in text
                    if ready:screens['stale']=text
                    return ready
                return all(marker in text for marker in markers)
            pty._markers_visible=visible_mode
            try:
                data=pty.run_session(240,60,exercise=False,cli_options=('--lang','en-US','--no-color','--interval','100'),
                    script=[(b'9',None),(('sleep',1),None),(b'/',None),(b'id:display:card1-eDP-1',None),
                            (b'\r',None),(('sleep',.2),None),(b'\r',None),(('sleep',.4),('mode-ready',)),
                            (('sleep',5.5),('mode-stale',)),(b'\x1b',None),(b'2',None),
                            (b'1',('PID','Command')),(b'p',None),(b'\x1b',('Power and limits',)),
                            (b'9',None),(b'q',None)])
                assert armed and 'stale'in screens
                (work/'warmed-mode-stale.pty').write_bytes(data)
                (work/'warmed-mode-stale.txt').write_text(screens['stale'])
                for name in ['warmed-mode-stale.pty','warmed-mode-stale.txt']:(work/name).chmod(0o600)
                deadline=time.monotonic()+2
                pids={int(pid)for pid in mode_reads.read_text().splitlines()}
                while any(Path('/proc',str(pid)).exists()for pid in pids):
                    assert time.monotonic()<deadline,'mode reader survived TUI exit'
                    time.sleep(.01)
            finally:
                (work/'mode-last-screen.txt').write_text(screens.get('last',''))
                pty._markers_visible=original;os.environ.clear();os.environ.update(saved)
            print('ok: warmed blocked mode ioctl: original mode marked stale, process/overview/power/system and quit responsive; owned readers reaped',flush=True)
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
            prior_pids={int(value)for value in spd_reads.read_text().splitlines()}
            saved=os.environ.copy();os.environ.update(spd_env)
            os.environ.update(WTOP_ROOT=str(ROOT),WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
            original=pty._markers_visible;screens={}
            started=time.monotonic()
            def hidden_ready(markers,data,columns,rows):
                if not markers:return True
                screen=pty.VirtualScreen(columns,rows);screen.feed(bytes(data));text=screen.text();screens['last']=text
                if markers==('hidden-spd-reaped',):
                    pids={int(value)for value in spd_reads.read_text().splitlines()}-prior_pids
                    ready=time.monotonic()-started>=1 and '[Overview]'in text and bool(pids) and not any(Path('/proc',str(pid)).exists()for pid in pids)
                    if ready:screens['overview']=text
                    return ready
                return all(marker in text for marker in markers)
            pty._markers_visible=hidden_ready
            try:
                data=pty.run_session(200,50,exercise=False,cli_options=('--lang','en-US','--no-color','--interval','100'),
                    script=[(b'4',('hidden-spd-reaped',)),(b'2',('Memory devices',)),
                            (b'1',('PID','Command')),(b'q',('CPU','Memory'))])
                assert 'overview'in screens
                (work/'hidden-spd.pty').write_bytes(data)
                print('ok: cold Overview completes hidden SPD and reaps it before Memory/Processes/Overview/quit',flush=True)
            finally:
                (work/'hidden-spd-overview.txt').write_text(screens.get('overview',''))
                pty._markers_visible=original;os.environ.clear();os.environ.update(saved)
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
