-- Detail-mode memory composition: /proc/<pid>/smaps_rollup is read only for
-- the selected process, USS is derived from the private share, and the detail
-- overlay shows the figures next to the resident/virtual pair.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Process = require("wtop.collectors.process")
local Export = require("wtop.export")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local json = require("wtop.format.json")
local Parsers = require("wtop.linux.parsers")

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
  ["/proc/10/oom_score"] = "800\n",
  ["/proc/10/oom_score_adj"] = "200\n",
  ["/proc/10/limits"] = "Max open files 1024 4096 files\n",
  ["/proc/10/smaps_rollup"] = rollup({ rss = 2012, pss = 118, anon = 104,
    shared = 1908, clean = 0, dirty = 104 }),
  ["/proc/20/stat"] = stat_line(20, 7, 1),
  ["/proc/20/oom_score"] = "999\n",
  ["/proc/20/oom_score_adj"] = "500\n",
  ["/proc/20/smaps_rollup"] = rollup({ rss = 900, pss = 640, anon = 600,
    shared = 260, clean = 40, dirty = 600 }),
}
for path, value in pairs(detail_files(10)) do files[path] = value end
for path, value in pairs(detail_files(20)) do files[path] = value end
local dirs = {
  ["/proc"] = { "10", "20" },
  ["/proc/10/fd"] = { "0", "1", "2", "8" },
}

local now = 1000000000
local function context(fs, selected)
  return { fs = fs, now_ns = function() return now end, selected_process_ids = selected }
end
local collector = Process.new({ read_status = false })

local first = collector:sample(context(fake_fs(files, dirs), { ["10:5"] = true }))
assert(first.status == "ok", "fixture sample failed")
local selected_oom = first.data.by_id["10:5"].oom
assert(selected_oom and selected_oom.score == 800 and selected_oom.adjustment == 200
  and selected_oom.score_status == "ok" and selected_oom.adjustment_status == "ok")
assert(first.data.by_id["20:7"].oom == nil,
  "the ordinary process table must not read every process's OOM files")
local oom_detail = table.concat(TUI.process_detail_lines(first.data.by_id["10:5"],
  assert(I18n.new({ locale = "en-US" }))), "\n")
assert(oom_detail:find("OOM selection", 1, true)
  and oom_detail:find("OOM score", 1, true)
  and oom_detail:find("800", 1, true)
  and oom_detail:find("Score adjustment", 1, true)
  and oom_detail:find("200", 1, true))
local no_oom_files = {}
for path, value in pairs(files) do
  if not path:find("/oom_score", 1, true) then no_oom_files[path] = value end
end
local no_oom = Process.new({ read_status = false }):sample(
  context(fake_fs(no_oom_files, dirs), { ["10:5"] = true }))
assert(no_oom.data.by_id["10:5"].oom == nil,
  "kernels without OOM detail files still retain the selected process")
local malformed_files = {}
for path, value in pairs(files) do malformed_files[path] = value end
malformed_files["/proc/10/oom_score"] = "1001\n"
malformed_files["/proc/10/oom_score_adj"] = "-1001\n"
local malformed_oom = Process.new({ read_status = false }):sample(
  context(fake_fs(malformed_files, dirs), { ["10:5"] = true }))
assert(malformed_oom.data.by_id["10:5"].oom.score_status == "error"
  and malformed_oom.data.by_id["10:5"].oom.adjustment_status == "error"
  and malformed_oom.data.by_id["10:5"].oom.score == nil,
  "out-of-range OOM values cannot masquerade as ordinary scores")
local denied_base = fake_fs(files, dirs)
local denied_fs = {
  list = denied_base.list,
  read = function(_, path, limit)
    if path == "/proc/10/oom_score" then
      return nil, { kind = "denied", message = "permission denied", path = path }
    end
    return denied_base:read(path, limit)
  end,
}
local denied_oom = Process.new({ read_status = false }):sample(
  context(denied_fs, { ["10:5"] = true }))
assert(denied_oom.data.by_id["10:5"].oom.score_status == "denied"
  and denied_oom.data.by_id["10:5"].oom.adjustment == 200,
  "one denied OOM file must not hide the independently readable adjustment")
local denied_detail = table.concat(TUI.process_detail_lines(denied_oom.data.by_id["10:5"],
  assert(I18n.new({ locale = "en-US" }))), "\n")
assert(denied_detail:find("OOM score", 1, true)
  and denied_detail:find("Denied", 1, true),
  "an unreadable score needs an explicit localized state")
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
local fd = first.data.by_id["10:5"].fd_detail
assert(fd.status == "ok" and fd.count == 4
  and fd.limit_status == "ok" and fd.limit.soft == 1024
  and fd.limit.hard == 4096 and fd.observed_ns == now,
  "selected process detail pairs the observed FD count with its limits")
assert(first.data.by_id["20:7"].fd_detail == nil,
  "the ordinary process scan must not enumerate every PID's FD directory")
local base_fd_fs = fake_fs(files, dirs)
local truncated_fs = {
  read = base_fd_fs.read,
  list = function(self, path, limit)
    if path == "/proc/10/fd" then
      assert(limit == 4096, "the FD walk must have a fixed budget")
      return { "0", "1", "2", "8" }, nil, true
    end
    return base_fd_fs:list(path, limit)
  end,
}
local truncated = collector:sample(context(truncated_fs, { ["10:5"] = true }))
local truncated_fd = truncated.data.by_id["10:5"].fd_detail
assert(truncated_fd.count == 4 and truncated_fd.status == "truncated",
  "a capped FD walk is a lower bound, not an exact count")
local denied_fs = {
  read = base_fd_fs.read,
  list = function(self, path, limit)
    if path == "/proc/10/fd" then
      return nil, { kind = "denied", message = "fixture_denied", path = path }
    end
    return base_fd_fs:list(path, limit)
  end,
}
local denied_fd = collector:sample(context(denied_fs, { ["10:5"] = true }))
  .data.by_id["10:5"]
assert(denied_fd.fd_detail.status == "denied" and denied_fd.fd_detail.count == nil
  and denied_fd.partial ~= true,
  "an optional denied FD walk is not a count of zero or a failed process sample")
local no_limit_files = {}
for path, value in pairs(files) do no_limit_files[path] = value end
no_limit_files["/proc/10/limits"] = nil
local no_limit = collector:sample(context(fake_fs(no_limit_files, dirs),
  { ["10:5"] = true })).data.by_id["10:5"].fd_detail
assert(no_limit.count == 4 and no_limit.limit == nil
  and no_limit.limit_status == "unavailable",
  "an absent limits file does not erase the independently readable FD count")
local bad_limit_files = {}
for path, value in pairs(files) do bad_limit_files[path] = value end
bad_limit_files["/proc/10/limits"] = "Max open files 4096 1024 files\n"
local bad_limit = collector:sample(context(fake_fs(bad_limit_files, dirs),
  { ["10:5"] = true })).data.by_id["10:5"].fd_detail
assert(bad_limit.count == 4 and bad_limit.limit == nil
  and bad_limit.limit_status == "error",
  "a malformed limit cannot become a plausible quota or hide a readable count")

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
  fd_detail = fd,
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
local fd_index, fd_row = row_index("打开的文件描述符")
local limit_index, limit_row = row_index("文件描述符上限")
assert(fd_index > threads_index and limit_index > fd_index
  and fd_row:find("首线程打开的文件描述符", 1, true)
  and fd_row:find("4", 1, true) and limit_row:find("1024 / 4096", 1, true),
  "leader FD use and soft/hard limits appear together in selected-process resources")
local truncated_lines = table.concat(TUI.process_detail_lines({
  pid = 20, id = "20:7", name = "shared", fd_detail = truncated_fd,
}, translator), "\n")
assert(truncated_lines:find(">=4", 1, true),
  "a capped FD count is labelled as a lower bound")
local denied_lines = table.concat(TUI.process_detail_lines({
  pid = 20, id = "20:7", name = "shared", fd_detail = denied_fd.fd_detail,
}, translator), "\n")
assert(denied_lines:find("无权限", 1, true)
  and not denied_lines:find("打开的文件描述符%s+0"),
  "an unreadable FD directory is shown as denied, never as zero")
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
  fd_detail = fd,
  oom = { score = 800, adjustment = 200, score_status = "ok" },
} } } }, { process_limit = 1 })
local encoded = json.encode(exported)
assert(not encoded:find("memory_detail", 1, true) and not encoded:find("pss_anon", 1, true),
  "snapshot JSON must not carry detail-mode memory internals")
assert(not encoded:find("fd_detail", 1, true),
  "snapshot JSON must not claim a detail-only FD observation")
assert(not encoded:find('"oom"', 1, true),
  "snapshot JSON must not claim a detail-only OOM observation")

-- numa_maps reports counts in each mapping's page size.  A huge-page row
-- cannot be multiplied by the ordinary base page size.
local maps = table.concat({
  "1000 default file=/private/path N1=2 N0=1 kernelpagesize_kB=4",
  "2000 bind:1 huge anon=1 N1=1 kernelpagesize_kB=2048",
  "3000 default N0=3", -- older kernel: ordinary page size omitted
}, "\n") .. "\n"
local placement = assert(Parsers.process_numa_maps(maps, 4096))
assert(placement.nodes[1].node_id == 0 and placement.nodes[1].mapped_bytes == 4 * 4096,
  "node zero combines the explicit and base-sized ordinary pages")
assert(placement.nodes[2].node_id == 1
    and placement.nodes[2].mapped_bytes == 2 * 4096 + 2048 * 1024,
  "huge pages use their own size")
assert(placement.total_mapped_bytes == 4 * 4096 + 2 * 4096 + 2048 * 1024)
assert(Parsers.process_numa_maps("1000 default huge N0=1\n", 4096) == nil,
  "a huge mapping without a size cannot be guessed")
assert(Parsers.process_numa_maps("1000 default N0=9223372036854775807\n", 4096) == nil,
  "overflow cannot wrap a mapped-byte count")
local empty_maps = assert(Parsers.process_numa_maps("", 4096))
assert(empty_maps.total_mapped_bytes == 0 and #empty_maps.nodes == 0,
  "a process without user mappings has zero mapped pages")

local numa_files = {}
for path, value in pairs(files) do numa_files[path] = value end
numa_files["/proc/10/numa_maps"] = maps
local numa_reads, last_limit = 0, nil
local base_fs = fake_fs(numa_files, dirs)
local counted_fs = {
  list = base_fs.list,
  read = function(_, path, limit)
    if path == "/proc/10/numa_maps" then
      numa_reads, last_limit = numa_reads + 1, limit
    end
    return base_fs:read(path, limit)
  end,
}
local numa_collector = Process.new({ read_status = false })
local selected = context(counted_fs, { ["10:5"] = true })
numa_collector:sample(selected)
assert(numa_reads == 0, "table selection alone does not scan numa_maps")
selected.selected_process_numa_ids = { ["10:5"] = true }
selected.selected_process_numa_ids["20:7"] = true
numa_collector:sample(selected)
assert(numa_reads == 0, "an ambiguous selection cannot trigger many VMA scans")
selected.selected_process_numa_ids["20:7"] = nil
local placed = numa_collector:sample(selected)
local placed_process = placed.data.by_id["10:5"]
assert(numa_reads == 1 and last_limit == 2 * 1024 * 1024,
  "the open detail requests one bounded VMA scan")
assert(placed_process.numa_detail.total_mapped_bytes == placement.total_mapped_bytes)
assert(placed.data.by_id["20:7"].numa_detail == nil,
  "other processes remain unscanned")
now = now + 1000000000
local cached_placement = numa_collector:sample(selected, placed)
assert(numa_reads == 1 and cached_placement.data.by_id["10:5"].numa_detail,
  "the next tick reuses the same identity's placement")
now = now + 10000000000
numa_collector:sample(selected, cached_placement)
assert(numa_reads == 2, "placement refreshes after ten seconds")

local numa_lines = TUI.process_detail_lines(placed_process, translator)
local numa_text = table.concat(numa_lines, "\n")
assert(numa_text:find("各 NUMA 节点的映射页", 1, true)
  and numa_text:find("节点 1", 1, true)
  and numa_text:find("共享页", 1, true),
  "the detail labels the node values and their shared-page semantics")
assert(not numa_text:find("/private/path", 1, true),
  "VMA backing paths never enter the overlay")
local numa_export = Export.snapshot({ processes = { list = { placed_process } } },
  { process_limit = 1 })
local numa_json = json.encode(numa_export)
assert(not numa_json:find("numa_detail", 1, true)
  and not numa_json:find("/private/path", 1, true),
  "snapshot JSON does not include detail-only placement or mapping paths")

local absent_numa = {}
for path, value in pairs(numa_files) do absent_numa[path] = value end
absent_numa["/proc/10/numa_maps"] = nil
local missing_fs = fake_fs(absent_numa, dirs)
local missing_context = context(missing_fs, { ["10:5"] = true })
missing_context.selected_process_numa_ids = { ["10:5"] = true }
local missing = Process.new({ read_status = false }):sample(missing_context)
local missing_process = missing.data.by_id["10:5"]
assert(missing_process.numa_status == "unavailable" and missing_process.partial ~= true,
  "a missing optional numa_maps section does not degrade the process sample")
local missing_text = table.concat(TUI.process_detail_lines(missing_process, translator), "\n")
assert(missing_text:find("各 NUMA 节点的映射页", 1, true),
  "an unavailable source is identified in the process detail")

local reused_files = {}
for path, value in pairs(numa_files) do reused_files[path] = value end
reused_files["/proc/10/stat"] = stat_line(10, 6, 2)
local reused_reads = 0
local reused_base = fake_fs(reused_files, dirs)
local reused_fs = {
  list = reused_base.list,
  read = function(_, path, limit)
    if path == "/proc/10/numa_maps" then reused_reads = reused_reads + 1 end
    return reused_base:read(path, limit)
  end,
}
local reused_context = context(reused_fs, { ["10:6"] = true })
reused_context.selected_process_numa_ids = { ["10:6"] = true }
local reused = numa_collector:sample(reused_context, placed)
assert(reused.data.by_id["10:6"].numa_detail and reused_reads == 1,
  "a recycled PID gets its own placement rather than the previous identity's cache")

print("ok: process detail memory and NUMA placement (collector, overlay, export boundary)")
return true
