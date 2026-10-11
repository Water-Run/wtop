-- Read membership only when the operator asks to navigate from a process.
local Actions = require("wtop.actions")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Parsers = require("wtop.linux.parsers")
local Navigation = require("wtop.model.workload_navigation")

local M = {}

function M.target_id(process, fs)
  fs = fs or FS.default
  if not Actions.verify_process(process, fs) then return nil end
  local ok, raw = pcall(fs.read, fs, "/proc/" .. process.pid .. "/cgroup", 65536)
  if not ok or type(raw) ~= "string" or #raw > 65536 then return nil end
  local cgroups = Parsers.cgroup(raw)
  local id = Navigation.target_id({ cgroups = cgroups }, "cgroup2")
  -- The row may outlive its process. Discard membership read across PID
  -- reuse, and prefer this current read to membership in an older snapshot.
  if id and Actions.verify_process(process, fs) then return id end
  return nil
end

-- A unit can name a main PID that the bounded process snapshot has not yet
-- sampled. Capture its generation before requesting that one process sample.
function M.observe(pid, fs)
  fs = fs or FS.default
  if type(pid) ~= "number" or math.type(pid) ~= "integer" or pid < 1 or pid > 2147483647 then return nil end
  local ok, raw = pcall(fs.read, fs, "/proc/" .. pid .. "/stat", 65536)
  if not ok or type(raw) ~= "string" or #raw > 65536 then return nil end
  local process = Parsers.process_stat(raw)
  if not process or process.pid ~= pid then return nil end
  local target = M.target_id(process, fs)
  if not target then return nil end
  return { id = process.id, pid = pid, starttime_ticks = process.starttime_ticks,
    name = Common.safe_text(process.comm, 256), state = process.state,
    parent_pid = process.ppid }, target
end

return M
