local Parsers = require("wtop.linux.parsers")
local WorkloadNavigation = require("wtop.model.workload_navigation")

local M = {}

local function valid_id(value)
  return type(value) == "number" and value == value and value % 1 == 0
    and value > 0 and value <= 2147483647
end

local function read(fs, path, limit)
  local ok, content = pcall(fs.read, fs, path, limit)
  return ok and content or nil
end

-- Resolve a bounded set of TIDs to process leaders only when the task still
-- belongs to this cgroup. A second stat read keeps a reused TID from joining
-- identity and membership taken from different tasks.
function M.resolve(fs, cgroup_id, tids, maximum)
  if type(fs) ~= "table" or type(fs.read) ~= "function"
      or type(cgroup_id) ~= "string" or cgroup_id:sub(1, 1) ~= "/"
      or #cgroup_id > 4096 or cgroup_id:find("\0", 1, true)
      or type(tids) ~= "table" then
    return nil, "invalid_thread_membership_source"
  end
  maximum = maximum or 64
  if type(maximum) ~= "number" or maximum % 1 ~= 0
      or maximum < 1 or maximum > 256 then
    return nil, "invalid_thread_scan_limit"
  end
  local result = { pids = {}, tids_total = #tids,
    tids_checked = math.min(#tids, maximum), matched_tids = 0,
    truncated = #tids > maximum }
  local seen = {}
  for index = 1, result.tids_checked do
    local tid = tids[index]
    if valid_id(tid) then
      local base = "/proc/" .. tid
      local first_content = read(fs, base .. "/stat", 65536)
      local first = first_content and Parsers.process_stat(first_content)
      if first and first.pid == tid then
        local status_content = read(fs, base .. "/status", 256 * 1024)
        local status = status_content and Parsers.process_status(status_content)
        if status and valid_id(status.tgid) then
          local cgroup_content = read(fs, base .. "/cgroup", 65536)
          local cgroups = cgroup_content and Parsers.cgroup(cgroup_content)
          if WorkloadNavigation.target_id({ cgroups = cgroups }, "cgroup2")
              == cgroup_id then
            local last_content = read(fs, base .. "/stat", 65536)
            local last = last_content and Parsers.process_stat(last_content)
            if last and last.pid == tid
                and last.starttime_ticks == first.starttime_ticks then
              result.matched_tids = result.matched_tids + 1
              if not seen[status.tgid] then
                seen[status.tgid] = true
                result.pids[#result.pids + 1] = status.tgid
              end
            end
          end
        end
      end
    end
  end
  table.sort(result.pids)
  return result
end

return M
