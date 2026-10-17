-- PID namespace nesting.  NSpid arrives with the status file the base scan
-- reads anyway, so a process inside a container can be recognised, shown and
-- searched for without any extra procfs read.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Process = require("wtop.collectors.process")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Controller = require("wtop.model.process_table")
local json = require("wtop.format.json")
local Export = require("wtop.export")

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

local function status_with(nspid, nstgid)
  local lines = { "Name:\tx", "Uid:\t0\t0\t0\t0", "VmRSS:\t2048 kB",
    "voluntary_ctxt_switches:\t4", "nonvoluntary_ctxt_switches:\t1" }
  if nspid then lines[#lines + 1] = "NSpid:\t" .. nspid end
  if nstgid then lines[#lines + 1] = "NStgid:\t" .. nstgid end
  return table.concat(lines, "\n") .. "\n"
end

local function detail_files(pid)
  return {
    [string.format("/proc/%d/cmdline", pid)] = "proc" .. pid .. "\0",
    [string.format("/proc/%d/io", pid)] = "rchar: 10\nwchar: 20\n",
    [string.format("/proc/%d/cgroup", pid)] = "0::/system.slice\n",
  }
end

-- A container init, a host process and something nested twice.
local files = {
  ["/proc/10/stat"] = stat_line(10, 5, 1),
  ["/proc/10/status"] = status_with("10\t1", "10\t1"),
  ["/proc/20/stat"] = stat_line(20, 7, 1),
  ["/proc/20/status"] = status_with("20", "20"),
  ["/proc/30/stat"] = stat_line(30, 9, 1),
  ["/proc/30/status"] = status_with("30\t8\t3", "30\t8\t3"),
}
for _, pid in ipairs({ 10, 20, 30 }) do
  for path, value in pairs(detail_files(pid)) do files[path] = value end
end
local dirs = { ["/proc"] = { "10", "20", "30" } }

local fs = fake_fs(files, dirs)
local collector = Process.new({})
local result = collector:sample({ fs = fs,
  now_ns = function() return 0 end, selected_process_ids = nil })
assert(result.status == "ok", "fixture sample failed")

local container = result.data.by_id["10:5"]
assert(container.namespaces, "a namespaced process carries namespace info")
assert(container.namespaces.namespaced == true, "a two-entry chain means nested")
assert(container.namespaces.inner_pid == 1,
  "the last entry is the id the process knows itself by")
assert(container.namespaces.procfs_pid == 10 and container.namespaces.host_pid == nil,
  "the first entry is procfs-relative, without an initial-host claim")
assert(#container.namespaces.nspid == 2 and #container.namespaces.nstgid == 2)

local host = result.data.by_id["20:7"]
assert(host.namespaces and host.namespaces.namespaced == false,
  "a single-entry chain has no nesting visible from this procfs mount")
assert(host.namespaces.inner_pid == 20, "and its inner id is its own")

local nested = result.data.by_id["30:9"]
assert(nested.namespaces.namespaced == true and nested.namespaces.inner_pid == 3,
  "three levels of nesting still report the innermost id")
assert(nested.namespaces.procfs_pid == 30, "and the procfs-relative id")


-- Namespace membership stays stable between ordinary refreshes. Reusing it
-- must not introduce another status read or alter the PID used for actions.
local status_reads = 0
local original_read = fs.read
fs.read = function(self, path)
  if path:match("/status$") then status_reads = status_reads + 1 end
  return original_read(self, path)
end
local cached = collector:sample({ fs = fs,
  now_ns = function() return 1000000000 end }, result)
assert(status_reads == 0, "cached namespaces add no status I/O")
for _, id in ipairs({ "10:5", "20:7", "30:9" }) do
  local before, after = result.data.by_id[id], cached.data.by_id[id]
  assert(after.namespaces.inner_pid == before.namespaces.inner_pid
    and after.namespaces.procfs_pid == before.pid,
    "namespace metadata survives the next tick")
  assert(after.pid == before.pid and after.id == id,
    "namespace IDs do not redirect the process identity used by actions")
end
local cached_controller = Controller.new({})
cached_controller:update(cached.data.list); cached_controller:set_query("ns:1")
assert(#cached_controller:rows() == 1 and cached_controller:rows()[1].pid == 10,
  "inner-ID search still works after a cached refresh")
local cached_export = json.encode(Export.snapshot({ processes = { list = cached.data.list } }))
assert(cached_export:find('"inner_pid":1', 1, true), "cached namespace IDs remain exportable")

-- A selected detail refresh may lose its status data. Drop the old claim
-- rather than letting stale metadata masquerade as a successful new read.
local original_status = files["/proc/10/status"]
files["/proc/10/status"] = "NSpid: -1\n"
local invalid = collector:sample({ fs = fs, selected_process_ids = { ["10:5"] = true },
  now_ns = function() return 2000000000 end }, cached)
assert(invalid.data.by_id["10:5"].namespaces == nil
  and invalid.data.by_id["10:5"].partial_reason == "status_parse_error")
files["/proc/10/status"] = nil
local missing = collector:sample({ fs = fs, selected_process_ids = { ["10:5"] = true },
  now_ns = function() return 3000000000 end }, invalid)
assert(missing.data.by_id["10:5"].namespaces == nil
  and missing.data.by_id["10:5"].partial_reason == "status_unavailable")
files["/proc/10/status"] = original_status
files["/proc/10/stat"] = stat_line(10, 55, 1)
files["/proc/10/status"] = status_with("10 7", "10 7")
local reused = collector:sample({ fs = fs, now_ns = function() return 4000000000 end }, missing)
assert(reused.data.by_id["10:55"].namespaces.inner_pid == 7,
  "a recycled PID cannot inherit the old generation's inner ID")
files["/proc/10/status"] = status_with("10 9", "10 9")
local other_fs = fake_fs(files, dirs)
local scoped = collector:sample({ fs = other_fs, now_ns = function() return 5000000000 end }, reused)
assert(scoped.data.by_id["10:55"].quality ~= "fresh",
  "a different procfs provider cannot inherit the old CPU-rate baseline")
assert(scoped.data.by_id["10:55"].namespaces.inner_pid == 9,
  "identical PID and starttime in another procfs provider cannot reuse namespace IDs")
local vanished_dirs = { ["/proc"] = {} }
collector:sample({ fs = fake_fs({}, vanished_dirs), now_ns = function() return 6000000000 end }, scoped)
assert(next(collector.identity_cache) == nil, "vanished process identities leave no namespace cache")

-- A kernel without the field leaves the process unremarkable rather than
-- claiming it is namespaced.
local legacy = { ["/proc/40/stat"] = stat_line(40, 11, 1),
  ["/proc/40/status"] = "Name:\tx\nUid:\t0\t0\t0\t0\n" }
for path, value in pairs(detail_files(40)) do legacy[path] = value end
local legacy_dirs = { ["/proc"] = { "40" } }
local legacy_result = collector:sample({ fs = fake_fs(legacy, legacy_dirs),
  now_ns = function() return 0 end, selected_process_ids = nil })
assert(legacy_result.data.by_id["40:11"].namespaces == nil,
  "a status file without NSpid yields no namespace claim")

-- The overlay shows the chain for a namespaced process and stays quiet for
-- the rest, because a single value is the ordinary case.
local translator = assert(I18n.new({ locale = "en-US" }))
local function joined(lines) return table.concat(lines, "\n") end
local container_lines = TUI.process_detail_lines(container, translator)
assert(joined(container_lines):find("procfs → inside", 1, true),
  "the chain label identifies the procfs scope and kernel order")
local thread_lines = TUI.thread_detail_lines(
  { tid = 11, starttime_ticks = 5, name = "worker" },
  { tid = 11, starttime_ticks = 5, nspid = { 11, 2 } }, container, translator)
assert(joined(thread_lines):find("procfs → inside", 1, true)
  and joined(thread_lines):find("11 → 2", 1, true),
  "a selected thread preserves its own TID chain and procfs-to-inner label")

assert(joined(container_lines):find("PID namespaces", 1, true),
  "a namespaced process gets a section")
assert(joined(container_lines):find("10 → 1", 1, true),
  "the chain reads procfs to inner, got: " .. joined(container_lines))
local host_lines = TUI.process_detail_lines(host, translator)
assert(not joined(host_lines):find("PID namespaces", 1, true),
  "an ordinary process gets no namespace section")
local zh_lines = TUI.process_detail_lines(container, assert(I18n.new({ locale = "zh-CN" })))
assert(joined(zh_lines):find("PID 命名空间", 1, true), "the section is translated")

-- Searching by the inner id is what makes the feature useful: one query finds
-- every container init.
local function names_matching(query)
  local controller = Controller.new({})
  controller:update(result.data.list)
  controller:set_query(query)
  local names = {}
  for _, row in ipairs(controller:rows()) do names[#names + 1] = row.name end
  table.sort(names)
  return table.concat(names, ",")
end
assert(names_matching("ns:1") == "proc10", "ns:1 finds the container init")
assert(names_matching("ns:3") == "proc30", "ns:3 finds the doubly-nested process")
assert(names_matching("ns:20") == "proc20", "a host process matches its own id")
assert(names_matching("ns:10") == "", "the procfs id is not the inner id")
assert(names_matching("state:S ns:1") == "proc10", "it combines with other terms")
assert(names_matching("!ns:1") == "proc20,proc30", "and can be negated")

-- The snapshot carries the nesting: a consumer needs to tell a container's
-- init from a host process.  The chain is reduced to the ids a consumer acts
-- on rather than exporting the raw list.
local exported = Export.snapshot({ processes = { list = result.data.list } },
  { process_limit = 8 })
local encoded = json.encode(exported)
assert(encoded:find("namespaces", 1, true), "namespace nesting reaches the snapshot")
assert(encoded:find("inner_pid", 1, true), "with the innermost id")
assert(encoded:find("procfs_pid", 1, true) and not encoded:find("host_pid", 1, true),
  "the exported outer ID explicitly names the procfs scope")
assert(not encoded:find("nspid", 1, true),
  "the raw chain stays out of the exported shape")
local host_entry = encoded:find('"pid":20', 1, true)
assert(host_entry, "the host process is exported too")
assert(encoded:find('"namespaced":false', 1, true) or encoded:find('"namespaced": false', 1, true),
  "an ordinary process is marked as not namespaced")

print("ok: process PID namespaces (parser, collector, overlay, search, export)")
return true
