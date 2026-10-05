package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local diagnose = require("wtop.diagnose")
local native = require("wtop.native")

local report = diagnose.collect({
    safe_mode = true,
    privilege = {
        mode = "root", uid = 0, effective_uid = 0, original_uid = 1000,
        root = true, elevated = true, via_sudo = true, requested = true,
    },
})
assert(report.application.name == "wtop")
assert(report.platform.sysname == "Linux" or report.platform.sysname == "unknown")
assert(report.sources.proc_stat.state == "available")
assert(report.sources.proc_cpuinfo.state == "available")
assert(report.sources.proc_meminfo.state == "available")
assert(type(report.sources.sys_hwmon.state) == "string")
assert(type(report.sources.sys_powercap.state) == "string")
assert(report.helpers.smartctl.state == "disabled")
assert(type(report.terminal.stdin_tty) == "boolean")
assert(report.identity.mode == "root" and report.identity.root == true)
assert(report.identity.elevated == true and report.identity.via_sudo == true)
assert(report.identity.original_uid == 1000 and report.identity.requested == true)

-- The GPU vendor section answers "can wtop reach this backend", which is not
-- the question the helper list answers.  wtop never runs `rocm-smi` or
-- `nvidia-smi` -- there is no process execution anywhere in the source -- it
-- dlopens the vendor library, so on a host with the command-line tool present
-- and the library absent the helper line reads `available` while wtop has no
-- backend at all.  That is this machine's exact shape.
--
-- Both halves below interrogate the native dlopen probes: safe mode expects
-- the probe to have been *skipped*, and the unsafe pass expects it to have
-- reached a verdict.  Without a built module neither state can occur -- the
-- report answers with the module's own absence -- so the section says so
-- instead of asserting against a fallback (a stated skip in the one suite
-- that builds nothing, a failure everywhere else).
if require("support.artifacts").require_condition(native.available,
        "the native module", "run `make native`") then
assert(type(report.gpu_vendors) == "table", "the vendor section exists")
for _, key in ipairs({ "nvml", "amdsmi", "levelzero" }) do
    local vendor = report.gpu_vendors[key]
    assert(vendor, "the vendor section names " .. key)
    assert(type(vendor.state) == "string" and vendor.state ~= "",
        key .. " has a state")
    assert(type(vendor.library) == "string" and vendor.library:match("^lib.*%.so"),
      key .. " names the library it dlopens, not a guessed path: " .. tostring(vendor.library))
end
-- Safe mode must not dlopen a third-party vendor library, exactly as it does not
-- run a helper: a diagnostic that loads vendor code in safe mode would defeat
-- the mode.  The state says so rather than reporting the probe's own finding.
assert(report.gpu_vendors.nvml.state == "skipped", "safe mode skips the probe")
assert(report.gpu_vendors.nvml.reason == "safe_mode", "and says why")
assert(report.gpu_vendors.amdsmi.state == "skipped", "for every vendor")
-- A reason is only meaningful alongside a library name, and "unavailable" alone
-- cannot be told apart from a host that simply has no such GPU.
if report.gpu_vendors.amdsmi.state == "unavailable" then
    assert(type(report.gpu_vendors.amdsmi.reason) == "string",
      "an unavailable vendor carries the reason the native layer gave")
end

-- The same section without safe mode, which is where the probe actually runs.
-- The states are host-specific -- a machine with an NVIDIA driver installed gets
-- a different answer -- so the assertions are about the shape of any answer
-- rather than one of them, plus the one fact that is the same everywhere: the
-- probe reached a verdict rather than giving up.
local probed = diagnose.collect({})
for key, vendor in pairs(probed.gpu_vendors) do
    assert(vendor.state ~= "skipped",
      key .. " is probed when safe mode is off")
    if vendor.state == "available" or vendor.state == "loaded" then
        assert(type(vendor.devices) == "number",
        key .. " reports how many devices the backend then found")
    end
end
end -- native module present: vendor probe states

-- The helper list answers "which external command can this build actually run".
--
-- It used to answer a different one.  Six of its ten entries were binaries wtop
-- never executes -- `nvidia-smi` and `rocm-smi` superseded by the dlopened
-- libraries, `intel_gpu_top` and `sensors` by the i915 and hwmon reads wtop
-- does itself, `ss` by the `/proc/net` tables, and `lspci` by the `pci.ids`
-- database -- so a host could be told its PCI tooling was missing while its
-- names resolved, or reassured about `lspci` while having no names at all.
--
-- Each surviving entry is the command one inspector runs: `smartctl` and `nvme`
-- from the storage inspector, `perf` from the bandwidth inspector, `systemctl`
-- from the service inspector.  The list is pinned, because there is no
-- declarative registry of inspector tools to derive it from -- the argv arrays
-- are built inline -- so a new inspector has to add its command here.
for _, helper in ipairs({ "smartctl", "nvme", "perf", "systemctl" }) do
  assert(report.helpers[helper], "the helper list names " .. helper)
end
for _, absent in ipairs({ "lspci", "nvidia-smi", "rocm-smi", "intel_gpu_top",
                          "ss", "sensors" }) do
  assert(report.helpers[absent] == nil,
    "the helper list still reports a command wtop never runs: " .. absent)
end
-- And the mechanical half: nothing may be listed that no collector or inspector
-- even names.  The match is a loose substring search, which is why it is only
-- asserted in this direction -- "perf" is a substring of "performance" and will
-- pass on its own, but a name appearing nowhere outside the diagnostic is
-- certainly a tool nothing runs.
for name in pairs(report.helpers) do
  local found = false
  for _, path in ipairs({
    "src/wtop/inspectors/smart.lua", "src/wtop/inspectors/perf_bandwidth.lua",
    "src/wtop/inspectors/ram_bandwidth.lua", "src/wtop/inspectors/service.lua",
  }) do
    local handle = io.open(path, "rb")
    if handle then
      if handle:read("*a"):find(name, 1, true) then found = true end
      handle:close()
    end
  end
  assert(found, "the helper list reports " .. name .. ", which no inspector names")
end

-- The PCI name database is a *source*, and the one decide whether the GPU table
-- says "Intel Corporation" or leaves the cell blank.  It is probed at the path
-- it was found, not at a location guessed here, so the two cannot drift apart.
local PciNames = require("wtop.linux.pci_names")
assert(report.sources.pci_ids, "the PCI name database is probed as a source")
assert(type(report.sources.pci_ids.state) == "string" and
       report.sources.pci_ids.state ~= "",
  "the PCI name database reports a state")
local known = {}
for _, path in ipairs(PciNames.DEFAULT_PATHS) do known[path] = true end
assert(known[report.sources.pci_ids.path],
  "the reported path is one wtop actually searches: " .. tostring(report.sources.pci_ids.path))

-- Which clock the monitor times against.  This is not the same fact as
-- `sources.proc_uptime` above, which says whether the file is readable at the
-- moment the diagnostic runs: the clock is a process-wide instance that has
-- already been sampling, and a read that has started failing leaves it on a
-- fallback or holding a stale value for as long as the failure lasts.  The line
-- was added because `Clock:source_name` had no caller at all -- not in the UI,
-- not here, not in the docs -- and a label nobody reads protects nobody.  This
-- assertion is the reason it is not dead code now: removing the line, or
-- renaming the source, breaks it.
-- It is a *measured* source rather than a remembered one, and that is why the
-- check above is not vacuous: `diagnose.collect` takes a reading before
-- reporting, so the value is never absent.  A diagnostic that reported the
-- clock's state without reading would say "no source" on every host, because
-- nothing has sampled yet in a process that only runs `--diagnose` -- and an
-- absent source would satisfy a weaker assertion, which is why the vocabulary
-- is a closed set rather than "any string".
local SOURCES = {
    procfs_uptime = true,          -- a reading from /proc/uptime
    process_clock_fallback = true, -- a reading the fallback produced
    held = true,                   -- the previous value, the new one being older
    unavailable = true,            -- nothing measured, nothing measurable
}
assert(type(report.clock) == "table" and type(report.clock.source) == "string",
  "the diagnostic does not report which clock the monitor is using, so a user "
    .. "whose rates have frozen has nowhere to look: a clock holding a stale "
    .. "value is indistinguishable from one reading /proc/uptime")
assert(SOURCES[report.clock.source],
  "the diagnostic reports a clock source of " .. tostring(report.clock.source)
    .. ", which is not one this project defines.  The four names are the whole "
    .. "vocabulary: a procfs reading, a fallback reading, a value being held "
    .. "because the new one was older, and no reading at all.")
-- `unavailable` is in the vocabulary but cannot be the answer *from here*.
-- `collect` takes a reading before reporting, and the default fallback is
-- `os.clock`, which cannot fail -- so the only way to reach it is a clock that
-- has never measured.  Without this, "report the source without reading it"
-- passes, because the name for "I have nothing" is itself a legal name.
assert(report.clock.source ~= "unavailable",
  "the diagnostic reports `unavailable`, which means the clock it asked never "
    .. "took a reading: `collect` reads /proc/uptime before reporting the "
    .. "source, and the default fallback cannot fail, so on any host this "
    .. "report describes a reading that was never taken")

-- And the text the human actually reads carries it too.  The data assertions
-- above pass whether or not the line is printed, which is how a diagnostic can
-- report a fact in its JSON and not in the output a person sees.
local printed = {}
local real_write = io.write
io.write = function(...) for _, part in ipairs({ ... }) do printed[#printed + 1] = tostring(part) end end
local ran_ok, ran_error = pcall(diagnose.run, {})
io.write = real_write
assert(ran_ok, "the text diagnostic did not run: " .. tostring(ran_error))
local text = table.concat(printed)
assert(text:find("Clock:", 1, true) ~= nil,
  "the text diagnostic does not print a clock line, so a user reading it has "
    .. "no way to learn which clock the monitor is timing against -- the fact "
    .. "is in the report and nowhere on screen")
assert(text:find(report.clock.source, 1, true) ~= nil,
  "the text diagnostic prints a clock line that does not carry the source it "
    .. "just measured: " .. report.clock.source)

return true
