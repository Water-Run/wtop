#!/usr/bin/env python3
"""Build/run Windows Sysman ABI, power and reader lifecycle fixtures."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def build(runtime: Path, output: Path, sdk_root: Path | None) -> None:
    output.mkdir(parents=True, exist_ok=False)
    flags = ['-std=c17', '-O2', '-Wall', '-Wextra', '-Werror', '-static-libgcc']
    versions = json.loads((ROOT / 'tests/fixtures/levelzero/versions.json').read_text())
    if sdk_root:
        for item in versions:
            assert hashlib.sha256((sdk_root / item['tag'] / item['file']).read_bytes()).hexdigest() == item['sha256']
    for arch, compiler, version in [('x86', 'i686-w64-mingw32-gcc', 1), ('x64', 'x86_64-w64-mingw32-gcc', 2)]:
        obj = output / ('sdk-' + arch + '.o')
        subprocess.run([compiler, *flags, '-DWTOP_GPU_WORKER', '-include',
                        str(ROOT / 'tests/native/windows_levelzero_paths.h'), '-c',
                        str(ROOT / 'native/wtop_levelzero.c'), '-o', str(obj)], check=True)
        subprocess.run([compiler, *flags, '-s', '-municode', '-DWTOP_GPU_WORKER', '-DWTOP_WINDOWS_LEVELZERO',
                        f'-Wl,--no-insert-timestamp,--major-os-version,5,--minor-os-version,{version},--major-subsystem-version,5,--minor-subsystem-version,{version}',
                        str(ROOT / 'native/wtop_windows_nvml_helper.c'), str(obj),
                        '-o', str(output / ('reader-' + arch + '.exe'))], check=True)
        for tag in ['v1.5.0', 'v1.34.0']:
            folder = output / ('sdk-' + arch + '-' + tag) / 'system'
            folder.mkdir(parents=True)
            definitions = ['-DWTOP_LEVELZERO_LEGACY'] if tag == 'v1.5.0' else []
            if sdk_root:
                definitions += ['-DWTOP_LEVELZERO_SDK_HEADER="' + str((sdk_root / tag / 'zes_api.h').resolve()) + '"']
            subprocess.run([compiler, *flags, '-shared', '-Wl,--export-all-symbols', *definitions,
                            str(ROOT / 'tests/native/levelzero_fake.c'),
                            str(ROOT / 'tests/native/levelzero_layout.c'), '-o', str(folder / 'ze_loader.dll')], check=True)
    subprocess.run([sys.executable, str(ROOT / 'tools/embed_cpuid_helpers.py'), '--kind', 'levelzero',
                    '--x86', str(output / 'reader-x86.exe'), '--x64', str(output / 'reader-x64.exe'),
                    '--output', str(output / 'wtop_levelzero_helpers.h')], check=True)
    includes = ['-I' + str(output), '-I' + str(runtime / 'include'),
                '-I' + str(ROOT / 'build/native'), '-I' + str(ROOT / 'build/windows-x86')]
    worker = output / 'worker.o'
    subprocess.run(['i686-w64-mingw32-gcc', *flags, *includes, '-include',
                    str(ROOT / 'tests/native/windows_nvml_arch.h'), '-c',
                    str(ROOT / 'native/wtop_windows_worker.c'), '-o', str(worker)], check=True)
    (output / 'fixture').mkdir()
    units = ['wtop_windows.c', 'wtop_windows_net.c', 'wtop_windows_hw.c',
             'wtop_windows_cpu.c', 'wtop_windows_disk.c', 'wtop_windows_cpuid.c']
    subprocess.run(['i686-w64-mingw32-gcc', *flags, *includes, '-shared',
                    *[str(ROOT / 'native' / name) for name in units], str(worker),
                    str(runtime / 'liblua55.dll.a'), '-lpsapi', '-liphlpapi', '-lsetupapi',
                    '-o', str(output / 'fixture/wtop_native.dll')], check=True)
    subprocess.run(['i686-w64-mingw32-gcc', *flags,
                    str(ROOT / 'tests/native/windows_process_reaped.c'),
                    '-o', str(output / 'process-reaped.exe')], check=True)
    for name in ['lua.exe', 'lua55.dll']:
        shutil.copyfile(runtime / name, output / name)
    shutil.copytree(ROOT / 'src', output / 'src')
    for source, name in [('windows_levelzero_cases.lua', 'cases.lua'), ('windows_levelzero_cache.lua', 'cache.lua'),
                         ('windows_levelzero_lifecycle.lua', 'lifecycle.lua')]:
        shutil.copyfile(ROOT / 'tests/native' / source, output / name)
    with zipfile.ZipFile(output.with_suffix('.zip'), 'x', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(output.rglob('*')):
            if path.is_file() and path.suffix not in ['.o', '.h']:
                archive.write(path, path.relative_to(output).as_posix())
    print('Windows Level Zero fixture archive built', flush=True)


def run(folder: Path) -> None:
    assert os.name == 'nt', 'run prepared fixtures on Windows'
    rows = []
    modes = [0, 2, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19, 20, 24, 25, 40, 41, 42, 43, 44, 46, 49]
    for bits, arch in [(32, 'x86'), (64, 'x64')]:
        profile = folder / 'profiles' / str(bits)
        profile.mkdir(parents=True)
        for tag in ['v1.34.0', 'v1.5.0']:
            for mode in modes:
                env = {**os.environ, 'LUA_PATH': str(folder / 'src/?.lua') + ';' + str(folder / 'src/?/init.lua') + ';;',
                       'LUA_CPATH': str(folder / 'fixture/?.dll') + ';;', 'APPDATA': str(profile),
                       'WTOP_LEVELZERO_TEST_ROOT': str(folder / ('sdk-' + arch + '-' + tag)),
                       'WTOP_NVML_TEST_BITS': str(bits), 'WTOP_LEVELZERO_FIXTURE_MODE': str(mode)}
                result = subprocess.run([str(folder / 'lua.exe'), str(folder / 'cases.lua')], env=env,
                                        capture_output=True, timeout=12)
                log = folder / f'case-{bits}-{tag}-{mode}.log'
                log.write_bytes(result.stdout + result.stderr)
                assert result.returncode == 0, log
                assert b'driver noise' not in result.stdout and b'driver stderr' not in result.stderr
                match = re.search(rb'^LEVELZERO_MATRIX_RESULT (.+)$', result.stdout, re.M)
                assert match, log
                row = json.loads(match[1]); row.update(bits=bits, sdk=tag); rows.append(row)
            print('Windows Level Zero', bits, tag, 'ABI/energy/cap/fault cases passed', flush=True)
        body = (folder / ('reader-' + arch + '.exe')).read_bytes()
        checksum = 2166136261
        for byte in body:
            checksum = ((checksum ^ byte) * 16777619) & 0xffffffff
        env.update(WTOP_LEVELZERO_TEST_ROOT=str(folder / ('sdk-' + arch + '-v1.34.0')),
                   WTOP_LEVELZERO_FIXTURE_MODE='0',
                   WTOP_LEVELZERO_CACHE_IMAGE=str(profile / 'wtop/readers' / f'levelzero-x{bits}-{checksum:08x}.exe'),
                   WTOP_LEVELZERO_EXPECT_IMAGE=str(folder / ('reader-' + arch + '.exe')))
        result = subprocess.run([str(folder / 'lua.exe'), str(folder / 'cache.lua')], env=env,
                                capture_output=True, timeout=15)
        log = folder / ('cache-' + str(bits) + '.log'); log.write_bytes(result.stdout + result.stderr)
        assert result.returncode == 0, log
        print('Windows Level Zero', bits, 'cache/quota/corruption/recovery passed', flush=True)
        for mode in ['warm', 'quit']:
            case = folder / ('lifecycle-' + str(bits) + '-' + mode)
            case.mkdir(); (case / 'profile').mkdir()
            env.update(APPDATA=str(case / 'profile'),
                       WTOP_LEVELZERO_LIFECYCLE_MARKER=str(case / 'reader'),
                       WTOP_LEVELZERO_FIXTURE_CONTROL=str(case / 'control'))
            started = time.monotonic()
            result = subprocess.run([str(folder / 'lua.exe'), 'lifecycle.lua', mode], cwd=folder,
                                    env=env, capture_output=True, timeout=25)
            log = case / 'parent.log'; log.write_bytes(result.stdout + result.stderr)
            assert result.returncode == (19 if mode == 'quit' else 0), log
            if mode == 'quit':
                marker = json.loads((case / 'reader.blocked').read_text())
                checked = subprocess.run([str(folder / 'process-reaped.exe'), str(marker['pid']),
                                          marker['birth'], '1000'], capture_output=True, timeout=5)
                (case / 'reap.log').write_bytes(checked.stdout + checked.stderr)
                checked.check_returncode()
                assert time.monotonic() - started < 9, "parent exit exceeded blocked API lease"
            print('Windows Level Zero', bits, mode, 'API lifecycle passed', flush=True)
    (folder / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--runtime', type=Path, default=ROOT / 'dist/windows-x86')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sdk-root', type=Path)
    args = parser.parse_args()
    if args.build:
        build(args.runtime.resolve(), args.output.resolve(), args.sdk_root.resolve() if args.sdk_root else None)
    else:
        run(args.output.resolve())


if __name__ == '__main__':
    main()
