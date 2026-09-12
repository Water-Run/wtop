SHELL := /bin/sh

HOST_OS := $(shell uname -s 2>/dev/null || echo unknown)
ifneq ($(HOST_OS),Linux)
$(error wtop supports Linux only (detected $(HOST_OS)))
endif

LUA_VERSION := 5.5.1
LUA_PREFIX := $(CURDIR)/.tools/lua-$(LUA_VERSION)
LUA := $(LUA_PREFIX)/bin/lua
LUAC := $(LUA_PREFIX)/bin/luac
LUAI := $(CURDIR)/.tools/rocks-5.5/bin/luai
LUA_STAMP := $(LUA_PREFIX)/.wtop-ready
LUAI_STAMP := $(CURDIR)/.tools/rocks-5.5/.wtop-ready
# The distribution LuaRocks is too old to target Lua 5.5, so the packaging
# path uses a pinned build rather than whatever the host happens to have.
LUAROCKS_PREFIX := $(CURDIR)/.tools/luarocks
LUAROCKS := $(LUAROCKS_PREFIX)/bin/luarocks
LUAROCKS_STAMP := $(LUAROCKS_PREFIX)/.wtop-ready
CC ?= cc

ROCKSPEC := wtop-scm-1.rockspec
ROCK_BUILD_DIR := $(CURDIR)/build/luarocks
ROCK_NATIVE_MODULE := $(ROCK_BUILD_DIR)/wtop_native.so
WTOP_ROCK_TREE ?= $(CURDIR)/.tools/wtop-rocks-5.5

NATIVE_DIR := $(CURDIR)/build/native
NATIVE_MODULE := $(NATIVE_DIR)/wtop_native.so
LUA_PATH_DEV := $(CURDIR)/src/?.lua;$(CURDIR)/src/?/init.lua;;
LUA_CPATH_DEV := $(NATIVE_DIR)/?.so;;
TEST_FILES := $(sort $(wildcard tests/unit/test_*.lua tests/integration/test_*.lua))
LOCALE_SOURCES := $(sort $(wildcard src/wtop/generated/locales/*.lua))
LOCALE_INCLUDES := $(foreach file,$(LOCALE_SOURCES),--include $(file))

FUZZ_SEEDS ?= 20

CFLAGS_NATIVE ?= -O2 -g0
CFLAGS_NATIVE += -std=c17 -fPIC -Wall -Wextra -Werror

.NOTPARALLEL: all native locales check test test-all test-fast test-54 test-55 test-pty test-pty-quick test-luarocks \
	toolchain luainstaller luarocks-bootstrap luarocks-install bundle-dir bundle-file \
	test-bundle-dir test-bundle-file

.PHONY: all resource-check resource-check-full toolchain luainstaller native locales check test test-all test-fast \
	test-54 test-55 test-pty test-pty-quick test-fuzz run \
	diagnose snapshot bundle-dir bundle-file test-bundle-dir test-bundle-file checksums \
	rock-build rock-install rockspec-check luarocks-bootstrap luarocks-install test-luarocks

all: native locales

resource-check:
	@./tools/check_resources.sh test

resource-check-full:
	@./tools/check_resources.sh full

toolchain: $(LUA_STAMP)

luarocks-bootstrap: $(LUAROCKS_STAMP)

luainstaller: $(LUAI_STAMP)

native: resource-check $(NATIVE_MODULE)

$(LUA_STAMP): tools/bootstrap_lua.sh
	@./tools/bootstrap_lua.sh >/dev/null
	@touch $@

$(LUAROCKS_STAMP): tools/bootstrap_luarocks.sh $(LUA_STAMP)
	@./tools/bootstrap_luarocks.sh >/dev/null
	@touch $@

$(LUAI_STAMP): tools/bootstrap_luainstaller.sh $(LUA_STAMP)
	@./tools/bootstrap_luainstaller.sh >/dev/null
	@touch $@

$(NATIVE_MODULE): native/wtop_native.c Makefile $(LUA_STAMP)
	@mkdir -p $(NATIVE_DIR)
	@$(CC) $(CFLAGS_NATIVE) -shared -I$(LUA_PREFIX)/include -o $@ $<

locales: resource-check $(LUA_STAMP)
	@if [ -f tools/compile_locales.lua ]; then \
		LUA_PATH='$(LUA_PATH_DEV)' $(LUA) tools/compile_locales.lua >/dev/null; \
	fi

check: resource-check native locales
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUAC) -p $$(find src tools tests -type f -name '*.lua' -print)
	@sh -n tools/*.sh
	@python3 -c 'import pathlib; [compile(path.read_bytes(), str(path), "exec") for path in pathlib.Path("tests").rglob("*.py")]'
	@python3 -c 'import json; json.load(open("docs/agent-v1.schema.json", encoding="utf-8"))'

test: resource-check-full test-55 test-pty

# Release-style validation: both Lua ABIs, source PTY, LuaRocks, and both
# luainstaller artifact forms. Every prerequisite remains serial and gated.
test-all: resource-check-full check test-54 test-55 test-pty rockspec-check \
	test-luarocks test-bundle-dir test-bundle-file

# Short feedback loop: isolated Lua files plus a representative PTY subset.
test-fast: resource-check test-55 test-pty-quick

test-55: resource-check native locales
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUA) tests/run.lua $(TEST_FILES)

test-54: resource-check
	@lua -e 'assert(_VERSION == "Lua 5.4", "test-54 requires Lua 5.4, got " .. _VERSION)'
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH=';;' lua tests/run.lua $(TEST_FILES)

test-pty: resource-check-full native locales
	@WTOP_LUA='$(LUA)' WTOP_ROOT='$(CURDIR)' python3 tests/pty_smoke.py

test-pty-quick: resource-check native locales
	@WTOP_PTY_PROFILE=quick WTOP_LUA='$(LUA)' WTOP_ROOT='$(CURDIR)' python3 tests/pty_smoke.py

# Random input against the real terminal loop.  Kept out of `test` because it
# is slow and non-deterministic by design; CI runs it on every push.
test-fuzz: resource-check native locales
	@WTOP_LUA='$(LUA)' WTOP_ROOT='$(CURDIR)' python3 tests/fuzz_tui.py --seeds $(FUZZ_SEEDS)

run: native locales
	@LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUA) src/wtop.lua

diagnose: native locales
	@LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUA) src/wtop.lua --diagnose

snapshot: native locales
	@LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUA) src/wtop.lua --snapshot

# rock-build and rock-install are the LuaRocks "make" backend entry points.
# End users should invoke LuaRocks (or luarocks-install), not these targets directly.
rock-build: resource-check
	@test -n "$(LUA_INCDIR)" || { echo "wtop: LUA_INCDIR is required" >&2; exit 1; }
	@mkdir -p "$(ROCK_BUILD_DIR)"
	$(CC) $(CFLAGS) -std=c17 -fPIC -Wall -Wextra -Werror -shared \
		-I"$(LUA_INCDIR)" -o "$(ROCK_NATIVE_MODULE)" native/wtop_native.c

rock-install:
	@test -f "$(ROCK_NATIVE_MODULE)" || { echo "wtop: run the rock build pass first" >&2; exit 1; }
	@test -n "$(PREFIX)" -a -n "$(LUADIR)" -a -n "$(LIBDIR)" -a -n "$(BINDIR)" || \
		{ echo "wtop: LuaRocks install directories are required" >&2; exit 1; }
	@mkdir -p "$(LUADIR)/wtop" "$(LIBDIR)" "$(BINDIR)" "$(PREFIX)/doc"
	@cp -R src/wtop/. "$(LUADIR)/wtop/"
	@cp "$(ROCK_NATIVE_MODULE)" "$(LIBDIR)/wtop_native.so"
	@cp src/wtop.lua "$(BINDIR)/wtop"
	@chmod 755 "$(BINDIR)/wtop" "$(LIBDIR)/wtop_native.so"
	@cp LICENSE README.md README-zh.md config.example.yml "$(PREFIX)/doc/"

rockspec-check: $(LUAROCKS_STAMP)
	@"$(LUAROCKS)" lint "$(ROCKSPEC)"

luarocks-install: resource-check-full $(LUA_STAMP) $(LUAROCKS_STAMP)
	"$(LUAROCKS)" --lua-version=5.5 --lua-dir="$(LUA_PREFIX)" --tree="$(WTOP_ROCK_TREE)" \
		make "$(ROCKSPEC)" --deps-mode=none --force

test-luarocks: luarocks-install
	@"$(WTOP_ROCK_TREE)/bin/wtop" --version | grep -qx 'wtop 0.1.0-dev'
	@"$(WTOP_ROCK_TREE)/bin/wtop" --diagnose | grep -q 'Platform: Linux'
	@"$(WTOP_ROCK_TREE)/bin/wtop" --snapshot | python3 tests/json_contract_smoke.py snapshot
	@"$(WTOP_ROCK_TREE)/bin/wtop" --agent | python3 tests/json_contract_smoke.py agent

bundle-dir: native locales $(LUAI_STAMP)
	mkdir -p dist
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUAI) -b --dir \
		src/wtop.lua -o dist/wtop --lua '$(LUA)' --lua-prefix '$(LUA_PREFIX)' \
		--target-os linux --max-deps 300 $(LOCALE_INCLUDES) -- --version
	@find dist/wtop -type d -exec chmod 0755 {} +
	@find dist/wtop -type f -exec chmod a+r {} +
	@chmod 0755 dist/wtop/wtop
	@find dist/wtop/.luai/native -type f -exec chmod 0755 {} +

bundle-file: native locales $(LUAI_STAMP)
	mkdir -p dist
	rm -f dist/.wtop-onefile.next
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUAI) -b --file \
		src/wtop.lua -o dist/.wtop-onefile.next --lua '$(LUA)' --lua-prefix '$(LUA_PREFIX)' \
		--target-os linux --max-deps 300 $(LOCALE_INCLUDES) -- --version
	mv -f dist/.wtop-onefile.next dist/wtop-onefile

test-bundle-dir: resource-check-full bundle-dir
	@test -z "$$(find dist/wtop -type d ! -perm -005 -print -quit)"
	@test -z "$$(find dist/wtop -type f ! -perm -004 -print -quit)"
	@test -x dist/wtop/wtop
	@WTOP_EXECUTABLE='$(CURDIR)/dist/wtop/wtop' WTOP_ROOT='$(CURDIR)' python3 tests/pty_smoke.py

test-bundle-file: resource-check-full bundle-file
	@WTOP_EXECUTABLE='$(CURDIR)/dist/wtop-onefile' WTOP_ROOT='$(CURDIR)' python3 tests/pty_smoke.py

checksums:
	@test -x dist/wtop/wtop && test -x dist/wtop-onefile
	@cd dist && sha256sum wtop/wtop wtop-onefile > SHA256SUMS
