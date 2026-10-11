#!/usr/bin/env python3
"""Exercise pinned installer reuse and repair without network or LuaRocks."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile


def write(path, content, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content.encode())
    if executable:
        path.chmod(0o755)


def main():
    original = Path("tools/bootstrap_luainstaller.sh").read_text()
    version = re.search(r"^luainstaller_version=(\S+)$", original, re.M).group(1)
    release = version.rsplit("-", 1)[0]
    source = "official source fixture\n"
    source_hash = hashlib.sha256(source.encode()).hexdigest()
    script, replacements = re.subn(r"^source_sha256=[0-9a-f]{64}$",
                                  "source_sha256=" + source_hash, original, flags=re.M)
    assert replacements == 1, "fixture must replace only the pinned input digest"
    with tempfile.TemporaryDirectory(prefix="wtop-installer-") as directory:
        root = Path(directory)
        bootstrap = root / "tools/bootstrap_luainstaller.sh"
        write(bootstrap, script, True)
        write(root / "tools/check_resources.sh", "#!/bin/sh\nexit 0\n", True)
        write(root / ".tools/lua-5.5.1/bin/lua", "#!/bin/sh\nexit 0\n", True)
        rockspec = 'version = "' + version + '"\n'
        payload = "return 'verified payload'\n"
        write(root / "fixture.rockspec", rockspec)
        write(root / "payload.lua", payload)
        cached_source = root / (".tools/downloads/luainstaller-" + version + ".src.rock")
        write(cached_source, source)
        installed_spec = ("lib/luarocks/rocks-5.5/luainstaller/" + version
                          + "/luainstaller-" + version + ".rockspec")
        installed_payload = "share/lua/5.5/luainstaller/cli.lua"
        manifest = "".join(hashlib.sha256(content.encode()).hexdigest() + "  " + path + "\n"
                           for path, content in [(installed_spec, rockspec),
                                                 (installed_payload, payload)])
        write(root / ("tools/luainstaller-" + release + ".sha256"), manifest)
        fake_rocks = '''#!/bin/sh
set -eu
root=$WTOP_TEST_BOOTSTRAP_ROOT
tree=
for arg do
    case "$arg" in --tree=*) tree=${arg#--tree=} ;; esac
done
test -n "$tree"
printf 'install\n' >> "$root/calls"
mkdir -p "$tree/share/lua/5.5/luainstaller" "$tree/bin" "$tree/<SPEC_DIR>"
cp "$root/payload.lua" "$tree/share/lua/5.5/luainstaller/cli.lua"
cp "$root/fixture.rockspec" "$tree/<SPEC>"
printf '#!/bin/sh\nexit 0\n' > "$tree/bin/luai"
chmod +x "$tree/bin/luai"
'''.replace("<SPEC_DIR>", str(Path(installed_spec).parent)).replace("<SPEC>", installed_spec)
        write(root / ".tools/luarocks/bin/luarocks", fake_rocks, True)
        environment = os.environ.copy()
        environment.pop("WTOP_LUAINSTALLER_ROCKSPEC", None)
        environment["WTOP_TEST_BOOTSTRAP_ROOT"] = str(root)

        def run(success=True, override=None):
            settings = environment.copy()
            if override is not None:
                settings["WTOP_LUAINSTALLER_ROCKSPEC"] = override
            result = subprocess.run(["sh", str(bootstrap)], env=settings,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            assert (result.returncode == 0) == success, result.stdout.decode()
            return result.stdout.decode()

        def installs():
            return len((root / "calls").read_text().splitlines())

        run()
        assert installs() == 1
        run()
        assert installs() == 1, "verified installation must be reused"
        protected = root / ".tools/rocks-5.5" / installed_payload
        write(protected, "corrupted installed module\n")
        run()
        assert installs() == 2 and protected.read_text() == payload
        write(protected, "corrupted installed module\n")
        write(cached_source, "untrusted source\n")
        run(False)
        assert installs() == 2, "source verification must precede installer execution"
        write(cached_source, source)
        run()
        assert installs() == 3
        assert "absolute path" in run(False, "relative.rockspec")
        wrong = root / "wrong.rockspec"
        write(wrong, 'version = "0.0.0-1"\n')
        assert "must declare version" in run(False, str(wrong))
        assert installs() == 3
        write(root / ".tools/rocks-5.5/bin/luai", "#!/bin/sh\nexit 1\n", True)
        run()
        assert installs() == 4, "unusable command must be repaired despite matching modules"
    print("luainstaller bootstrap: reuse, repair, source integrity and overrides passed")


if __name__ == "__main__":
    main()
