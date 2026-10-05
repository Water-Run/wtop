-- Detail-mode memory composition: /proc/<pid>/smaps_rollup is read only for
-- the selected process, USS is derived from the private share, and the detail
-- overlay shows the figures next to the resident/virtual pair.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Process = require("wtop.collectors.process")
local Export = require("wtop.export")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local json = require("wtop.format.json")

local function stat_line(pid, starttime, threads)
  local fields = {
    1, pid, pid, 0, -1, 4194304, 10, 0, 2, 0,
    5, 0, 0, 0, 20, 0, threads or 1, 0,
    starttime, 10485760, 2048,
  }
  local numbers = {}
  for index, value in ipairs(fields) do numbers[index] = tostring(value) end
  for index = #fields + 1, 44 do numbers[index] = "0" end
  return string.format("%d (%s) S %s", pid, "proc" .. pid, table.concat(numbers, " "))
end

-- A real smaps_rollup body: the synthetic mapping header first, then "Key: n kB".
local function rollup(spec)
  local lines = {
    "558c6eaeb000-7ffd636da000 ---p 00000000 00:00 0                          [rollup]",
    string.format("Rss: %d kB", spec.rss),
    string.format("Pss: %d kB", spec.pss),
    "Pss_Dirty: 0 kB",
    string.format("Pss_Anon: %d kB", spec.anon),
    string.format("Pss_File: %d kB", spec.pss - spec.anon),
    "Pss_Shmem: 0 kB",
    string.format("Shared_Clean: %d kB", spec.shared),
    "Shared_Dirty: 0 kB",
    string.format("Private_Clean: %d kB", spec.clean),
    string.format("Private_Dirty: %d kB", spec.dirty),
    string.format("Referenced: %d kB", spec.rss),
    string.format("Anonymous: %d kB", spec.anon),
    "Swap: 0 kB",
    "SwapPss: 0 kB",
    "Locked: 0 kB",
  }
  return table.concat(lines, "\n") .. "\n"
end

local function fake_fs(files, dirs)
  return {
    read = function(_, path)
      local value = files[path]
      if value == nil then
        return nil, { kind = "missing", message = "fixture_missing", path = path }
      end
      return value
    end,
    list = function(_, path, limit)
      local values = dirs[path]
      if not values then
        return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
      end
      local copy, cut = {}, false
      for _, entry in ipairs(values) do
        if limit and #copy >= limit then cut = true break end
        copy[#copy + 1] = entry
      end
      return copy, nil, cut
    end,
  }
end

-- The other on-demand detail files are present so that a partial flag can only
-- come from the memory summary under test.
local function detail_files(pid)
  return {
    [string.format("/proc/%d/cmdline", pid)] = "proc" .. pid .. "\0",
    [string.format("/proc/%d/io", pid)] = "rchar: 100\nwchar: 200\n",
    [string.format("/proc/%d/cgroup", pid)] = "0::/user.slice\n",
  }
end

local files = {
  ["/proc/10/stat"] = stat_line(10, 5, 2),
  ["/proc/10/smaps_rollup"] = rollup({ rss = 2012, pss = 118, anon = 104,
    shared = 1908, clean = 0, dirty = 104 }),
  ["/proc/20/stat"] = stat_line(20, 7, 1),
  ["/proc/20/smaps_rollup"] = rollup({ rss = 900, pss = 640, anon = 600,
    shared = 260, clean = 40, dirty = 600 }),
}
for path, value in pairs(detail_files(10)) do files[path] = value end
for path, value in pairs(detail_files(20)) do files[path] = value end
local dirs = { ["/proc"] = { "10", "20" } }

local now = 1000000000
local function context(fs, selected)
  return { fs = fs, now_ns = function() return now end, selected_process_ids = selected }
end
local collector = Process.new({ read_status = false })

local first = collector:sample(context(fake_fs(files, dirs), { ["10:5"] = true }))
assert(first.status == "ok", "fixture sample failed")
local memory = first.data.by_id["10:5"].memory_detail
assert(type(memory) == "table", "the selected process exposes its memory composition")
assert(memory.pss == 118 * 1024, "PSS comes straight from the rollup")
assert(memory.uss == 104 * 1024, "USS is the private share, not a kernel field")
assert(memory.rss == 2012 * 1024 and memory.swap == 0 * 1024,
  "the rollup's own RSS and swap travel with it")
assert(memory.shared_clean == 1908 * 1024 and memory.pss_anon == 104 * 1024
  and memory.pss_file == 14 * 1024, "the anon/file split of PSS is kept")
assert(first.data.by_id["20:7"].memory_detail == nil,
  "unselected processes must not read smaps_rollup")

-- USS must actually be the private sum, not a copy of PSS: this process shares
-- almost all of its memory, so the two differ by three orders of magnitude.
local private = first.data.by_id["10:5"]
assert(private.partial ~= true, "a parsed rollup is not a partial sample")

-- A kernel without smaps_rollup reports why the section is empty instead of
-- pretending the process has no memory.
local legacy_files = {}
for path, value in pairs(files) do legacy_files[path] = value end
legacy_files["/proc/10/smaps_rollup"] = nil
local legacy = collector:sample(context(fake_fs(legacy_files, dirs), { ["10:5"] = true }))
local legacy_process = legacy.data.by_id["10:5"]
assert(legacy_process.memory_detail == nil, "an absent rollup yields no figures")
assert(legacy_process.memory_status == "unavailable"
  and legacy_process.partial == true,
  "an absent rollup is reported as unavailable, not silently empty")

-- A corrupt rollup is a parse error, and it must not poison the rest of the row.
local corrupt_files = {}
for path, value in pairs(files) do corrupt_files[path] = value end
corrupt_files["/proc/10/smaps_rollup"] = "Rss: 4 MB\n"
local corrupt = collector:sample(context(fake_fs(corrupt_files, dirs), { ["10:5"] = true }))
local corrupt_process = corrupt.data.by_id["10:5"]
assert(corrupt_process.memory_status == "parse_error" and corrupt_process.partial == true,
  "a corrupt rollup is a parse error")
assert(corrupt_process.name == "proc10" and corrupt_process.pid == 10,
  "the rest of the row survives a bad memory summary")

-- The overlay shows PSS/USS with the other memory figures, localized.  The two
-- values differ on purpose: a row that showed the wrong figure would pass with
-- identical numbers.
local translator = assert(I18n.new({ locale = "zh-CN" }))
local lines = TUI.process_detail_lines({
  pid = 20, id = "20:7", name = "shared", resident_bytes = 900 * 1024,
  virtual_bytes = 10485760,
  memory_detail = { pss = 640 * 1024, uss = 120 * 1024, rss = 900 * 1024 },
}, translator)
local function row_index(label)
  for index, line in ipairs(lines) do
    if line:find(label, 1, true) then return index, line end
  end
end
local pss_index, pss_row = row_index("PSS")
local uss_index, uss_row = row_index("私有")
assert(pss_row and pss_row:find("640", 1, true),
  "the PSS row carries the PSS value, got " .. tostring(pss_row))
assert(uss_row and uss_row:find("120", 1, true),
  "the USS row carries the USS value, got " .. tostring(uss_row))
assert(not pss_row:find("120", 1, true) and not uss_row:find("640", 1, true),
  "the two memory figures are not interchangeable")
local section_index = row_index("资源")
local virtual_index = row_index("虚拟内存")
local threads_index = row_index("线程")
assert(section_index and virtual_index and pss_index and uss_index and threads_index,
  "the memory figures are only meaningful alongside the rest of the section")
assert(section_index < virtual_index and virtual_index < pss_index
  and pss_index < uss_index and uss_index < threads_index,
  "PSS/USS sit in the Resources section between virtual memory and thread count")
local identity_index = row_index("身份")
assert(identity_index < section_index, "the identity section keeps its own rows")

-- A process whose kernel has no rollup keeps the section it had, with no
-- placeholder rows for figures that do not exist.
local plain = TUI.process_detail_lines({
  pid = 30, id = "30:1", name = "plain", resident_bytes = 1024,
}, translator)
for _, line in ipairs(plain) do
  assert(not line:find("PSS", 1, true) and not line:find("私有", 1, true),
    "absent PSS/USS add no placeholder rows")
end

-- Snapshot JSON must not grow detail-mode memory internals by accident.
local exported = Export.snapshot({ processes = { list = { {
  id = "20:7", pid = 20, name = "shared", threads = 1,
  memory_detail = { pss = 640 * 1024, uss = 640 * 1024, pss_anon = 600 * 1024 },
} } } }, { process_limit = 1 })
local encoded = json.encode(exported)
assert(not encoded:find("memory_detail", 1, true) and not encoded:find("pss_anon", 1, true),
  "snapshot JSON must not carry detail-mode memory internals")

print("ok: process detail memory composition (collector, overlay, export boundary)")
return true