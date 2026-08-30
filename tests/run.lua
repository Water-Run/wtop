local files = {}
for index = 1, #arg do
    files[#files + 1] = arg[index]
end

if #files == 0 then
    io.stderr:write("wtop tests: no test files were provided\n")
    os.exit(2)
end

local failures = {}
local baseline_path = package.path
local baseline_cpath = package.cpath
local baseline_loaded = {}
local baseline_preload = {}
for name, value in pairs(package.loaded) do baseline_loaded[name] = value end
for name, value in pairs(package.preload) do baseline_preload[name] = value end

local function restore_map(target, baseline)
    for name in pairs(target) do
        if baseline[name] == nil then target[name] = nil end
    end
    for name, value in pairs(baseline) do target[name] = value end
end

local function isolate_next_file()
    package.path = baseline_path
    package.cpath = baseline_cpath
    restore_map(package.loaded, baseline_loaded)
    restore_map(package.preload, baseline_preload)
    -- File-level fixtures are intentionally independent. Collecting here keeps
    -- a long suite from retaining failed fixture graphs until process exit.
    collectgarbage("collect")
end

for _, path in ipairs(files) do
    io.write(string.format("%-64s", path))
    io.flush()
    local started = os.clock()
    local ok, result = xpcall(function()
        local chunk, load_error = loadfile(path)
        assert(chunk, load_error)
        return chunk()
    end, debug.traceback)
    local elapsed = os.clock() - started
    isolate_next_file()
    if ok then
        io.write(string.format(" ok  %7.3fs\n", elapsed))
    else
        io.write(string.format(" FAIL %7.3fs\n", elapsed))
        failures[#failures + 1] = { path = path, message = result }
    end
end

if #failures > 0 then
    io.stderr:write("\n")
    for _, failure in ipairs(failures) do
        io.stderr:write("--- ", failure.path, "\n", failure.message, "\n")
    end
    io.stderr:write(string.format("\n%d/%d test files failed\n", #failures, #files))
    os.exit(1)
end

io.write(string.format("\n%d test files passed\n", #files))
