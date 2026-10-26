-- Embed the transitive, literal require graph of the hardware entry point.
local targets = { "wtop.core.hardware_worker", "wtop.native", "wtop.collectors.hwmon",
    "wtop.collectors.cppc", "wtop.collectors.cpufreq", "wtop.collectors.powercap", "wtop.collectors.cpu_limits",
    "wtop.collectors.thermal_throttle", "wtop.collectors.cpuidle", "wtop.collectors.thermal_zones",
    "wtop.collectors.smbios_input", "wtop.collectors.gpu_drm", "wtop.collectors.cpu_clocks", "wtop.collectors.cpuid",
    "wtop.collectors.portable", "wtop.collectors.linux_nvme", "wtop.platform" }
local seen, modules = {}, {}
local function visit(name)
    if seen[name] or name == "wtop_native" then return end
    seen[name] = true
    local path = "src/" .. name:gsub("%.", "/") .. ".lua"
    local f = assert(io.open(path, "rb"), path)
    local source = assert(f:read("a")); assert(f:close())
    modules[#modules + 1] = { name = name, source = source }
    for dependency in source:gmatch("require%s*%(%s*[\"']([%w_%.]+)[\"']%s*%)") do visit(dependency) end
end
for _, name in ipairs(targets) do visit(name) end
table.sort(modules, function(a,b) return a.name < b.name end)
local out = assert(io.open(assert(arg[1]), "wb"))
out:write("/* Generated hardware worker modules. */\n")
for i, entry in ipairs(modules) do
    out:write("static const unsigned char hardware_lua_", i, "[] = {\n")
    for p = 1, #entry.source, 32 do
        for q = p, math.min(p + 31, #entry.source) do out:write(entry.source:byte(q), ",") end
        out:write("\n")
    end
    out:write("};\n")
end
out:write("static const struct { const char *name; const unsigned char *source; size_t size; } hardware_modules[] = {\n")
for i, entry in ipairs(modules) do
    out:write(string.format('{"%s", hardware_lua_%d, sizeof(hardware_lua_%d)},\n', entry.name, i, i))
end
out:write("};\n"); assert(out:close())
