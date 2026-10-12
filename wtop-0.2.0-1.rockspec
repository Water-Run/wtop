-- Generated from wtop-scm-1.rockspec and VERSION; DO NOT EDIT.
rockspec_format = "3.0"
package = "wtop"
version = "0.2.0-1"

source = {
    url = "git+https://github.com/Water-Run/wtop.git",
    tag = "v0.2.0",
    dir = "wtop",
}

description = {
    summary = "Responsive Linux observability TUI",
    detailed = [[
        wtop (WaterRun's top) is a Linux-only terminal performance workbench.
        It observes CPU, memory, pressure, storage, networking, processes,
        cgroup v2, hwmon, CPU frequency, and DRM GPU data through procfs and
        sysfs. It includes responsive layouts, JSON snapshot and agent output,
        capability diagnostics, internationalization, and a small C17 native
        module for terminal and operating-system primitives.
    ]],
    homepage = "https://github.com/Water-Run/wtop",
    issues_url = "https://github.com/Water-Run/wtop/issues",
    license = "EUPL-1.2",
    maintainer = "WaterRun <linzhangrun49@gmail.com>",
    labels = {
        "linux",
        "monitoring",
        "observability",
        "tui",
        "system-monitor",
    },
}

supported_platforms = {
    "linux",
}

dependencies = {
    "lua >= 5.5, < 5.6",
}

build = {
    type = "make",
    build_target = "rock-build",
    install_target = "rock-install",
    build_variables = {
        CFLAGS = "$(CFLAGS)",
        LUA_INCDIR = "$(LUA_INCDIR)",
    },
    install_variables = {
        BINDIR = "$(BINDIR)",
        CFLAGS = "$(CFLAGS)",
        LIBDIR = "$(LIBDIR)",
        LUA_INCDIR = "$(LUA_INCDIR)",
        LUADIR = "$(LUADIR)",
        PREFIX = "$(PREFIX)",
    },
}
