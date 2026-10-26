#!/usr/bin/env python3
"""Warmed hardware I/O timeout, source independence, recovery and real TUI input."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def typec_fixture(lua_prefix, directory):
    """Materialize the shared ABI fixture; readlink exposes synthetic sysfs paths."""
    script='package.path="./src/?.lua;./src/?/init.lua;./tests/?.lua;"..package.path;print(require("wtop.format.json").encode(require("support.typec").new()))'
    fixture=json.loads(subprocess.check_output([str(lua_prefix.resolve()/'bin/lua'),'-e',script],cwd=ROOT,timeout=10))
    physical=directory/'typec-devices';ports=directory/'typec-class';pd=directory/'pd-class'
    ports.mkdir();pd.mkdir()
    for name,value in fixture['files'].items():
        if name.startswith('/sys/class/typec/'):
            relative=Path(name).relative_to('/sys/class/typec');path=physical/'typec'/relative
        else:
            relative=Path(name).relative_to('/sys/class/usb_power_delivery');path=physical/'usb_power_delivery'/relative
        path.parent.mkdir(parents=True,exist_ok=True);path.write_text(value)
    for parent,category in [(ports,'typec'),(pd,'usb_power_delivery')]:
        for child in (physical/category).iterdir():
            parent.joinpath(child.name).symlink_to(child)
    port=physical/'typec/port0';object_path=physical/'usb_power_delivery/pd7'
    (port/'device').symlink_to(physical);(object_path/'device').symlink_to(physical)
    (port/'usb_power_delivery').symlink_to(object_path)
    control=directory/'typec-control';control.write_text('0\n');entered=directory/'typec-entered'
    return {'WTOP_TYPEC_FIXTURE_ROOT':str(ports),'WTOP_PD_FIXTURE_ROOT':str(pd),
            'WTOP_TYPEC_PHYSICAL_ROOT':str(physical),'WTOP_TYPEC_FIXTURE_CONTROL':str(control),
            'WTOP_TYPEC_FIXTURE_ENTERED':str(entered)}

def verify_typec_application(args, env, work):
    """Production Type-C declarations and typed navigation, without hardware writes."""
    command=([str(args.executable.resolve())] if args.executable else
             [str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'src/wtop.lua')])
    receipts={}
    for mode in ['snapshot','agent','report','stream']:
        extra=['--count','4','--interval','1000'] if mode=='stream' else []
        run=subprocess.run(command+['--'+mode]+extra,cwd=ROOT,env=env,capture_output=True,timeout=35)
        for suffix,body in [('out',run.stdout),('stderr',run.stderr)]:
            path=work/('typec-'+mode+'.'+suffix);path.write_bytes(body);path.chmod(0o600)
        run.check_returncode();receipts[mode]=hashlib.sha256(run.stdout).hexdigest()
        if mode=='report':
            assert b'USB Type-C ports' in run.stdout and b'USB PD objects' in run.stdout
            assert b'45.00 W' in run.stdout and b'no selected contract' in run.stdout
            assert b'spr_adjustable_voltage_supply' in run.stdout
            continue
        rows=[json.loads(line)for line in run.stdout.splitlines()]
        assert len(rows)==(4 if mode=='stream' else 1)
        for snapshot in rows:
            data=snapshot['metrics']['power'] if mode=='agent' else snapshot['typec']
            ports=data['typec_ports'] if mode=='agent' else data['ports']
            assert len(ports)==1 and ports[0]['id']=='port0' and ports[0]['pd_id']=='pd7'
            assert ports[0]['data_role']=='host' and ports[0]['usb_default_mode']=='usb4'
            pd=data['pd_devices'][0];assert pd['declarations_only'] and pd['revision']=='3.1'
            assert len(pd['profiles'])==(8 if mode=='agent' else 10)
            for profile in pd['profiles']:
                assert profile['declarations_only'] and 'power_watts' not in profile and 'usage_percent' not in profile
            assert pd['profiles'][0]['voltage_volts']==5 and pd['profiles'][2]['maximum_power_watts']==45
    saved=os.environ.copy();os.environ.update(env,WTOP_ROOT=str(ROOT),WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
    if args.executable:os.environ['WTOP_EXECUTABLE']=str(args.executable.resolve())
    sys.path.insert(0,str(ROOT/'tests'));import pty_smoke as tty
    original=tty._markers_visible;screens={};terminals=[]
    def visible(markers,data,columns,rows):
        if markers and markers[0].startswith('typec-'):
            screen=tty.VirtualScreen(columns,rows);screen.feed(bytes(data));text=screen.text()
            screens[hashlib.sha256(text.encode()).hexdigest()]=text
            if markers==('typec-port',):return 'port0' in text and ('Reported data role' in text or '报告的数据角色' in text)
            if markers==('typec-pd',):return 'pd7' in text and ('PD object revision' in text or 'PD 对象规范修订版' in text)
            if markers==('typec-capture',):return True
        return original(markers,data,columns,rows)
    tty._markers_visible=visible
    try:
        for columns,rows,locale,ascii_mode in [(120,40,'en-US',False),(100,30,'zh-CN',False),(100,30,'en-US',True)]:
            screens.clear()
            script=[(b'9',None),(('sleep',2),None),(b'/',None),(b'id:typec:port0',None),(b'\r',None),
                    (('sleep',.6),None),(b'\r',None),(('sleep',.4),('typec-port',)),
                    (b'r',None),(('sleep',.4),('typec-pd',))]
            for _ in range(24):script.extend([(b'\x1b[6~',None),(('sleep',.1),('typec-capture',))])
            script.extend([(b'b',None),(('sleep',.3),('typec-port',)),(b'\x1b',None),
                           (b'2',None),(('sleep',.2),('Command',)if locale=='en-US'else('命令',)),(b'q',None)])
            terminal_env={'TERM':'dumb','COLORTERM':None,'LANG':'C','LC_ALL':'C','LC_CTYPE':'C'}if ascii_mode else None
            raw=tty.run_session(columns,rows,exercise=False,cli_options=('--lang',locale,'--no-color'),
                                terminal_environment=terminal_env,script=script)
            stem='typec-'+str(columns)+'-'+locale+('-ascii'if ascii_mode else '')
            for suffix,body in [('.pty',raw),('-screens.json',json.dumps(screens,ensure_ascii=False).encode())]:
                path=work/(stem+suffix);path.write_bytes(body);path.chmod(0o600)
            text=' '.join(' '.join(screens.values()).split())
            for marker in ['fixed_supply','variable_supply','battery','programmable_supply','spr_adjustable_voltage_supply']:
                assert marker in text,(locale,marker)
            assert ('PDOs declare supply'if locale=='en-US'else'PDO 描述供电能力')in text
            if ascii_mode:assert all(byte<128 for byte in raw)
            terminals.append(dict(columns=columns,rows=rows,locale=locale,ascii=ascii_mode,typed_navigation=True,
                                  pty_sha256=hashlib.sha256(raw).hexdigest()))
    finally:tty._markers_visible=original;os.environ.clear();os.environ.update(saved)
    control=Path(env['WTOP_TYPEC_FIXTURE_CONTROL']);entered=Path(env['WTOP_TYPEC_FIXTURE_ENTERED'])
    control.write_text('1\n');entered.unlink(missing_ok=True);owned={}
    def blocked_visible(markers,data,columns,rows):
        if markers==('typec-blocked',):
            try:
                pid=int(entered.read_text());proc=Path('/proc',str(pid),'stat')
                owned.update(pid=pid,birth=proc.read_text().rsplit(')',1)[1].split()[19])
                return True
            except (OSError,ValueError):return False
        return original(markers,data,columns,rows)
    tty._markers_visible=blocked_visible;os.environ.update(env,WTOP_ROOT=str(ROOT),WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
    if args.executable:os.environ['WTOP_EXECUTABLE']=str(args.executable.resolve())
    try:
        raw=tty.run_session(100,30,exercise=False,cli_options=('--lang','en-US','--no-color'),script=[
            (b'9',None),(('sleep',.2),('typec-blocked',)),(b'2',None),
            (('sleep',.2),('Command',)),(b'q',None)])
        assert owned
        proc=Path('/proc',str(owned['pid']),'stat')
        assert not proc.exists()or proc.read_text().rsplit(')',1)[1].split()[19]!=owned['birth']
    finally:control.write_text('0\n');tty._markers_visible=original;os.environ.clear();os.environ.update(saved)
    (work/'typec-blocked.pty').write_bytes(raw)
    blocked=dict(owned,actual_exit=0,driver_blocked_before_input=True,owned_reader_gone=True,
                 pty_sha256=hashlib.sha256(raw).hexdigest())
    (work/'TYPEC-application-acceptance.json').write_text(json.dumps(dict(status='passed',
        scope='software Type-C/PD tree through production readers/CLI/TUI; not active USB-PD contract verification',
        CLI_sha256=receipts,TTY=terminals,blocked_TTY=blocked),indent=2)+'\n')
    print('TYPEC_APPLICATION_PASSED:4CLI/4stream,five PDO kinds,EN/ZH/ASCII typed port-to-PD/back navigation and blocked-driver process/quit/reap',flush=True)

def verify_supply_input_application(args, env, work):
    """Software USB input through production collector, outputs and terminals."""
    command = ([str(args.executable.resolve())] if args.executable else
               [str(args.lua_prefix.resolve()/'bin/lua'), str(ROOT/'src/wtop.lua')])
    receipts, terminals = {}, []
    with tempfile.TemporaryDirectory(prefix='supply-input-', dir=work) as temporary:
        tree = Path(temporary); device = tree/'USB0'; device.mkdir()
        for name, value in {'type':'USB', 'online':'1', 'scope':'Device',
            'usb_type':'C [PD] PD_PPS', 'voltage_now':'20000000', 'current_now':'3000000',
            'voltage_max':'28000000', 'current_max':'5000000',
            'power_now':'60000000', 'input_power_limit':'80000000'}.items():
            (device/name).write_text(value+'\n')
        environment = {**env, 'WTOP_SUPPLY_FIXTURE_ROOT':str(tree)}
        for mode in ['snapshot', 'agent', 'report', 'stream']:
            extra = ['--count', '4', '--interval', '1000'] if mode == 'stream' else []
            run = subprocess.run(command+['--'+mode]+extra, cwd=ROOT, env=environment, capture_output=True, timeout=35)
            for suffix, body in [('out',run.stdout), ('stderr',run.stderr)]:
                path=work/('supply-input-'+mode+'.'+suffix);path.write_bytes(body);path.chmod(0o600)
            run.check_returncode();receipts[mode]=hashlib.sha256(run.stdout).hexdigest()
            if mode == 'report':
                assert b'External power supplies' in run.stdout and b'75.0%' in run.stdout
                assert b'separate from CPU or outlet power' in run.stdout
                continue
            rows = [json.loads(line) for line in run.stdout.splitlines()]
            assert len(rows) == (4 if mode == 'stream' else 1)
            for snapshot in rows:
                supplies = snapshot['metrics']['power']['supplies'] if mode == 'agent' else snapshot['power_supplies']['supplies']
                assert len(supplies)==1
                row=supplies[0]
                assert row['id']=='USB0' and row['voltage_volts']==20 and row['current_amperes']==3
                assert row['usb_type']=='PD' and row['power_watts']==60 and row['input_power_limit_watts']==80
                assert row['input_limit_percent']==75 and row['input_headroom_watts']==20
        saved=os.environ.copy();os.environ.update(environment,WTOP_ROOT=str(ROOT),WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
        if args.executable:os.environ['WTOP_EXECUTABLE']=str(args.executable.resolve())
        sys.path.insert(0,str(ROOT/'tests'));import pty_smoke as tty
        original=tty._markers_visible;screens={}
        def visible(markers,data,columns,rows):
            if markers==('supply-input-capture',):
                screen=tty.VirtualScreen(columns,rows);screen.feed(bytes(data));text=screen.text()
                screens[hashlib.sha256(text.encode()).hexdigest()]=text;return True
            return original(markers,data,columns,rows)
        tty._markers_visible=visible
        try:
            for columns,rows,locale,ascii_mode in [(100,30,'en-US',False),(80,24,'zh-CN',False),(100,30,'en-US',True)]:
                screens.clear()
                script=[(('sleep',2),None),(b'p',None),(('sleep',.5),('supply-input-capture',))]
                for _ in range(12):script.extend([(b'\x1b[6~',None),(('sleep',.15),('supply-input-capture',))])
                script.extend([(b'\x1b',None),(b'2',None),(('sleep',.3),('Command',) if locale=='en-US' else ('命令',)),(b'q',None)])
                terminal_environment={'TERM':'dumb','COLORTERM':None,'LANG':'C','LC_ALL':'C','LC_CTYPE':'C'} if ascii_mode else None
                raw=tty.run_session(columns,rows,exercise=False,cli_options=('--lang',locale,'--no-color'),
                    terminal_environment=terminal_environment,script=script)
                stem='supply-input-'+str(columns)+'-'+locale+('-ascii' if ascii_mode else '')
                for suffix,body in [('.pty',raw),('-screens.json',json.dumps(screens,ensure_ascii=False).encode())]:
                    path=work/(stem+suffix);path.write_bytes(body);path.chmod(0o600)
                text=' '.join(' '.join(screens.values()).split())
                for marker in ['USB0','PD_PPS','[######--]']:
                    assert marker in text,(locale,marker)
                assert re.search(r'75(?:[.,]0)?%', text), (locale, '75 percent')
                assert ('limits describe this input' if locale=='en-US' else '限制属于此输入端') in text
                if ascii_mode:assert all(byte<128 for byte in raw)
                terminals.append(dict(columns=columns,rows=rows,locale=locale,ascii=ascii_mode,pty_sha256=hashlib.sha256(raw).hexdigest()))
        finally:tty._markers_visible=original;os.environ.clear();os.environ.update(saved)
        control=work/'supply-input-blocked-control';control.write_text('1\n')
        entered=work/'supply-input-blocked-entered';entered.unlink(missing_ok=True)
        blocked_environment={**environment,'WTOP_SUPPLY_FIXTURE_CONTROL':str(control),
                             'WTOP_SUPPLY_FIXTURE_ENTERED':str(entered)}
        owned={}
        def blocked_visible(markers,data,columns,rows):
            if markers==('input-driver-blocked',):
                if not entered.exists():return False
                pid=int(entered.read_text());proc=Path('/proc',str(pid),'stat')
                if not proc.exists():return False
                owned.update(pid=pid,birth=proc.read_text().rsplit(')',1)[1].split()[19])
                return True
            return original(markers,data,columns,rows)
        tty._markers_visible=blocked_visible
        os.environ.update(blocked_environment,WTOP_ROOT=str(ROOT),WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
        if args.executable:os.environ['WTOP_EXECUTABLE']=str(args.executable.resolve())
        try:
            blocked_raw=tty.run_session(100,30,exercise=False,cli_options=('--lang','en-US','--no-color'),script=[
                (('sleep',1),('CPU','Memory')),(b'p',None),(('sleep',.2),('input-driver-blocked',)),
                (b'\x1b',None),(b'2',None),(('sleep',.2),('Command',)),(b'q',None)])
            assert owned, 'no actual blocked USB reader observed'
            proc=Path('/proc',str(owned['pid']),'stat')
            assert not proc.exists() or proc.read_text().rsplit(')',1)[1].split()[19]!=owned['birth']
        finally:
            control.write_text('0\n');tty._markers_visible=original;os.environ.clear();os.environ.update(saved)
        (work/'supply-input-blocked.pty').write_bytes(blocked_raw)
        blocked_proof=dict(owned,actual_exit=0,driver_blocked_before_input=True,process_navigation_and_quit=True,
                           owned_reader_gone=True,pty_sha256=hashlib.sha256(blocked_raw).hexdigest())
    (work/'SUPPLY-INPUT-application-acceptance.json').write_text(json.dumps(dict(status='passed',
        scope='software USB fixture through production reader/CLI/TUI; not physical USB power verification',
        CLI_sha256=receipts,TTY=terminals,blocked_TTY=blocked_proof),indent=2)+'\n')
    print('SUPPLY_INPUT_APPLICATION_PASSED:readonly USB units/modes,4CLI modes/4stream frames,English/Chinese/ASCII input-cap bars and separate CPU/outlet domains',flush=True)
    print('SUPPLY_INPUT_BLOCKED_TTY_PASSED:live USB reader blocked before input, process navigation/quit responsive and owned reader reaped',flush=True)

def verify_fan_control_application(args, env, work):
    """Standard PWM readback through the real worker, CLI and terminal."""
    command = ([str(args.executable.resolve())] if args.executable else
               [str(args.lua_prefix.resolve()/'bin/lua'), str(ROOT/'src/wtop.lua')])
    receipts = {}
    for mode in ['snapshot', 'agent', 'report', 'stream']:
        extra = ['--count', '4', '--interval', '1000'] if mode == 'stream' else []
        run = subprocess.run(command+['--'+mode]+extra, cwd=ROOT, env=env, capture_output=True, timeout=35)
        for suffix, body in [('out', run.stdout), ('stderr', run.stderr)]:
            path = work/('fan-control-'+mode+'.'+suffix);path.write_bytes(body);path.chmod(0o600)
        run.check_returncode();receipts[mode] = hashlib.sha256(run.stdout).hexdigest()
        if mode == 'report':
            assert b'Fan control settings' in run.stdout and b'not verified' in run.stdout
            assert b'50.2%' in run.stdout and b'25000 Hz' in run.stdout
            continue
        rows = [json.loads(line) for line in run.stdout.splitlines()]
        assert len(rows) == (4 if mode == 'stream' else 1)
        found = 0
        for snapshot in rows:
            if mode == 'agent':
                controls = snapshot['metrics']['sensors']['fan_controls']
                assert snapshot['metrics']['sensors']['fan_count'] == 1
            else:
                device = next(x for x in snapshot['sensors']['devices'] if x['name'] == 'wtop-fixture')
                controls = device['fan_controls']
                assert len([c for c in device['channels'] if c['type'] == 'fan']) == 1
            assert len(controls) == 1
            control = controls[0]
            assert control['raw_value'] == 128 and control['settings_only']
            assert control['control_method'] == 'manual' and control['output_mode'] == 'pwm'
            assert control['frequency_hz'] == 25000 and control['temperature_inputs'] == [1, 3]
            assert 'input' not in control and 'rpm' not in control and 'session' not in control
            if 'setting_percent' in control:
                assert abs(control['setting_percent']-128/255*100)<1e-9;found += 1
        assert found, 'no current PWM control setting in '+mode
    saved = os.environ.copy();os.environ.update(env, WTOP_ROOT=str(ROOT), WTOP_LUA=str(args.lua_prefix.resolve()/'bin/lua'))
    if args.executable:os.environ['WTOP_EXECUTABLE'] = str(args.executable.resolve())
    sys.path.insert(0, str(ROOT/'tests'));import pty_smoke as tty
    original = tty._markers_visible;screens = {};terminals = []
    def visible(markers, data, columns, rows):
        screen = tty.VirtualScreen(columns, rows);screen.feed(bytes(data));text = screen.text()
        if markers == ('fan-control-capture',) or 'wtop-fixture' in text:
            screens[hashlib.sha256(text.encode()).hexdigest()] = text
        if markers == ('fan-control-capture',):return True
        return original(markers, data, columns, rows)
    tty._markers_visible = visible
    try:
        for columns, rows, locale, ascii_mode in [(100, 30, 'en-US', False), (80, 24, 'zh-CN', False), (100, 30, 'en-US', True)]:
            screens.clear()
            script = [(('sleep', 2), None), (b'h', None), (('sleep', .5), ('fan-control-capture',))]
            for _ in range(7):script.extend([(b'\x1b[6~', None), (('sleep', .2), ('fan-control-capture',))])
            script.extend([(b'\x1b', None), (b'2', None), (('sleep', .3), ('Command',) if locale == 'en-US' else ('命令',)), (b'q', None)])
            environment = {'TERM':'dumb','COLORTERM':None,'LANG':'C','LC_ALL':'C','LC_CTYPE':'C'} if ascii_mode else None
            raw = tty.run_session(columns, rows, exercise=False, cli_options=('--lang', locale, '--no-color'),
                                  terminal_environment=environment, script=script)
            stem = 'fan-control-'+str(columns)+'-'+locale+('-ascii' if ascii_mode else '')
            for suffix, body in [('.pty', raw), ('-screens.json', json.dumps(screens, ensure_ascii=False).encode())]:
                path = work/(stem+suffix);path.write_bytes(body);path.chmod(0o600)
            normalized = ' '.join(' '.join(screens.values()).split())
            for marker in ['pwm1', '[####----]', '50.2%', '25000', 'temp1, temp3']:
                if marker == '25000':assert re.search(r'25(?:[.,]0+)?\s*kHz|25000', normalized)
                else:assert marker in normalized, (locale, marker)
            assert ('Driver settings' if locale == 'en-US' else '驱动控制设置') in normalized
            if ascii_mode:assert all(byte < 128 for byte in raw)
            terminals.append(dict(columns=columns, rows=rows, locale=locale, ascii=ascii_mode,
                                  pty_sha256=hashlib.sha256(raw).hexdigest()))
    finally:tty._markers_visible = original;os.environ.clear();os.environ.update(saved)
    path = work/'FAN-CONTROL-application-acceptance.json'
    path.write_text(json.dumps(dict(status='passed',scope='software hwmon fixture through production reader/CLI/TUI; not physical fan verification',
        CLI_sha256=receipts,TTY=terminals),indent=2)+'\n');path.chmod(0o600)
    print('FAN_CONTROL_APPLICATION_PASSED:readonly settings through worker,4CLI modes/4stream frames,English/Chinese/ASCII terminals and separate RPM semantics',flush=True)

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
                           'temp1_input':'42000\n','temp1_crit':'95000\n',
                           'fan1_input':'1600\n','pwm1':'128\n','pwm1_enable':'1\n',
                           'pwm1_mode':'1\n','pwm1_freq':'25000\n','pwm1_auto_channels_temp':'5\n'}.items():
            (device/name).write_text(value)
        control=directory/'control'; control.write_text('0\n'); entered=directory/'entered'
        supply_root=directory/'power-supplies';supply_device=supply_root/'USB0';supply_device.mkdir(parents=True)
        for name,value in {'type':'USB','online':'1','usb_type':'C [PD] PD_PPS',
                           'power_now':'60000000','input_power_limit':'80000000'}.items():
            (supply_device/name).write_text(value+'\n')
        supply_control=directory/'supply-control';supply_control.write_text('0\n')
        supply_entered=directory/'supply-entered'
        power=directory/'power'; zone=power/'intel-rapl:0';zone.mkdir(parents=True)
        (power/'intel-rapl').mkdir();(power/'intel-rapl'/'enabled').write_text('1\n')
        for name,value in {'name':'package-0\n','energy_uj':'1000000\n',
                           'max_energy_range_uj':'1000000000\n','enabled':'1\n',
                           'constraint_0_name':'long_term\n','constraint_0_power_limit_uw':'25000000\n'}.items():
            (zone/name).write_text(value)
        firmware=directory/'firmware';firmware.mkdir()
        def record(kind,handle,body,strings=()):
            return bytes([kind,len(body)+4])+handle.to_bytes(2,'little')+body+b'\0'.join(strings)+b'\0\0'
        def probe(kind, handle, nominal, description):
            body = bytearray(18)
            body[0:2] = bytes([1, 0x63])
            for offset in [2, 4, 6, 8, 10]:
                body[offset:offset+2] = b'\x00\x80'
            body[16:18] = nominal.to_bytes(2, 'little', signed=True)
            return record(kind, handle, body, [description])
        (firmware/'DMI').write_bytes(record(10,0x1000,bytes([133,1]),[b'Firmware Ethernet'])
            +record(8,0x0800,bytes([1,0,2,18,16]),[b'Internal',b'USB'])
            +probe(26,0x2600,12000,b'Firmware input rail')
            +probe(28,0x2800,-55,b'Firmware inlet temperature')
            +probe(29,0x2900,2500,b'Firmware input current')
            +record(27,0x2700,b'\x00\x28\x63\x00'+bytes(4)+b'\x40\x06\x01',[b'Firmware fan'])
            +record(127,0xffff,b''))
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
        env.update(WTOP_SUPPLY_FIXTURE_ROOT=str(supply_root),WTOP_SUPPLY_FIXTURE_CONTROL=str(supply_control),
                   WTOP_SUPPLY_FIXTURE_ENTERED=str(supply_entered))
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/hardware_worker_smoke.lua'),
                        str(ROOT),str(control),str(entered),str(power)],cwd=ROOT,env=env,check=True,timeout=35)
        cppc_root=directory/'cppc';cppc_cpu=cppc_root/'cpu0/acpi_cppc';cppc_cpu.mkdir(parents=True)
        (cppc_root/'online').write_text('0\n')
        for key,value in {'highest_perf':196,'nominal_perf':150,'lowest_nonlinear_perf':80,
                          'lowest_perf':10,'guaranteed_perf':0,'reference_perf':165,
                          'nominal_freq':3300,'lowest_freq':0}.items():
            (cppc_cpu/key).write_text(str(value)+'\n')
        cppc_control=directory/'cppc-control';cppc_control.write_text('0\n')
        cppc_entered=directory/'cppc-entered'
        cppc_env={**env,'WTOP_CPPC_FIXTURE_CONTROL':str(cppc_control),'WTOP_CPPC_FIXTURE_ENTERED':str(cppc_entered)}
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/cppc_worker_smoke.lua'),
                        str(ROOT),str(cppc_root),str(cppc_control),str(cppc_entered)],
                       cwd=ROOT,env=cppc_env,check=True,timeout=25)
        typec_env={**env,**typec_fixture(args.lua_prefix,directory)}
        subprocess.run([str(args.lua_prefix.resolve()/'bin/lua'),str(ROOT/'tests/native/typec_worker_smoke.lua'),
                        str(ROOT),typec_env['WTOP_TYPEC_FIXTURE_CONTROL'],typec_env['WTOP_TYPEC_FIXTURE_ENTERED']],
                       cwd=ROOT,env=typec_env,check=True,timeout=25)
        if not args.native_only:
            verify_typec_application(args, typec_env, work)
            verify_supply_input_application(args, env, work)
            verify_fan_control_application(args, env, work)
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
