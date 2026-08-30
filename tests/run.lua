local files = {}
for index = 1, #arg do
    files[#files + 1] = arg[index]
end

if #files == 0 then
    io.stderr:write("wtop tests: no test files were provided\n")
    os.exit(2)
end

local failures = {}
for _, path in ipairs(files) do
    io.write(string.format("%-64s", path))
    io.flush()
    local ok, result = xpcall(function()
        local chunk, load_error = loadfile(path)
        assert(chunk, load_error)
        return chunk()
    end, debug.traceback)
    if ok then
        io.write(" ok\n")
    else
        io.write(" FAIL\n")
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
