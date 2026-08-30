local Capability = require("wtop.core.capability")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local Memory = {}
Memory.__index = Memory

function Memory.new(options)
  options = options or {}
  if type(options) ~= "table" then error("Memory options must be a table", 2) end
  return setmetatable({
    id = "memory",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 1000),
    fs = options.fs or FS.default,
    meminfo_path = Common.absolute_path("meminfo_path", options.meminfo_path, "/proc/meminfo"),
    vmstat_path = Common.absolute_path("vmstat_path", options.vmstat_path, "/proc/vmstat"),
    _method_style = true,
  }, Memory)
end

function Memory:probe(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.meminfo_path, 1024 * 1024)
  if content then
    return Capability.available({ source = self.meminfo_path })
  end
  local status = FS.error_status(err)
  if status == "denied" then
    return Capability.denied(err.message, { source = self.meminfo_path })
  end
  return Capability.unavailable(err and err.message or "meminfo_unavailable", { source = self.meminfo_path })
end

function Memory:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.meminfo_path, 1024 * 1024)
  if not content then
    return Common.error_result(err, Common.now_ns(context), self.meminfo_path)
  end
  local info, parse_error = Parsers.meminfo(content)
  if not info then
    return Common.result("error", Common.now_ns(context), nil, {
      quality = "error",
      reason = parse_error,
      source = self.meminfo_path,
    })
  end

  local available = info.MemAvailable
  local estimated_available = false
  if available == nil then
    available = Common.safe_add(info.MemFree or 0, info.Buffers or 0, info.Cached or 0)
    if not available or available < 0 or available > math.maxinteger then
      return Common.result("error", Common.now_ns(context), nil, {
        quality = "error", reason = "estimated_available_out_of_range", source = self.meminfo_path,
      })
    end
    estimated_available = true
  end
  if available < 0 or available > info.MemTotal then
    return Common.result("error", Common.now_ns(context), nil, {
      quality = "error", reason = "MemAvailable_out_of_range", source = self.meminfo_path,
    })
  end
  local cache_total = Common.safe_add(info.Cached or 0, info.SReclaimable or 0)
  local cache = cache_total and cache_total - (info.Shmem or 0) or nil
  if not cache or cache ~= cache or cache == math.huge or cache == -math.huge then
    return Common.result("error", Common.now_ns(context), nil, {
      quality = "error", reason = "cache_value_out_of_range", source = self.meminfo_path,
    })
  end
  cache = math.max(0, cache)

  local swap_total, swap_free = info.SwapTotal or 0, info.SwapFree or 0
  if swap_free > swap_total then
    return Common.result("error", Common.now_ns(context), nil, {
      quality = "error", reason = "SwapFree_out_of_range", source = self.meminfo_path,
    })
  end

  local vmstat_content, vmstat_read_error = fs:read(self.vmstat_path, 2 * 1024 * 1024)
  local vmstat, vmstat_parse_error
  if vmstat_content then vmstat, vmstat_parse_error = Parsers.vmstat(vmstat_content) end
  local vmstat_partial = vmstat == nil
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, {
    total_bytes = info.MemTotal,
    available_bytes = available,
    used_bytes = math.max(0, info.MemTotal - available),
    free_bytes = info.MemFree or 0,
    buffers_bytes = info.Buffers or 0,
    cache_bytes = cache,
    anonymous_bytes = info.AnonPages or info.Active_anon,
    slab_bytes = info.Slab or 0,
    reclaimable_slab_bytes = info.SReclaimable or 0,
    unreclaimable_slab_bytes = info.SUnreclaim or 0,
    dirty_bytes = info.Dirty or 0,
    writeback_bytes = info.Writeback or 0,
    swap_total_bytes = swap_total,
    swap_free_bytes = swap_free,
    swap_used_bytes = swap_total - swap_free,
    zswap_bytes = info.Zswap or info.zswap,
    zswapped_bytes = info.Zswapped or info.zswapped,
    available_estimated = estimated_available,
    vmstat = vmstat,
    vmstat_error = vmstat_parse_error or (vmstat_read_error and vmstat_read_error.message),
    raw = info,
  }, {
    quality = vmstat_partial and "partial" or (estimated_available and "estimated" or "fresh"),
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = { self.meminfo_path, self.vmstat_path },
  })
end

return Memory
