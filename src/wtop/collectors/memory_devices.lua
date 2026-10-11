local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")
local Platform = require("wtop.platform")
local Source = require("wtop.collectors.smbios_source")

local MemoryDevices = {}
MemoryDevices.__index = MemoryDevices

function MemoryDevices.new(options)
  options = options or {}
  if type(options) ~= "table" then error("MemoryDevices options must be a table", 2) end
  return setmetatable({ id = "memory_devices", _method_style = true,
    fs = options.fs or FS.default, native = options.native or Native,
    platform = options.platform or Platform.id(),
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/firmware/dmi/tables"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000),
  }, MemoryDevices)
end

function MemoryDevices:sample(context)
  local started = Common.now_ns(context)
  local input, parsed, reason, read_error = Source.load(self, context)
  if not input then return read_error end
  local source = input.source
  if not parsed then
    return Common.result("error", Common.now_ns(context), nil, { reason = reason, source = source })
  end
  if #parsed.devices == 0 and #parsed.arrays == 0 and #parsed.channels == 0
      and #parsed.array_ranges == 0 and #parsed.device_ranges == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { reason = "no_memory_devices", source = source })
  end
  Source.attach_metadata_issue(parsed, input, self.base_path)
  parsed.source = source
  for _, item in ipairs(parsed.issues) do
    item.source = item.source or (source .. string.format("@0x%x", item.offset or 0))
  end
  for _, list in ipairs({ parsed.arrays, parsed.devices, parsed.channels,
      parsed.array_ranges, parsed.device_ranges }) do
    for _, record in ipairs(list) do record.source = source .. "#" .. record.id end
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, parsed, { source = source,
    quality = parsed.partial and "partial" or "fresh",
    reason = parsed.partial and "memory_devices_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

function MemoryDevices:probe(context)
  local result = self:sample(context)
  if result.status == "ok" then return Capability.available({ source = result.source }) end
  if result.status == "denied" then return Capability.denied(result.reason, { source = result.source }) end
  return Capability.unavailable(result.reason, { source = result.source })
end

return MemoryDevices
