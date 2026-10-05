SHELL := /bin/sh

HOST_OS := $(shell uname -s 2>/dev/null || echo unknown)
ifeq ($(HOST_OS),Darwin)

.PHONY: all native run snapshot diagnose
all: native
native:
	@./tools/build_macos.sh
run: native
	@./dist/macos/wtop
snapshot: native
	@./dist/macos/wtop --snapshot
diagnose: native
	@./dist/macos/wtop --diagnose

else
ifneq ($(HOST_OS),Linux)
$(error wtop build supports Linux and macOS (detected $(HOST_OS)))
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

NATIVE_SOURCES := native/wtop_native.c native/wtop_nvml.c native/wtop_amdsmi.c \
  native/wtop_levelzero.c
NATIVE_HEADERS := native/wtop_nvml.h native/wtop_amdsmi.h native/wtop_levelzero.h
NATIVE_DIR := $(CURDIR)/build/native
NATIVE_MODULE := $(NATIVE_DIR)/wtop_native.so
NATIVE_REVISION_HEADER := $(NATIVE_DIR)/build_revision.h
NATIVE_VERSION_HEADER := $(NATIVE_DIR)/build_version.h
LUA_PATH_DEV := $(CURDIR)/src/?.lua;$(CURDIR)/src/?/init.lua;;
LUA_CPATH_DEV := $(NATIVE_DIR)/?.so;;
TEST_FILES := $(sort $(wildcard tests/unit/test_*.lua tests/integration/test_*.lua))
LOCALE_SOURCES := $(sort $(wildcard src/wtop/generated/locales/*.lua))
LOCALE_INCLUDES := $(foreach file,$(LOCALE_SOURCES),--include $(file))

# The project's own licence text is part of the release, not only of the
# repository.  luainstaller already ships the Lua, LGPL and GPL texts it is
# responsible for, and the SBOM declares EUPL-1.2 on both wtop components --
# but neither artifact form carried the text of that licence, so a
# re-distributor holding a complete, checksum-verified release had no file to
# read the project's own terms from.
#
# Only the onedir bundle gets it, and that asymmetry is measured rather than
# assumed.  Two things were tried and both refused, which is why the difference
# is stated rather than papered over.  `--include` is the packaging tool's only
# supported way to add a file, and it validates the path as Lua source:
# "Manual include must be a Lua source file".  Its notice set otherwise comes
# from a table inside the tool.  And the onedir tree cannot simply be given an
# extra file after the fact either -- luainstaller checks its output against an
# ownership marker and rejects unowned content at any depth -- so the tree is
# rebuilt from empty each time and the licence goes in last.  Rather than patch
# a third-party LGPL tool to carry our terms, the onedir carries the text as a
# file and the SBOM records, per licence, which artifact forms hold it, so a
# distributor sees the onefile gap instead of having to infer it.
RELEASE_LICENCE := LICENSE

# The integrity manifest covers the two entry points and every licence or
# notice file the onedir bundle carries, not only the programs.  A release
# whose SHA256SUMS covers the executables and not the terms they ship under
# verifies green while those terms can be deleted or replaced, and the gate in
# docs/PLAN.md names the notices as release artifacts in their own right.  The
# list is discovered rather than written down, so a notice the packaging tool
# starts shipping is covered without an edit here -- and the result is checked
# for emptiness, because a find that matches nothing would otherwise produce a
# perfectly valid two-file manifest and report success, which is the defect
# this whole manifest exists to prevent, one level up.
RELEASE_NOTICE_FILES := \( -name '$(RELEASE_LICENCE)' -o -name '*NOTICE*' -o -path '*/licenses/*' \)

FUZZ_SEEDS ?= 20

CFLAGS_NATIVE ?= -O2 -g0
CFLAGS_NATIVE += -std=c17 -fPIC -Wall -Wextra -Werror

.NOTPARALLEL: all native locales check test test-all test-fast test-54 test-55 test-pty test-pty-quick test-luarocks \
	toolchain luainstaller luarocks-bootstrap luarocks-install bundle-dir bundle-file \
	test-bundle-dir test-bundle-file test-release-notices check-native-warnings \
	sanitize-native test-sanitized

.PHONY: all resource-check resource-check-full toolchain luainstaller native locales check test test-all test-fast \
	test-54 test-55 test-pty test-pty-quick benchmark test-fuzz run \
	diagnose snapshot bundle-dir bundle-file test-bundle-dir test-bundle-file checksums build-id sbom baseline \
	cross-libc release-baseline rock-build rock-install rockspec-check luarocks-bootstrap luarocks-install test-luarocks

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

# The build identity and the version are generated, not passed as flags, so that
# the revision and the version compiled into the module and the ones in the Lua
# tree come out of one run of one script.  Two independent readings could
# disagree between the moment one side is built and the moment the other is, and
# the two are compared against each other.
#
# VERSION is a prerequisite and not an afterthought: the script writes the
# revision header whether or not the version changed, so depending on it alone
# would leave a version bump rebuilding nothing.
$(NATIVE_REVISION_HEADER): tools/write_build_id.sh VERSION
	@mkdir -p $(NATIVE_DIR)
	@./tools/write_build_id.sh

# Written by the same invocation, immediately after the revision header, so it is
# never the older of the two.  The recipe re-runs the generator if it is missing
# rather than failing: the header is an output, and an output that was deleted
# should be rebuilt, not diagnosed.
$(NATIVE_VERSION_HEADER): $(NATIVE_REVISION_HEADER)
	@test -f $@ || ./tools/write_build_id.sh

$(NATIVE_MODULE): $(NATIVE_SOURCES) $(NATIVE_HEADERS) $(NATIVE_REVISION_HEADER) \
		$(NATIVE_VERSION_HEADER) Makefile $(LUA_STAMP)
	@mkdir -p $(NATIVE_DIR)
	@$(CC) $(CFLAGS_NATIVE) -shared -I$(NATIVE_DIR) -I$(LUA_PREFIX)/include \
		-o $@ $(NATIVE_SOURCES) -ldl

locales: resource-check $(LUA_STAMP)
	@if [ -f tools/compile_locales.lua ]; then \
		LUA_PATH='$(LUA_PATH_DEV)' $(LUA) tools/compile_locales.lua >/dev/null; \
	fi

# ---------------------------------------------------------------------------
# The native module built a second and third time, for two gates that both used
# to be shell commands in the CI workflow holding their own copy of the source
# list.  Both copies were shorter than NATIVE_SOURCES: they named
# wtop_native.c and wtop_nvml.c and left out wtop_amdsmi.c and
# wtop_levelzero.c.  All four compile cleanly under every flag below, so nothing
# was being worked around -- the two gates simply covered half the module, and
# neither said so.  The memory-safety one mattered more: the omitted files are
# the vendor backends, which reach AMD SMI and Level Zero through dlopen and
# dlsym rather than at link time, so they are the part of this module most able
# to get a pointer wrong and the only part the ASan/UBSan job never saw.
#
# A new .c file is now covered by both gates by being added to NATIVE_SOURCES,
# which is the one place the module's file list exists.  That is the same reason
# the ELF list moved into the baseline target and BASELINE_OUTPUT replaced a
# re-derived path list in two CI steps.

# Stricter than CFLAGS_NATIVE on purpose: this is the gate that says a new
# warning is rejected, and a list of the flags is the gate.
STRICT_NATIVE_CFLAGS := -std=c17 -fPIC -Wall -Wextra -Werror -Wshadow \
  -Wconversion -Wsign-conversion -Wpointer-arith -O2 -shared \
  -I$(NATIVE_DIR) -I$(LUA_PREFIX)/include

check-native-warnings: $(LUA_STAMP) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER)
	@$(CC) $(STRICT_NATIVE_CFLAGS) -o /dev/null $(NATIVE_SOURCES) -ldl
	@echo "wtop: $(words $(NATIVE_SOURCES)) native sources clean under: $(STRICT_NATIVE_CFLAGS)"

# The sanitized module is a separate file on purpose.  Overwriting
# $(NATIVE_MODULE) would leave a module newer than its own prerequisites, so the
# next `make native` would not rebuild it and the rest of the suite would run
# against an instrumented build it did not ask for.
SANITIZED_DIR := build/native-san
SANITIZED_MODULE := $(SANITIZED_DIR)/wtop_native.so
SANITIZER_CFLAGS := -std=c17 -fPIC -Wall -Wextra -Werror -O1 -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer

sanitize-native: $(LUA_STAMP) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER)
	@mkdir -p $(SANITIZED_DIR)
	@$(CC) $(SANITIZER_CFLAGS) -shared -I$(NATIVE_DIR) -I$(LUA_PREFIX)/include \
		-o $(SANITIZED_MODULE) $(NATIVE_SOURCES) -ldl

# The whole sanitized run lives here so the workflow does not have to know the
# module's path or the sanitizer policy.  The options are ours: leak detection
# is off because the process is a long-lived TUI whose reachable state at exit
# is not the question being asked, and both sanitizers halt on the first error
# so a run cannot report success past one.
#
# The three CLI invocations come first and are not redundant with the suite.
# They drive the real collection paths end to end against the instrumented
# module -- a full snapshot, the agent export, and the diagnostic report -- and
# the unit suite reaches only some of what they touch.  They were in the
# workflow and they stayed when the rest of the step moved here.
SAN_RUN_ENV := ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
	UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(SANITIZED_DIR)/?.so;;'

# tests/unit/test_benchmark_record.lua drives a real TUI and asserts on a
# three-second first-frame window.  Under ASan+UBSan that window is the one
# place in this run where a pass would depend on the sanitizer's overhead
# rather than on the code being checked, and the development host cannot run
# this target at all -- it has no sanitizer runtime installed -- so a flake
# introduced here would be invisible until CI.  It is excluded by name rather
# than by pattern, the reason is here rather than in a workflow, and the same
# file still runs instrumented in every other suite; only the child process it
# spawns is unmeasured.  A gate that emits a spurious failure teaches a team to
# re-run, which is worse than missing a real one.
SANITIZER_EXCLUDED := tests/unit/test_benchmark_record.lua

test-sanitized: resource-check $(LUA_STAMP) $(NATIVE_REVISION_HEADER) \
		$(NATIVE_VERSION_HEADER) sanitize-native
	@for mode in --snapshot --agent --diagnose; do \
		echo "wtop: sanitized $$mode"; \
		$(SAN_RUN_ENV) $(LUA) src/wtop.lua $$mode > /dev/null || exit 1; \
	done
	$(SAN_RUN_ENV) $(LUA) tests/run.lua \
		$(filter-out $(SANITIZER_EXCLUDED),$(TEST_FILES))

check: resource-check native locales
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUAC) -p $$(find src tools tests -type f -name '*.lua' -print)
	@sh -n tools/*.sh
	@python3 -c 'import pathlib; [compile(path.read_bytes(), str(path), "exec") for path in pathlib.Path("tests").rglob("*.py")]'
	@python3 -c 'import json; json.load(open("docs/agent-v1.schema.json", encoding="utf-8"))'
	@# Parsing the agent schema proves the schema is JSON.  It says nothing about
	@# the document --agent emits, so the next line applies it.  The CI job that
	@# runs this one is named "Syntax, schema and the full unit suite", and until
	@# this step existed the middle word was doing no work.
	@WTOP_LUA='$(LUA)' WTOP_NATIVE_DIR='$(NATIVE_DIR)' \
		$(LUA) tools/check_agent_schema.lua

test: resource-check-full test-55 test-pty

# Release-style validation: both Lua ABIs, source PTY, LuaRocks, both
# luainstaller artifact forms, and every release-evidence document.  The last
# clause is not redundant with the individual targets existing: `sbom` was
# absent from here while CI ran it, and a gate that runs somewhere other than
# where a person looks is how an SBOM spent a month describing nothing and
# reporting success.  Every prerequisite remains serial and gated.
test-all: resource-check-full check check-native-warnings test-54 test-55 test-pty \
	rockspec-check release-baseline sbom checksums test-release-notices \
	test-luarocks test-bundle-dir test-bundle-file
# `baseline` is deliberately absent, and it is the consequence of a decision
# rather than an oversight: it measures $(BASELINE_ELFS) -- the native module
# under build/ and the bootstrapped interpreter under .tools/, neither of which
# ships -- so the release floor is release-baseline's.  Leaving it here would
# have test-all produce a document the release does not contain, and the two
# gates in tests/unit/test_release_evidence.lua would then disagree about it:
# one says a CI job must not produce evidence nobody receives, the other says
# the build-host floor must never be published as release evidence.  `make
# baseline` still works, and still answers its own question for a build host.
# test-sanitized is deliberately not here: it needs the ASan and UBSan
# runtimes, which a build host is not required to have, and a gate that
# cannot run everywhere is a gate that only reports where someone
# remembered.  CI runs it; this does not pretend to.

# Short feedback loop: isolated Lua files plus a representative PTY subset.
test-fast: resource-check test-55 test-pty-quick

test-55: resource-check native locales
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUA) tests/run.lua $(TEST_FILES)

test-54: resource-check
	@lua -e 'assert(_VERSION == "Lua 5.4", "test-54 requires Lua 5.4, got " .. _VERSION)'
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH=';;' lua tests/run.lua $(TEST_FILES)

# The benchmark drives the development tree unless it is told which artifact to
# measure, and those are not the same program: on one host the bundle started
# 15% slower and held 25% more resident memory than the source tree.  The
# release gates in docs/PLAN.md ask about what ships, so the subject has to be
# selectable from here rather than only through an environment variable that
# appears in no document.  The tool records which subject it used in both its
# output and its JSON, so a result cannot be mistaken for the other kind.
#
#   make benchmark
#   make benchmark BENCH_EXECUTABLE=dist/wtop/wtop
#   make benchmark BENCH_EXECUTABLE=dist/wtop-onefile
BENCH_EXECUTABLE ?=
BENCH_ARGS ?=

benchmark: resource-check native locales
	@WTOP_LUA='$(LUA)' WTOP_ROOT='$(CURDIR)' \
		WTOP_BENCH_EXECUTABLE='$(BENCH_EXECUTABLE)' \
		python3 tools/perf_benchmark.py $(BENCH_ARGS)

test-pty: resource-check-full native locales
	@python3 tests/pty_scenario_ledger.py
	@WTOP_LUA='$(LUA)' WTOP_ROOT='$(CURDIR)' python3 tests/pty_smoke.py

test-pty-quick: resource-check native locales
	@WTOP_PTY_PROFILE=quick WTOP_LUA='$(LUA)' WTOP_ROOT='$(CURDIR)' python3 tests/pty_smoke.py

# Each PTY scenario on its own, in its own process.  Kept out of `test-pty`
# because it costs one process per scenario rather than one pass, and because a
# scenario that only passes inside the matrix has been hiding a real defect:
# `run_thread_drilldown` passed in the suite and failed 0 times out of 8 alone,
# because its assertion read the last line of an overlay that has to be
# scrolled to see.  The suite is the gate; this is the question the suite
# cannot answer, and it is cheap enough to run before a change that touches
# overlays rather than after one that trips over it.
test-pty-isolation: resource-check-full native locales
	@WTOP_PTY_ISOLATION=1 WTOP_LUA='$(LUA)' WTOP_ROOT='$(CURDIR)' python3 tests/pty_smoke.py

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
		-I"$(NATIVE_DIR)" -I"$(LUA_INCDIR)" -o "$(ROCK_NATIVE_MODULE)" \
		$(NATIVE_SOURCES) -ldl

rock-install:
	@test -f "$(ROCK_NATIVE_MODULE)" || { echo "wtop: run the rock build pass first" >&2; exit 1; }
	@test -n "$(PREFIX)" -a -n "$(LUADIR)" -a -n "$(LIBDIR)" -a -n "$(BINDIR)" || \
		{ echo "wtop: LuaRocks install directories are required" >&2; exit 1; }
	@mkdir -p "$(LUADIR)/wtop" "$(LIBDIR)" "$(BINDIR)" "$(PREFIX)/doc"
	@cp -R src/wtop/. "$(LUADIR)/wtop/"
	@cp "$(ROCK_NATIVE_MODULE)" "$(LIBDIR)/wtop_native.so"
	@cp src/wtop.lua "$(BINDIR)/wtop"
	@chmod 755 "$(BINDIR)/wtop" "$(LIBDIR)/wtop_native.so"
	@cp LICENSE README.md README-zh.md README-fr.md README-ru.md config.example.yml "$(PREFIX)/doc/"

rockspec-check: $(LUAROCKS_STAMP)
	@"$(LUAROCKS)" lint "$(ROCKSPEC)"

luarocks-install: resource-check-full $(LUA_STAMP) $(LUAROCKS_STAMP)
	"$(LUAROCKS)" --lua-version=5.5 --lua-dir="$(LUA_PREFIX)" --tree="$(WTOP_ROCK_TREE)" \
		make "$(ROCKSPEC)" --deps-mode=none --force

test-luarocks: luarocks-install
	@"$(WTOP_ROCK_TREE)/bin/wtop" --version | grep -qx 'wtop 0.1.0'
	@"$(WTOP_ROCK_TREE)/bin/wtop" --diagnose | grep -q 'Platform: Linux'
	@"$(WTOP_ROCK_TREE)/bin/wtop" --snapshot | python3 tests/json_contract_smoke.py snapshot
	@"$(WTOP_ROCK_TREE)/bin/wtop" --agent | python3 tests/json_contract_smoke.py agent

build-id: $(NATIVE_REVISION_HEADER)
	@./tools/write_build_id.sh

# Both artifact forms are named because both are shipped, and neither is a child
# of the other.  The target used to depend on bundle-dir alone and pass a
# `dist/bundle-dir` that no rule has ever produced, so the generator found no
# files and wrote a complete CycloneDX document with no hashes and exit 0.
sbom: bundle-dir bundle-file
	@python3 tools/make_sbom.py --onedir dist/wtop --onefile dist/wtop-onefile \
		--output dist/SBOM.cyclonedx.json

# The release gate reads the glibc floor off every ELF the bundle ships and
# fails when one of them needs more than tools/baseline.conf promises.  The
# interpreter is named here rather than defaulted inside the script because it,
# not the native module, sets the floor: the module tops out at 2.34 while PUC
# Lua 5.5.1's math library asks for 2.38.
BASELINE_ELFS := $(NATIVE_MODULE) $(LUA)

# The output path is a parameter rather than a constant in the recipe, for the
# same reason the ELF list is an argument rather than a default: a caller that
# wants the evidence under a different name -- the aarch64 runner wants its own
# so an artifact says which host produced it -- must not have to re-derive which
# files to measure.  Two CI steps used to call tools/record_baseline.sh directly
# with no arguments, which has been a usage error since the ELF list became
# required, and the shell redirect left a zero-byte document behind for the
# release job to upload.
BASELINE_OUTPUT ?= dist/BASELINE.txt

baseline: native toolchain
	@mkdir -p $(dir $(BASELINE_OUTPUT))
	@./tools/record_baseline.sh $(BASELINE_ELFS) > $(BASELINE_OUTPUT)
	@echo "wtop: baseline evidence written to $(BASELINE_OUTPUT)"

# The build outputs are not what ships.  The onedir bundle carries its own
# executable, produced by luainstaller, that no earlier target inspects, and a
# gate that only reads the module it happened to build cannot speak for a
# release.  The onefile is worse: its launcher alone reports GLIBC_2.34 while
# the interpreter appended inside it needs GLIBC_2.38, so measuring the shipped
# file is not enough -- tools/elf_floors.py measures what a file carries as well
# as the file.  Kept as a separate target rather than a conditional inside
# `baseline`: an artifact that is measured only when it happens to exist is an
# artifact that is silently skipped on the machine where it was forgotten.
RELEASE_BUNDLE := $(CURDIR)/dist/wtop
RELEASE_ELFS := $(RELEASE_BUNDLE)/wtop $(RELEASE_BUNDLE)/.luai/native/wtop_native.so \
	$(CURDIR)/dist/wtop-onefile

RELEASE_BASELINE_OUTPUT ?= dist/BASELINE.release.txt

release-baseline: bundle-dir bundle-file
	@mkdir -p $(dir $(RELEASE_BASELINE_OUTPUT))
	@./tools/record_baseline.sh $(RELEASE_ELFS) > $(RELEASE_BASELINE_OUTPUT)
	@echo "wtop: release baseline evidence written to $(RELEASE_BASELINE_OUTPUT)"

# The glibc floor is a property of the build host, so "which glibc does wtop
# need" is only answerable by compiling somewhere and reading the result off
# the binaries.  This target does that in a container; the default image is the
# oldest libc the project is known to build on.  It says nothing about minimum
# kernels -- a container shares the host's -- which is why the kernel question
# is answered from the source in docs/PACKAGING.md 9.2 instead.
CROSS_LIBC_IMAGE ?= quay.io/pypa/manylinux2014_x86_64
CROSS_LIBC_SUITE ?=

cross-libc: native toolchain
	@./tools/cross_libc_build.sh $(CROSS_LIBC_IMAGE) $(CROSS_LIBC_SUITE)

bundle-dir: build-id native locales $(LUAI_STAMP)
	@# luainstaller validates its output tree against an ownership marker and
	@# rejects any file it did not generate, at any depth -- so the previous
	@# bundle is removed first rather than merged into.  A phony packaging target
	@# that builds on top of its own last output can ship a stale file, and it
	@# cannot be given an extra one: the licence text copied in below is exactly
	@# such a file, and leaving it there made the second run fail with
	@# "Generated output contains an unexpected top-level entry".
	@rm -rf dist/wtop
	mkdir -p dist
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUAI) -b --dir \
		src/wtop.lua -o dist/wtop --lua '$(LUA)' --lua-prefix '$(LUA_PREFIX)' \
		--target-os linux --max-deps 300 $(LOCALE_INCLUDES) -- --version
	@cp $(RELEASE_LICENCE) dist/wtop/$(RELEASE_LICENCE)
	@find dist/wtop -type d -exec chmod 0755 {} +
	@find dist/wtop -type f -exec chmod a+r {} +
	@chmod 0755 dist/wtop/wtop
	@find dist/wtop/.luai/native -type f -exec chmod 0755 {} +

bundle-file: build-id native locales $(LUAI_STAMP)
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

# The release ships programs and the terms they are distributed under, and both
# halves have to be there.  This target exists because the gate in
# docs/PLAN.md §9 names third-party notices as release artifacts while nothing
# checked for them: the SBOM declared EUPL-1.2, MIT and LGPL on four components
# and carried none of the three texts, SHA256SUMS covered two executables and
# none of the notices, and neither CI upload published a notice file.  Every one
# of those now fails somewhere, and this is where the bundle itself is asked.
#
# The manifest coverage is checked by re-reading the discovery the checksums
# recipe used, rather than by comparing against a list written out here: a list
# in the test and a list in the recipe would be two things to forget to update,
# and a notice the packaging tool starts shipping would be covered by one and
# not the other.
test-release-notices: resource-check-full bundle-dir checksums sbom
	@for required in $(RELEASE_LICENCE) THIRD_PARTY_NOTICES.md \
		.luai/licenses/Lua-MIT.txt .luai/licenses/LGPL-3.0-or-later.txt; do \
		test -f "dist/wtop/$$required" || { \
			echo "wtop: the onedir bundle does not carry $$required, and the"; \
			echo "     release is documented as being distributed under terms"; \
			echo "     whose text a recipient would have no way to read."; \
			exit 1; }; \
	done
	@cd dist && find wtop -type f $(RELEASE_NOTICE_FILES) | LC_ALL=C sort | \
		while read -r notice; do \
			grep -q "  $$notice$$" SHA256SUMS || { \
				echo "wtop: $$notice is in the bundle and not in SHA256SUMS, so"; \
				echo "     the integrity manifest covers the programs and not"; \
				echo "     the notices beside them."; \
				exit 1; }; \
		done
	@cd dist && find wtop -type f | LC_ALL=C sort | \
		while read -r shipped; do \
			grep -q "  $$shipped$$" SHA256SUMS || { \
				echo "wtop: $$shipped ships in the onedir bundle and is not in"; \
				echo "     SHA256SUMS.  A recipient who replaces it gets a green"; \
				echo "     sha256sum -c, which is the one result the manifest"; \
				echo "     exists to prevent."; \
				exit 1; }; \
		done
	@cd dist && grep -q "  wtop-onefile$$" SHA256SUMS || { \
		echo "wtop: SHA256SUMS does not cover the onefile entry point"; \
		exit 1; }
	@python3 tools/check_digest_agreement.py --sbom dist/SBOM.cyclonedx.json \
		--manifest dist/SHA256SUMS
	@cd dist && sha256sum -c --quiet SHA256SUMS

checksums:
	@test -x dist/wtop/wtop && test -x dist/wtop-onefile
	@cd dist && find wtop -type f | LC_ALL=C sort > .wtop-files
	@test -s dist/.wtop-files || { \
		echo "wtop: the onedir bundle contains no files, so the manifest"; \
		echo "     would cover one program and nothing else.  Refusing to"; \
		echo "     write it."; \
		exit 1; }
	@cd dist && find wtop -type f $(RELEASE_NOTICE_FILES) | LC_ALL=C sort > .wtop-notices
	@test -s dist/.wtop-notices || { \
		echo "wtop: no licence or notice file found under dist/wtop, so the"; \
		echo "     manifest would cover programs and none of the terms"; \
		echo "     they are distributed under.  Refusing to write it."; \
		exit 1; }
	@cd dist && { sha256sum wtop-onefile; \
		xargs sha256sum < .wtop-files; } > SHA256SUMS
	@rm -f dist/.wtop-files dist/.wtop-notices
	@cd dist && cat SHA256SUMS

endif
