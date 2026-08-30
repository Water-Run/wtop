local Capability = require("wtop.core.capability")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local CPU = {}
CPU.__index = CPU

local function derive_cpu(current, previous)
  local output = {
    name = current.name,
    counters = current,
    utilization = nil,
  }
  if not previous then
    output.quality = "gap"
    return output
  end
  local total_delta = Common.delta(current.total, previous.total)
  local idle_delta = Common.delta(current.idle_all, previous.idle_all)
  if not total_delta or not idle_delta or total_delta <= 0 or idle_delta > total_delta then
    output.quality = "gap"
    return output
  end
  local deltas = {}
  for _, key in ipairs({ "user", "nice", "system", "iowait", "irq", "softirq", "steal" }) do
    deltas[key] = Common.delta(current[key], previous[key])
    if deltas[key] == nil then
      output.quality = "gap"
      return output
    end
  end
  local function percent(value)
    return math.max(0, math.min(100, (value + 0.0) * 100 / total_delta))
  end
  output.utilization = math.max(0,
    math.min(100, ((total_delta - idle_delta) + 0.0) * 100 / total_delta))
  output.user = percent(deltas.user)
  output.nice = percent(deltas.nice)
  output.system = percent(deltas.system)
  output.iowait = percent(deltas.iowait)
  local interrupt = Common.safe_add(deltas.irq, deltas.softirq)
  if not interrupt then output.quality = "gap" return output end
  output.irq = percent(interrupt)
  output.steal = percent(deltas.steal)
  output.quality = "fresh"
  return output
end

function CPU.new(options)
  options = options or {}
  if type(options) ~= "table" then error("CPU options must be a table", 2) end
  return setmetatable({
    id = "cpu",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 500),
    fs = options.fs or FS.default,
    stat_path = Common.absolute_path("stat_path", options.stat_path, "/proc/stat"),
    loadavg_path = Common.absolute_path("loadavg_path", options.loadavg_path, "/proc/loadavg"),
    _method_style = true,
  }, CPU)
end

function CPU:probe(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.stat_path, 1024 * 1024)
  if content then
    return Capability.available({ source = self.stat_path })
  end
  local status = FS.error_status(err)
  if status == "denied" then
    return Capability.denied(err.message, { source = self.stat_path })
  end
  return Capability.unavailable(err and err.message or "proc_stat_unavailable", { source = self.stat_path })
end

function CPU:sample(context, previous)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.stat_path, 1024 * 1024)
  if not content then
    return Common.error_result(err, Common.now_ns(context), self.stat_path)
  end
  local parsed, parse_error = Parsers.proc_stat(content)
  if not parsed then
    return Common.result("error", Common.now_ns(context), nil, {
      quality = "error",
      reason = parse_error,
      source = self.stat_path,
    })
  end

  local previous_data = Common.previous_data(previous)
  local previous_raw = previous_data and previous_data.raw
  local total = derive_cpu(parsed.total, previous_raw and previous_raw.total)
  local cores = {}
  local any_gap = total.quality == "gap"
  for _, current in ipairs(parsed.cores or {}) do
    local old = previous_raw and previous_raw.cpus[current.name]
    local derived = derive_cpu(current, old)
    cores[#cores + 1] = derived
    any_gap = any_gap or derived.quality == "gap"
  end

  local load, load_partial
  local load_content, load_error = fs:read(self.loadavg_path, 4096)
  if load_content then
    local load_parse_error
    load, load_parse_error = Parsers.loadavg(load_content)
    load_partial = load == nil
  elseif load_error then
    load_partial = true
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, {
    total = total,
    cores = cores,
    load = load,
    context_switches = parsed.metadata.ctxt,
    interrupts = parsed.metadata.intr,
    processes_created = parsed.metadata.processes,
    processes_running = parsed.metadata.procs_running,
    processes_blocked = parsed.metadata.procs_blocked,
    boot_time_seconds = parsed.metadata.btime,
    raw = parsed,
  }, {
    quality = load_partial and "partial" or (any_gap and "gap" or "fresh"),
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = { self.stat_path, self.loadavg_path },
  })
end

return CPU
