#!/usr/bin/env lua

local entry_path = tostring(arg and arg[0] or "")
local entry_dir = entry_path:match("^(.*)[/\\][^/\\]+$")
if entry_dir and entry_dir ~= "" then
    package.path = entry_dir .. "/?.lua;" .. entry_dir .. "/?/init.lua;" .. package.path
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
