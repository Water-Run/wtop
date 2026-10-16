#!/usr/bin/env lua

local entry_path = tostring(arg and arg[0] or "")
local entry_dir = entry_path:match("^(.*)[/\\][^/\\]+$")
if entry_dir and entry_dir ~= "" then
    package.path = entry_dir .. "/?.lua;" .. entry_dir .. "/?/init.lua;" .. package.path
    -- A source-tree relaunch through sudo deliberately drops LUA_CPATH. Keep
    -- the project-native module discoverable without trusting that variable.
    package.cpath = entry_dir .. "/../build/native/?.so;" .. package.cpath
end

local native = require("wtop.native")
-- The reader starts before the CLI and never opens a terminal session.
if arg and arg[1] == "--wtop-hardware-reader" and native.hardware_worker_run then
    require("wtop.core.hardware_worker") -- Include the reader graph in both bundle forms.
    os.exit(native.hardware_worker_run(table.unpack(arg, 2, #arg)), true)
end
if native.hardware_worker_configure then
    native.hardware_worker_sources = native.hardware_worker_configure(
        arg and rawget(arg, -1) ~= nil and entry_path or nil)
end

local cli = require("wtop.cli")
local ok, code_or_error = xpcall(function()
    return cli.run(arg)
end, debug.traceback)

if not ok then
    io.stderr:write("wtop: ", tostring(code_or_error), "\n")
    os.exit(1)
end

os.exit(tonumber(code_or_error) or 0, true)
