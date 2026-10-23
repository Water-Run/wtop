SHELL := /bin/sh

HOST_OS := $(shell uname -s 2>/dev/null || echo unknown)
ifeq ($(HOST_OS),Darwin)

.PHONY: all native run snapshot diagnose test-native-inventory test-native-disk test-native-network test-native-displays test-native-smc test-native-hid test-native-gpu test-native-ioreport test-native-cpu test-native-worker
.NOTPARALLEL: native bundle-dir bundle-file test-bundle-dir test-bundle-file test-bundles
all: native
native:
	@./tools/build_macos.sh
test-native-inventory: native
	@cc -std=c17 -O2 -Wall -Wextra -Werror -Ibuild/macos/lua-5.5.1/src \
		tests/native/macos_inventory.c build/macos/lua-5.5.1/src/liblua.a \
		-framework IOKit -framework CoreFoundation -o build/macos/inventory-fixture
	@./build/macos/inventory-fixture
test-native-disk: native
	@cc -std=c17 -O2 -Wall -Wextra -Werror -Ibuild/macos/lua-5.5.1/src \
		tests/native/macos_disk.c build/macos/lua-5.5.1/src/liblua.a \
		-framework IOKit -framework CoreFoundation -o build/macos/disk-fixture
	@./build/macos/disk-fixture
test-native-network: native
	@cc -std=c17 -O2 -Wall -Wextra -Werror -Ibuild/macos/lua-5.5.1/src \
		tests/native/macos_network.c build/macos/lua-5.5.1/src/liblua.a \
		-framework IOKit -framework CoreFoundation -o build/macos/network-fixture
	@./build/macos/network-fixture
test-native-displays: native
	@cc -std=c17 -O2 -Wall -Wextra -Werror -Ibuild/macos/lua-5.5.1/src \
		tests/native/macos_displays.c build/macos/lua-5.5.1/src/liblua.a \
		-framework CoreGraphics -framework CoreFoundation -framework ColorSync -o build/macos/displays-fixture
	@./build/macos/displays-fixture
test-native-smc: native
	@cc -std=c17 -O2 -Wall -Wextra -Werror -Ibuild/macos/lua-5.5.1/src \
		tests/native/macos_smc.c -framework IOKit -framework CoreFoundation -o build/macos/smc-fixture
	@./build/macos/smc-fixture
test-native-hid: native
	@cc -std=c17 -O2 -Wall -Wextra -Werror -Ibuild/macos/lua-5.5.1/src \
		tests/native/macos_hid.c build/macos/lua-5.5.1/src/liblua.a \
		-framework IOKit -framework CoreFoundation -o build/macos/hid-fixture
	@./build/macos/hid-fixture
test-native-gpu: native
	@cc -std=c17 -O2 -Wall -Wextra -Werror -Ibuild/macos/lua-5.5.1/src \
		tests/native/macos_gpu.c build/macos/lua-5.5.1/src/liblua.a \
		-framework IOKit -framework CoreFoundation -o build/macos/gpu-fixture
	@./build/macos/gpu-fixture
test-native-ioreport: native
	@cc -std=c17 -O2 -Wall -Wextra -Werror -Ibuild/macos/lua-5.5.1/src \
		tests/native/macos_ioreport.c build/macos/lua-5.5.1/src/liblua.a \
		-framework IOKit -framework CoreFoundation -o build/macos/ioreport-fixture
	@./build/macos/ioreport-fixture
test-native-cpu: native
	@cc -std=c17 -O2 -Wall -Wextra -Werror -Ibuild/macos/lua-5.5.1/src \
		tests/native/macos_cpu.c build/macos/lua-5.5.1/src/liblua.a -o build/macos/cpu-fixture
	@./build/macos/cpu-fixture
test-native-worker: native
	@python3 tests/test_macos_worker.py
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
WTOP_VERSION := $(strip $(shell cat VERSION))
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
VERSION_ROCKSPEC := wtop-$(WTOP_VERSION)-1.rockspec
ROCK_BUILD_DIR := $(CURDIR)/build/luarocks
ROCK_NATIVE_MODULE := $(ROCK_BUILD_DIR)/wtop_native.so
WTOP_ROCK_TREE ?= $(CURDIR)/.tools/wtop-rocks-5.5
SOURCE_ROCK_TREE ?= $(CURDIR)/.tools/wtop-source-rocks-5.5
SOURCE_ROCK_ARGS ?=

NATIVE_SOURCES := native/wtop_native.c native/wtop_nvml.c native/wtop_worker_client.c native/wtop_amdsmi.c \
  native/wtop_levelzero.c
NATIVE_HEADERS := native/wtop_nvml_platform.h native/wtop_nvml.h native/wtop_gpu_output.h native/wtop_gpu_protocol.h native/wtop_gpu_lua.h native/wtop_gpu_worker.h native/wtop_amdsmi.h native/wtop_amdsmi_abi.h native/licenses/AMD-SMI-MIT.txt native/licenses/NVML-NVIDIA.txt native/wtop_levelzero.h native/wtop_levelzero_abi.h native/wtop_levelzero_platform.h native/licenses/Level-Zero-MIT.txt native/wtop_build.h native/wtop_edid_license.h native/licenses/DRM-EDID-MIT.txt
NATIVE_DIR := $(CURDIR)/build/native
NATIVE_MODULE := $(NATIVE_DIR)/wtop_native.so
GPU_WORKER_SOURCES := native/wtop_gpu_worker.c native/wtop_nvml.c native/wtop_amdsmi.c native/wtop_levelzero.c
GPU_WORKER := $(NATIVE_DIR)/wtop_gpu_worker
GPU_WORKER_HEADER := $(NATIVE_DIR)/wtop_gpu_worker_image.h
GPU_WORKER_INPUTS := $(GPU_WORKER_SOURCES) $(NATIVE_HEADERS)
HARDWARE_WORKER_SOURCES := native/wtop_hardware_worker.c native/wtop_native.c native/wtop_linux_cpuid.c
HARDWARE_WORKER := $(NATIVE_DIR)/wtop_hardware_worker
HARDWARE_WORKER_HEADER := $(NATIVE_DIR)/wtop_hardware_worker_image.h
HARDWARE_LUA_HEADER := $(NATIVE_DIR)/wtop_hardware_lua.h
HARDWARE_LUA_INPUTS := $(shell find src/wtop -name '*.lua')
NATIVE_HEADERS += native/wtop_terminal_signal.h native/wtop_hardware_worker.h native/wtop_cpuid_protocol.h native/wtop_cpuid_capture.h native/wtop_linux_nvme.h native/wtop_linux_wifi.h native/wtop_linux_drm.h native/wtop_linux_drm_lua.h
NATIVE_HEADERS += native/wtop_linux_usb.h
NATIVE_HEADERS += native/wtop_linux_process_status.h
NATIVE_HEADERS += native/wtop_linux_perf.h
NATIVE_HEADERS += native/wtop_fs_errors.h
NATIVE_HEADERS += native/wtop_worker_image_cache.h
NATIVE_HEADERS += native/wtop_windows_display_mode.h
NATIVE_HEADERS += native/wtop_recording.h native/wtop_recording_license.h native/vendor/lz4/lz4.c native/vendor/lz4/lz4.h native/licenses/LZ4-BSD-2-Clause.txt
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
ROOTLESS_EXECUTABLE ?= $(CURDIR)/dist/wtop-onefile
ROOTLESS_IMAGE ?=
ROOTLESS_OUTPUT ?=

CFLAGS_NATIVE ?= -O2 -g0
CFLAGS_NATIVE += -std=c17 -fPIC -Wall -Wextra -Werror

.NOTPARALLEL: all native locales check test test-all test-fast test-54 test-55 test-pty test-pty-quick test-luarocks \
	benchmark-check \
	toolchain luainstaller luarocks-bootstrap luarocks-install bundle-dir bundle-file \
	test-bundle-dir test-bundle-file test-rootless-onefile test-release-notices check-native-warnings test-recording-replay \
	release-archive test-release-archive test-downloaded-archive sanitize-native test-sanitized

.PHONY: all resource-check resource-check-full resource-check-benchmark toolchain luainstaller native locales check test test-all test-fast \
	benchmark-check \
	test-54 test-55 test-pty test-pty-quick benchmark test-fuzz run \
	diagnose snapshot bundle-dir bundle-file test-bundle-dir test-bundle-file checksums build-id sbom baseline \
	cross-libc release-baseline rock-build rock-install rockspec-check luarocks-bootstrap luarocks-install test-luarocks

.PHONY: release-archive test-release-archive test-downloaded-archive version-rockspec source-rock test-source-rock rock-index test-rock-index test-rootless-onefile

all: native locales

resource-check:
	@./tools/check_resources.sh test

resource-check-full:
	@./tools/check_resources.sh full

resource-check-benchmark:
	@./tools/check_resources.sh benchmark

toolchain: $(LUA_STAMP)

luarocks-bootstrap: $(LUAROCKS_STAMP)

luainstaller: $(LUAI_STAMP)
	@./tools/bootstrap_luainstaller.sh >/dev/null

native: resource-check $(NATIVE_MODULE)

$(LUA_STAMP): tools/bootstrap_lua.sh
	@./tools/bootstrap_lua.sh >/dev/null
	@touch $@

$(LUAROCKS_STAMP): tools/bootstrap_luarocks.sh $(LUA_STAMP)
	@./tools/bootstrap_luarocks.sh >/dev/null
	@touch $@

$(LUAI_STAMP): tools/bootstrap_luainstaller.sh tools/luainstaller-1.5.0.sha256 $(LUA_STAMP)
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
.PHONY: force-build-identity
force-build-identity:

# Git refs and dirty state can change without touching a source dependency.
# The generator preserves timestamps when the identity is unchanged.
$(NATIVE_REVISION_HEADER): tools/write_build_id.sh VERSION force-build-identity
	@mkdir -p $(NATIVE_DIR)
	@./tools/write_build_id.sh --refresh

# Written by the same invocation, immediately after the revision header, so it is
# never the older of the two.  The recipe re-runs the generator if it is missing
# rather than failing: the header is an output, and an output that was deleted
# should be rebuilt, not diagnosed.
$(NATIVE_VERSION_HEADER): $(NATIVE_REVISION_HEADER)
	@test -f $@ || ./tools/write_build_id.sh --refresh

$(GPU_WORKER): $(GPU_WORKER_INPUTS) Makefile
	@mkdir -p $(NATIVE_DIR)
	@$(CC) $(CFLAGS) -std=c17 -O2 -Wall -Wextra -Werror -s -DWTOP_GPU_WORKER -o $@ $(GPU_WORKER_SOURCES) -ldl -lm

$(GPU_WORKER_HEADER): $(GPU_WORKER) tools/embed_gpu_worker.sh
	@sh tools/embed_gpu_worker.sh $(GPU_WORKER) $@

$(HARDWARE_LUA_HEADER): $(NATIVE_REVISION_HEADER) tools/embed_hardware_lua.lua $(HARDWARE_LUA_INPUTS) $(LUA_STAMP)
	@mkdir -p $(NATIVE_DIR)
	@$(LUA) tools/embed_hardware_lua.lua $@.tmp
	@mv $@.tmp $@

$(HARDWARE_WORKER): $(HARDWARE_WORKER_SOURCES) $(NATIVE_HEADERS) $(HARDWARE_LUA_HEADER) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER) Makefile
	@$(CC) $(CFLAGS) -std=c17 -O2 -Wall -Wextra -Werror -s -DWTOP_HARDWARE_WORKER \
		-I$(NATIVE_DIR) -I$(LUA_PREFIX)/include -o $@ $(HARDWARE_WORKER_SOURCES) \
		$(LUA_PREFIX)/lib/liblua.a -ldl -lm -pthread

$(HARDWARE_WORKER_HEADER): $(HARDWARE_WORKER) tools/embed_gpu_worker.sh
	@sh tools/embed_gpu_worker.sh $(HARDWARE_WORKER) $@ wtop_hardware_worker_image

$(NATIVE_MODULE): $(NATIVE_SOURCES) $(NATIVE_HEADERS) $(NATIVE_REVISION_HEADER) $(GPU_WORKER_HEADER) $(HARDWARE_WORKER_HEADER) \
		$(NATIVE_VERSION_HEADER) Makefile $(LUA_STAMP)
	@mkdir -p $(NATIVE_DIR)
	@$(CC) $(CFLAGS_NATIVE) -shared -I$(NATIVE_DIR) -I$(LUA_PREFIX)/include \
		-o $@ $(NATIVE_SOURCES) -ldl -pthread

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

check-native-warnings: $(LUA_STAMP) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER) $(GPU_WORKER_HEADER) $(HARDWARE_WORKER_HEADER)
	@$(CC) $(STRICT_NATIVE_CFLAGS) -o /dev/null $(NATIVE_SOURCES) -ldl -pthread
	@$(CC) $(filter-out -fPIC -shared,$(STRICT_NATIVE_CFLAGS)) -DWTOP_GPU_WORKER -o /dev/null $(GPU_WORKER_SOURCES) -ldl -lm
	@$(CC) $(filter-out -fPIC -shared,$(STRICT_NATIVE_CFLAGS)) -DWTOP_HARDWARE_WORKER -o /dev/null $(HARDWARE_WORKER_SOURCES) $(LUA_PREFIX)/lib/liblua.a -ldl -lm -pthread
	@$(CC) $(STRICT_NATIVE_CFLAGS) -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 \
		-o /dev/null tests/native/hardware_io_fake.c -ldl
	@$(CC) $(STRICT_NATIVE_CFLAGS) -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 \
		-o /dev/null tests/native/cpu_clock_fake.c -ldl
	@echo "wtop: $(words $(NATIVE_SOURCES)) native sources clean under: $(STRICT_NATIVE_CFLAGS)"

# The sanitized module is a separate file on purpose.  Overwriting
# $(NATIVE_MODULE) would leave a module newer than its own prerequisites, so the
# next `make native` would not rebuild it and the rest of the suite would run
# against an instrumented build it did not ask for.
SANITIZED_DIR := build/native-san
SANITIZED_MODULE := $(SANITIZED_DIR)/wtop_native.so
SANITIZED_GPU_WORKER := $(SANITIZED_DIR)/wtop_gpu_worker
SANITIZED_GPU_HEADER := $(SANITIZED_DIR)/wtop_gpu_worker_image.h
SANITIZED_HARDWARE_WORKER := $(SANITIZED_DIR)/wtop_hardware_worker
SANITIZED_HARDWARE_HEADER := $(SANITIZED_DIR)/wtop_hardware_worker_image.h
SANITIZER_CFLAGS := -std=c17 -fPIC -Wall -Wextra -Werror -O1 -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer

$(SANITIZED_GPU_WORKER): $(GPU_WORKER_INPUTS) Makefile
	@mkdir -p $(SANITIZED_DIR)
	@$(CC) $(SANITIZER_CFLAGS) -DWTOP_GPU_WORKER -o $@ $(GPU_WORKER_SOURCES) -ldl -lm

$(SANITIZED_GPU_HEADER): $(SANITIZED_GPU_WORKER) tools/embed_gpu_worker.sh
	@sh tools/embed_gpu_worker.sh $(SANITIZED_GPU_WORKER) $@

$(SANITIZED_HARDWARE_WORKER): $(HARDWARE_WORKER_SOURCES) $(NATIVE_HEADERS) $(HARDWARE_LUA_HEADER) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER) Makefile
	@mkdir -p $(SANITIZED_DIR)
	@$(CC) $(SANITIZER_CFLAGS) -DWTOP_HARDWARE_WORKER -I$(NATIVE_DIR) -I$(LUA_PREFIX)/include \
		-o $@ $(HARDWARE_WORKER_SOURCES) $(LUA_PREFIX)/lib/liblua.a -ldl -lm -pthread

$(SANITIZED_HARDWARE_HEADER): $(SANITIZED_HARDWARE_WORKER) tools/embed_gpu_worker.sh
	@sh tools/embed_gpu_worker.sh $(SANITIZED_HARDWARE_WORKER) $@ wtop_hardware_worker_image

sanitize-native: $(LUA_STAMP) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER) $(SANITIZED_GPU_HEADER) $(SANITIZED_HARDWARE_HEADER)
	@mkdir -p $(SANITIZED_DIR)
	@$(CC) $(SANITIZER_CFLAGS) -shared -I$(SANITIZED_DIR) -I$(NATIVE_DIR) -I$(LUA_PREFIX)/include \
		-o $(SANITIZED_MODULE) $(NATIVE_SOURCES) -ldl -pthread

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
#
# The interpreter this env runs on is the bootstrapped PUC Lua, built by
# `make toolchain` with no sanitizer flags, and ASan needs its runtime in the
# initial library list of the *process*, not of the dlopen() that loads the
# module.  Without the preload the first sanitized invocation aborts before a
# single test runs ("ASan runtime does not come first in initial library
# list"), which is how this gate spent 2026-09-28 onward failing in its first
# second while passing nowhere that could fix it -- the development host had
# no sanitizer runtime at the time the target was written.
#
# The runtime to preload is read out of the module's own DT_NEEDED rather than
# out of the compiler: `-print-file-name=libasan.so` answers the *linker
# script* gcc uses for linking (preloading it fails with "file too short"),
# clang links a differently-named runtime entirely, and the DSO the module
# actually carries as a dependency is loadable by that very name through the
# loader's normal search -- which is also how the dlopen finds it at all.
#
# Both variables below are lazy (`=`, not `:=`) so the query runs against the
# module this target just built, not whatever a previous run left behind.  The
# distinction was measured in CI, not reasoned about: with SAN_RUN_ENV as `:=`
# its whole value froze at parse time, when no module exists, so LD_PRELOAD
# ran empty while the validation line below -- a direct reference, expanded
# per use -- saw the real soname and passed, and the first sanitized command
# still died on the library-order check.  A guard and the thing it guards must
# not expand at different times.
SAN_ASAN_RUNTIME = $(shell objdump -p $(SANITIZED_MODULE) 2>/dev/null \
	| grep -o 'lib[a-z_.]*asan[a-z_.0-9-]*\.so[.0-9]*' | head -n 1)
# The sanitized run also declares itself without the *ordinary* build
# artifacts: its module lives in $(SANITIZED_DIR), so build/native/ holds
# nothing, and the tests whose subject is the ordinary module or the documents
# built from it state-and-skip rather than fail (tests/support/artifacts.lua).
# What is not skipped is the point of this run: every test that loads a module
# loads the instrumented one through LUA_CPATH below.
SAN_RUN_ENV = ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
	UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
	LD_PRELOAD='$(SAN_ASAN_RUNTIME)' \
	WTOP_TESTS_WITHOUT_ARTIFACTS=1 \
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
        $(NATIVE_VERSION_HEADER) sanitize-native test-native-amdsmi-sanitized test-native-levelzero-sanitized test-native-nvml-sanitized test-native-nvml-worker-sanitized test-native-gpu-worker-sanitized test-native-hardware-worker-sanitized test-native-drm-worker-sanitized test-native-cpu-clocks-sanitized test-native-cpuid-sanitized test-native-process-status-sanitized test-native-usb-endpoints-sanitized test-native-io-oom-sanitized test-native-perf-counts-sanitized test-native-directory-hints-sanitized test-native-worker-images-sanitized
	@if [ -z '$(SAN_ASAN_RUNTIME)' ]; then echo "wtop: the sanitized module names no ASan runtime to preload, so the suite cannot run on the uninstrumented interpreter"; exit 1; fi
	@for mode in --snapshot --agent --diagnose; do \
		echo "wtop: sanitized $$mode"; \
		$(SAN_RUN_ENV) $(LUA) src/wtop.lua $$mode > /dev/null || exit 1; \
	done
	$(SAN_RUN_ENV) $(LUA) tests/run.lua \
		$(filter-out $(SANITIZER_EXCLUDED),$(TEST_FILES))

.PHONY: test-native-nvme-health
test-native-nvme-health: native
	@mkdir -p $(NATIVE_DIR)
	@$(CC) $(CFLAGS) -std=c17 -O2 -Wall -Wextra -Werror -Inative \
		tests/native/linux_nvme_health.c -o $(NATIVE_DIR)/nvme-health-fixture
	@$(NATIVE_DIR)/nvme-health-fixture
	@python3 tests/test_linux_nvme_health.py --cc '$(CC)' --module '$(NATIVE_MODULE)' --lua-prefix '$(LUA_PREFIX)'

.PHONY: test-native-wifi
.PHONY: test-native-drm-modes
.PHONY: test-native-usb-endpoints test-native-usb-endpoints-sanitized
test-native-usb-endpoints: $(LUA_STAMP)
	@python3 tests/test_linux_usb_endpoints.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-usb-endpoints-sanitized: $(LUA_STAMP)
	@python3 tests/test_linux_usb_endpoints.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS) -fno-pie -no-pie' --output build/native-usb-endpoints-san

test-native-drm-modes: native
	@$(CC) -std=c17 -O2 -Wall -Wextra -Werror -I$(LUA_PREFIX)/include \
		tests/native/linux_drm_modes.c $(LUA_PREFIX)/lib/liblua.a -lm -ldl -o build/native/drm-modes-fixture
	@build/native/drm-modes-fixture
test-native-wifi: native
	@python3 tests/test_linux_wifi.py --cc '$(CC)' --module '$(NATIVE_MODULE)' --lua-prefix '$(LUA_PREFIX)'

.PHONY: test-native-cpu-limits
test-native-cpu-limits: $(LUA_STAMP) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER) $(GPU_WORKER_HEADER) $(HARDWARE_WORKER_HEADER)
	@mkdir -p $(NATIVE_DIR)
	@$(CC) $(CFLAGS_NATIVE) -I$(NATIVE_DIR) -I$(LUA_PREFIX)/include \
		tests/native/linux_cpu_limits.c $(filter-out native/wtop_native.c,$(NATIVE_SOURCES)) \
		$(LUA_PREFIX)/lib/liblua.a -lm -ldl -pthread -o $(NATIVE_DIR)/cpu-limits-fixture
	@$(NATIVE_DIR)/cpu-limits-fixture

.PHONY: test-native-io-oom test-native-io-oom-sanitized
test-native-io-oom: $(LUA_STAMP) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER) $(GPU_WORKER_HEADER) $(HARDWARE_WORKER_HEADER)
	@mkdir -p $(NATIVE_DIR)
	@$(CC) $(CFLAGS_NATIVE) -std=c17 -Wall -Wextra -Werror \
		-I$(NATIVE_DIR) -I$(LUA_PREFIX)/include tests/native/linux_io_oom.c \
		$(filter-out native/wtop_native.c,$(NATIVE_SOURCES)) \
		$(LUA_PREFIX)/lib/liblua.a -lm -ldl -pthread -o $(NATIVE_DIR)/io-oom-fixture
	@$(NATIVE_DIR)/io-oom-fixture

test-native-io-oom-sanitized: $(LUA_STAMP) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER) $(GPU_WORKER_HEADER) $(HARDWARE_WORKER_HEADER)
	@mkdir -p $(SANITIZED_DIR)
	@$(CC) $(SANITIZER_CFLAGS) -I$(NATIVE_DIR) -I$(LUA_PREFIX)/include \
		tests/native/linux_io_oom.c $(filter-out native/wtop_native.c,$(NATIVE_SOURCES)) \
		$(LUA_PREFIX)/lib/liblua.a -lm -ldl -pthread -o $(SANITIZED_DIR)/io-oom-fixture
	@ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 $(SANITIZED_DIR)/io-oom-fixture

.PHONY: test-native-directory-hints test-native-directory-hints-sanitized
test-native-directory-hints: $(LUA_STAMP) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER) $(GPU_WORKER_HEADER) $(HARDWARE_WORKER_HEADER)
	@mkdir -p $(NATIVE_DIR)
	@$(CC) $(CFLAGS_NATIVE) -std=c17 -Wall -Wextra -Werror \
		-I$(NATIVE_DIR) -I$(LUA_PREFIX)/include tests/native/linux_directory_hints.c \
		$(filter-out native/wtop_native.c,$(NATIVE_SOURCES)) \
		$(LUA_PREFIX)/lib/liblua.a -lm -ldl -pthread -o $(NATIVE_DIR)/directory-hints-fixture
	@$(NATIVE_DIR)/directory-hints-fixture

test-native-directory-hints-sanitized: $(LUA_STAMP) $(NATIVE_REVISION_HEADER) $(NATIVE_VERSION_HEADER) $(GPU_WORKER_HEADER) $(HARDWARE_WORKER_HEADER)
	@mkdir -p $(SANITIZED_DIR)
	@$(CC) $(SANITIZER_CFLAGS) -I$(NATIVE_DIR) -I$(LUA_PREFIX)/include \
		tests/native/linux_directory_hints.c $(filter-out native/wtop_native.c,$(NATIVE_SOURCES)) \
		$(LUA_PREFIX)/lib/liblua.a -lm -ldl -pthread -o $(SANITIZED_DIR)/directory-hints-fixture
	@ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 $(SANITIZED_DIR)/directory-hints-fixture

.PHONY: test-native-worker-images test-native-worker-images-sanitized
test-native-worker-images:
	@mkdir -p build/native-worker-images
	@$(CC) $(CFLAGS) -std=c17 -O2 -Wall -Wextra -Werror -pthread -Inative \
		tests/native/worker_image_cache.c -o build/native-worker-images/fixture
	@build/native-worker-images/fixture
	@$(CC) $(CFLAGS) -std=c17 -O2 -Wall -Wextra -Werror -pthread -Inative \
		-DWTOP_TEST_NO_SEALS tests/native/worker_image_cache.c -o build/native-worker-images/no-seals
	@build/native-worker-images/no-seals

test-native-worker-images-sanitized:
	@mkdir -p build/native-worker-images-san
	@$(CC) $(SANITIZER_CFLAGS) -fno-pie -no-pie -pthread -Inative \
		tests/native/worker_image_cache.c -o build/native-worker-images-san/fixture
	@ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 build/native-worker-images-san/fixture
	@$(CC) $(SANITIZER_CFLAGS) -fno-pie -no-pie -pthread -Inative \
		-DWTOP_TEST_NO_SEALS tests/native/worker_image_cache.c -o build/native-worker-images-san/no-seals
	@ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 build/native-worker-images-san/no-seals

.PHONY: test-native-amdsmi test-native-amdsmi-sanitized
test-native-amdsmi: $(LUA_STAMP)
	@python3 tests/test_linux_amdsmi.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-amdsmi-sanitized: $(LUA_STAMP)
	@python3 tests/test_linux_amdsmi.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --output build/native-amdsmi-san

.PHONY: test-native-levelzero test-native-levelzero-sanitized
test-native-levelzero: $(LUA_STAMP)
	@python3 tests/test_linux_levelzero.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-levelzero-sanitized: $(LUA_STAMP)
	@python3 tests/test_linux_levelzero.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --output build/native-levelzero-san

.PHONY: test-native-nvml test-native-nvml-sanitized test-native-nvml-worker test-native-nvml-worker-sanitized
test-native-nvml: $(LUA_STAMP)
	@python3 tests/test_linux_nvml.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-nvml-sanitized: $(LUA_STAMP)
	@python3 tests/test_linux_nvml.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --output build/native-nvml-san

test-native-nvml-worker: native $(LUA_STAMP)
	@python3 tests/test_linux_nvml_worker.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-nvml-worker-sanitized: sanitize-native $(LUA_STAMP)
	@python3 tests/test_linux_nvml_worker.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --module '$(SANITIZED_MODULE)' \
		--output build/native-nvml-worker-san --native-only

.PHONY: test-native-gpu-worker test-native-gpu-worker-sanitized test-native-hardware-worker test-native-hardware-worker-sanitized test-native-drm-worker test-native-drm-worker-sanitized test-native-cpu-clocks test-native-cpu-clocks-sanitized test-native-tui-input
test-native-cpu-clocks: native $(LUA_STAMP)
	@python3 tests/test_linux_cpu_clocks.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-cpu-clocks-sanitized: sanitize-native $(LUA_STAMP)
	@$(SAN_RUN_ENV) python3 tests/test_linux_cpu_clocks.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --module '$(SANITIZED_MODULE)' --output build/native-cpu-clocks-san

test-native-drm-worker: native $(LUA_STAMP)
	@python3 tests/test_linux_drm_worker.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-drm-worker-sanitized: sanitize-native $(LUA_STAMP)
	@$(SAN_RUN_ENV) python3 tests/test_linux_drm_worker.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --module '$(SANITIZED_MODULE)' --output build/native-drm-worker-san --native-only

.PHONY: test-native-cpuid test-native-cpuid-sanitized
test-native-cpuid: native $(LUA_STAMP)
	@python3 tests/test_linux_cpuid.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-cpuid-sanitized: sanitize-native $(LUA_STAMP)
	@$(SAN_RUN_ENV) python3 tests/test_linux_cpuid.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --module '$(SANITIZED_MODULE)' --output build/native-cpuid-san --native-only

.PHONY: test-native-process-status test-native-process-status-sanitized
test-native-process-status: native $(LUA_STAMP)
	@python3 tests/test_linux_process_status.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-process-status-sanitized: sanitize-native $(LUA_STAMP)
	@$(SAN_RUN_ENV) python3 tests/test_linux_process_status.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --module '$(SANITIZED_MODULE)' --output build/native-process-status-san

test-native-hardware-worker: native $(LUA_STAMP)
	@python3 tests/test_linux_hardware_worker.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-tui-input: native $(LUA_STAMP)
	@python3 tests/test_tui_input_before_sampling.py --lua-prefix '$(LUA_PREFIX)'

test-native-hardware-worker-sanitized: sanitize-native $(LUA_STAMP)
	@$(SAN_RUN_ENV) python3 tests/test_linux_hardware_worker.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --module '$(SANITIZED_MODULE)' \
		--output build/native-hardware-worker-san --native-only

test-native-gpu-worker: native $(LUA_STAMP)
	@python3 tests/test_linux_gpu_worker.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)'

test-native-gpu-worker-sanitized: sanitize-native $(LUA_STAMP)
	@python3 tests/test_linux_gpu_worker.py --cc '$(CC)' --lua-prefix '$(LUA_PREFIX)' \
		--cflags='$(SANITIZER_CFLAGS)' --module '$(SANITIZED_MODULE)' \
		--output build/native-gpu-worker-san --native-only

.PHONY: test-build-identity test-recording-replay
test-build-identity: resource-check
	@python3 tests/test_build_identity_refresh.py

test-recording-replay: native locales
	@python3 tests/test_recording_replay.py --lua '$(LUA)'
	@python3 tests/test_recording_replay_tty.py --lua '$(LUA)' --guard
	@python3 tests/test_health_tty.py --lua '$(LUA)' --guard
	@python3 tests/test_runtime_pm_tty.py --lua '$(LUA)' --guard

check: resource-check native locales test-build-identity test-recording-replay test-native-terminal-signals test-native-cpu-limits test-native-io-oom test-native-nvme-health test-native-wifi test-native-drm-modes test-native-usb-endpoints test-native-amdsmi test-native-levelzero test-native-nvml test-native-nvml-worker test-native-gpu-worker test-native-hardware-worker test-native-drm-worker test-native-cpu-clocks test-native-cpuid test-native-process-status test-native-perf-counts test-native-tui-input test-native-directory-hints test-native-worker-images
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH='$(LUA_CPATH_DEV)' $(LUAC) -p $$(find src tools tests -type f -name '*.lua' -print)
	@sh -n tools/*.sh
	@python3 -c 'import pathlib; [compile(path.read_bytes(), str(path), "exec") for path in pathlib.Path("tests").rglob("*.py")]'
	@python3 -c 'import json; json.load(open("docs/agent-v1.schema.json", encoding="utf-8"))'
	@python3 -c 'import json; json.load(open("docs/memory-bandwidth-v1.schema.json", encoding="utf-8"))'
	@# Parsing the agent schema proves the schema is JSON.  It says nothing about
	@# the document --agent emits, so the next line applies it.  The CI job that
	@# runs this one is named "Syntax, schema and the full unit suite", and until
	@# this step existed the middle word was doing no work.
	@WTOP_LUA='$(LUA)' WTOP_NATIVE_DIR='$(NATIVE_DIR)' \
		$(LUA) tools/check_agent_schema.lua
	@for mode in memory-bandwidth memory-pmu-list; do \
		WTOP_LUA='$(LUA)' WTOP_NATIVE_DIR='$(NATIVE_DIR)' \
		$(LUA) tools/check_agent_schema.lua --schema docs/memory-bandwidth-v1.schema.json --mode $$mode || exit 1; \
	done
	@python3 tests/test_json_contract_smoke.py
	@python3 tests/test_luainstaller_bootstrap.py
	@python3 tests/test_windows_x86_artifact.py
	@python3 tests/test_windows_payload.py --lua '$(LUA)'
	@python3 tests/test_macos_artifact.py
	@python3 tests/test_release_archive.py

test: resource-check-full test-55 test-pty

# Release-style validation: both Lua ABIs, source PTY, LuaRocks, both
# luainstaller artifact forms, and every release-evidence document.  The last
# clause is not redundant with the individual targets existing: `sbom` was
# absent from here while CI ran it, and a gate that runs somewhere other than
# where a person looks is how an SBOM spent a month describing nothing and
# reporting success.  Every prerequisite remains serial and gated.
test-all: resource-check-full check check-native-warnings test-54 test-55 test-pty \
	rockspec-check release-baseline sbom checksums test-release-notices \
	test-luarocks test-bundle-dir test-bundle-file test-release-archive test-source-rock test-rock-index
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

# The 5.4 subset run builds nothing: no native module, no packaged
# interpreter, no bundles.  Its question is whether the Lua tree still parses
# and runs on the system interpreter, and tests whose subject is one of those
# artifacts refuse to run without them (tests/support/artifacts.lua) so that a
# broken build cannot pass test-55 or test-all.  This run declares the absence
# up front -- the one environment where it is the environment and not a
# broken build -- and those tests print a stated skip instead of failing.
test-54: resource-check
	@lua -e 'assert(_VERSION == "Lua 5.4", "test-54 requires Lua 5.4, got " .. _VERSION)'
	LUA_PATH='$(LUA_PATH_DEV)' LUA_CPATH=';;' WTOP_TESTS_WITHOUT_ARTIFACTS=1 lua tests/run.lua $(TEST_FILES)

# The benchmark drives the development tree unless it is told which artifact to
# measure, and those are not the same program: on one host the bundle started
# 15% slower and held 25% more resident memory than the source tree.  The
# release gates in docs/PLAN.md ask about what ships, so the subject has to be
# selectable from here rather than only through an environment variable that
# appears in no document.  The tool records which subject it used in both its
# output and its JSON, so a result cannot be mistaken for the other kind.
#
#   make native locales && make benchmark
#   make benchmark BENCH_EXECUTABLE=dist/wtop/wtop
#   make benchmark BENCH_EXECUTABLE=dist/wtop-onefile
# A prebuilt bundle is measured without a compiler or Lua source-tree artifacts;
# the benchmark resource profile also works on low-memory target hosts.
BENCH_EXECUTABLE ?=
BENCH_ARGS ?=
BENCH_PROFILE ?= unprofiled
BENCH_BUDGET ?=
BENCH_RESULT ?= build/perf/current.json

benchmark: resource-check-benchmark
	@WTOP_LUA='$(LUA)' WTOP_ROOT='$(CURDIR)' \
		WTOP_BENCH_EXECUTABLE='$(BENCH_EXECUTABLE)' \
		python3 tools/perf_benchmark.py $(BENCH_ARGS)

# Hardware-profile budgets are supplied by the machine that can actually run
# them. There is deliberately no release threshold copied from this build host.
benchmark-check: resource-check-benchmark
	@test -n '$(BENCH_EXECUTABLE)' || { echo 'benchmark-check requires BENCH_EXECUTABLE' >&2; exit 1; }
	@test -n '$(BENCH_BUDGET)' || { echo 'benchmark-check requires BENCH_BUDGET' >&2; exit 1; }
	@test '$(BENCH_PROFILE)' != 'unprofiled' || { echo 'benchmark-check requires BENCH_PROFILE' >&2; exit 1; }
	@mkdir -p '$(dir $(BENCH_RESULT))'
	@WTOP_LUA='$(LUA)' WTOP_ROOT='$(CURDIR)' \
		WTOP_BENCH_EXECUTABLE='$(BENCH_EXECUTABLE)' \
		python3 tools/perf_benchmark.py $(BENCH_ARGS) \
			--profile '$(BENCH_PROFILE)' --json '$(BENCH_RESULT)'
	@python3 tools/check_perf_budget.py --result '$(BENCH_RESULT)' --budget '$(BENCH_BUDGET)'

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
rock-build: resource-check build-id $(GPU_WORKER_HEADER) $(HARDWARE_WORKER_HEADER)
	@test -n "$(LUA_INCDIR)" || { echo "wtop: LUA_INCDIR is required" >&2; exit 1; }
	@mkdir -p "$(ROCK_BUILD_DIR)"
	$(CC) $(CFLAGS) -std=c17 -fPIC -Wall -Wextra -Werror -shared \
		-I"$(NATIVE_DIR)" -I"$(LUA_INCDIR)" -o "$(ROCK_NATIVE_MODULE)" \
		$(NATIVE_SOURCES) -ldl -pthread

rock-install:
	@test -f "$(ROCK_NATIVE_MODULE)" || { echo "wtop: run the rock build pass first" >&2; exit 1; }
	@test -n "$(PREFIX)" -a -n "$(LUADIR)" -a -n "$(LIBDIR)" -a -n "$(BINDIR)" || \
		{ echo "wtop: LuaRocks install directories are required" >&2; exit 1; }
	@mkdir -p "$(LUADIR)/wtop" "$(LIBDIR)" "$(BINDIR)" "$(PREFIX)/doc/licenses"
	@cp -R src/wtop/. "$(LUADIR)/wtop/"
	@cp "$(ROCK_NATIVE_MODULE)" "$(LIBDIR)/wtop_native.so"
	@cp src/wtop.lua "$(BINDIR)/wtop"
	@chmod 755 "$(BINDIR)/wtop" "$(LIBDIR)/wtop_native.so"
	@cp LICENSE README.md README-zh.md README-fr.md README-ru.md config.example.yml "$(PREFIX)/doc/"
	@cp THIRD_PARTY.md "$(PREFIX)/doc/THIRD_PARTY_NOTICES.md"
	@cp native/licenses/*.txt "$(PREFIX)/doc/licenses/"

rockspec-check: $(LUAROCKS_STAMP) version-rockspec
	@"$(LUAROCKS)" lint "$(ROCKSPEC)"
	@"$(LUAROCKS)" lint "$(VERSION_ROCKSPEC)"

luarocks-install: resource-check-full $(LUA_STAMP) $(LUAROCKS_STAMP)
	"$(LUAROCKS)" --lua-version=5.5 --lua-dir="$(LUA_PREFIX)" --tree="$(WTOP_ROCK_TREE)" \
		make "$(ROCKSPEC)" --deps-mode=none --force

test-luarocks: luarocks-install
	@python3 tests/installed_smoke.py --executable "$(WTOP_ROCK_TREE)/bin/wtop" \
		--version "$(WTOP_VERSION)" --platform Linux

# Optional host acceptance: needs rootless Podman and an existing local image.
# It measures the supplied executable and does not rebuild either bundle.
test-rootless-onefile: resource-check-full
	@test -n '$(ROOTLESS_IMAGE)' || { echo 'test-rootless-onefile requires ROOTLESS_IMAGE (an existing local Linux image)' >&2; exit 1; }
	@python3 tests/test_rootless_onefile.py --executable '$(ROOTLESS_EXECUTABLE)' \
		--image '$(ROOTLESS_IMAGE)' --version '$(WTOP_VERSION)' --pty \
		$(if $(ROOTLESS_OUTPUT),--output '$(ROOTLESS_OUTPUT)',)

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

bundle-dir: build-id native locales luainstaller
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
	@cp native/licenses/AMD-SMI-MIT.txt dist/wtop/.luai/licenses/AMD-SMI-MIT.txt
	@cp native/licenses/NVML-NVIDIA.txt dist/wtop/.luai/licenses/NVML-NVIDIA.txt
	@cp native/licenses/Level-Zero-MIT.txt dist/wtop/.luai/licenses/Level-Zero-MIT.txt
	@cp native/licenses/DRM-EDID-MIT.txt dist/wtop/.luai/licenses/DRM-EDID-MIT.txt
	@cp native/licenses/LZ4-BSD-2-Clause.txt dist/wtop/.luai/licenses/LZ4-BSD-2-Clause.txt
	@find dist/wtop -type d -exec chmod 0755 {} +
	@find dist/wtop -type f -exec chmod a+r {} +
	@chmod 0755 dist/wtop/wtop
	@find dist/wtop/.luai/native -type f -exec chmod 0755 {} +

bundle-file: build-id native locales luainstaller
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
test-release-notices: resource-check-full sbom checksums
	@for required in $(RELEASE_LICENCE) THIRD_PARTY_NOTICES.md \
		.luai/licenses/Lua-MIT.txt .luai/licenses/AMD-SMI-MIT.txt .luai/licenses/NVML-NVIDIA.txt .luai/licenses/Level-Zero-MIT.txt .luai/licenses/DRM-EDID-MIT.txt .luai/licenses/LZ4-BSD-2-Clause.txt .luai/licenses/LGPL-3.0-or-later.txt; do \
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

RELEASE_ARCHIVE ?= dist/wtop-$(WTOP_VERSION)-linux-$(shell uname -m)-glibc.tar.gz
ARCHIVE_PTY_PROFILE ?= quick
DOWNLOAD_DIR ?=

release-archive: resource-check-full test-release-notices release-baseline
	@python3 tools/release_archive.py create --dist dist --output '$(RELEASE_ARCHIVE)'

test-release-archive: release-archive
	@python3 tools/release_archive.py verify '$(RELEASE_ARCHIVE)' \
		--version '$(WTOP_VERSION)' --pty '$(ARCHIVE_PTY_PROFILE)'

# This target runs on a new runner and never rebuilds the downloaded programs.
test-downloaded-archive: resource-check-full
	@test -n '$(DOWNLOAD_DIR)' || { echo 'DOWNLOAD_DIR is required' >&2; exit 1; }
	@python3 tools/release_archive.py verify --download-dir '$(DOWNLOAD_DIR)' \
		--version '$(WTOP_VERSION)' --pty full

version-rockspec:
	@python3 tools/make_source_rock.py --rockspec-only

source-rock: resource-check-full version-rockspec
	@python3 tools/make_source_rock.py --output dist/source $(SOURCE_ROCK_ARGS)

test-source-rock: source-rock $(LUA_STAMP) $(LUAROCKS_STAMP)
	@"$(LUAROCKS)" --lua-version=5.5 --lua-dir="$(LUA_PREFIX)" --tree="$(SOURCE_ROCK_TREE)" \
		install "$(CURDIR)/dist/source/wtop-$(WTOP_VERSION)-1.src.rock" --deps-mode=none --force
	@python3 tests/installed_smoke.py --executable "$(SOURCE_ROCK_TREE)/bin/wtop" \
		--version "$(WTOP_VERSION)" --platform Linux

rock-index: source-rock $(LUAROCKS_STAMP)
	@"$(LUAROCKS_PREFIX)/bin/luarocks-admin" --lua-version=5.5 make_manifest dist/source

test-rock-index: rock-index $(LUA_STAMP)
	@"$(LUAROCKS)" --lua-version=5.5 --lua-dir="$(LUA_PREFIX)" \
		--tree="$(CURDIR)/.tools/wtop-index-rocks-5.5" --only-server="file://$(CURDIR)/dist/source" \
		install wtop "$(WTOP_VERSION)-1" --deps-mode=none --force
	@python3 tests/installed_smoke.py --executable "$(CURDIR)/.tools/wtop-index-rocks-5.5/bin/wtop" \
		--version "$(WTOP_VERSION)" --platform Linux


.PHONY: test-native-perf-counts test-native-perf-counts-sanitized
test-native-perf-counts: $(LUA_STAMP)
	@mkdir -p build/native-perf-counts
	@$(CC) $(CFLAGS) -std=c17 -O2 -Wall -Wextra -Werror -I$(LUA_PREFIX)/include -Inative \
		tests/native/linux_perf_counts.c $(LUA_PREFIX)/lib/liblua.a -lm -ldl -o build/native-perf-counts/fixture
	@build/native-perf-counts/fixture

test-native-perf-counts-sanitized: $(LUA_STAMP)
	@mkdir -p build/native-perf-counts-san
	@$(CC) $(SANITIZER_CFLAGS) -fno-pie -no-pie -I$(LUA_PREFIX)/include -Inative \
		tests/native/linux_perf_counts.c $(LUA_PREFIX)/lib/liblua.a -lm -ldl -o build/native-perf-counts-san/fixture
	@ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 build/native-perf-counts-san/fixture

endif

# The macOS packaging targets sit after the Linux ones, and that placement is
# load-bearing.  Make parses one platform branch and never sees a collision,
# but the release-evidence guards read a target's recipe out of the file text,
# where the first definition by that name is the one they find:
# tests/unit/test_release_evidence.lua asks for the recipe of `bundle-dir`
# without knowing which platform it runs on.  Defined up top, the macOS recipe
# was what every reader found, and the licence-copy clause failed on Linux
# while Linux make never even saw that rule.
ifeq ($(HOST_OS),Darwin)

.PHONY: bundle-dir bundle-file test-bundle-dir test-bundle-file test-bundles
bundle-dir: native
	@./tools/package_macos.sh dir
bundle-file: native
	@./tools/package_macos.sh file
test-bundle-dir: bundle-dir
	@python3 tests/installed_smoke.py --executable dist/macos-bundle/wtop/wtop \
		--version "$$(cat VERSION)" --platform Darwin
	@python3 tests/test_recording_replay.py --executable dist/macos-bundle/wtop/wtop
	@WTOP_EXECUTABLE='$(CURDIR)/dist/macos-bundle/wtop/wtop' WTOP_ROOT='$(CURDIR)' \
		WTOP_PTY_PROFILE=quick python3 tests/pty_smoke.py
test-bundle-file: bundle-file
	@python3 tests/installed_smoke.py --executable dist/macos-bundle/wtop-onefile \
		--version "$$(cat VERSION)" --platform Darwin
	@python3 tests/test_recording_replay.py --executable dist/macos-bundle/wtop-onefile
	@WTOP_EXECUTABLE='$(CURDIR)/dist/macos-bundle/wtop-onefile' WTOP_ROOT='$(CURDIR)' \
		WTOP_PTY_PROFILE=quick python3 tests/pty_smoke.py

test-bundles: test-bundle-dir test-bundle-file
	@python3 tools/check_macos.py --bundle dist/macos-bundle

endif

.PHONY: test-native-terminal-signals
test-native-terminal-signals: native
	@python3 tests/test_terminal_signals.py --cc "$(CC)" \
		--lua-prefix '$(or $(LUA_PREFIX),$(CURDIR)/.tools/lua-5.5.1)' \
		--output build/native-terminal-signals
