-- SMBIOS Type 8 firmware port declarations. These do not identify a present
-- operating-system interface or establish a device-tree parent relationship.
local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local Native = require("wtop.native")
local Platform = require("wtop.platform")
local Source = require("wtop.collectors.smbios_source")

local PortConnectors = {}
PortConnectors.__index = PortConnectors

function PortConnectors.new(options)
  options = options or {}
  if type(options) ~= "table" then error("PortConnectors options must be a table", 2) end
  return setmetatable({ id = "port_connectors", _method_style = true,
    fs = options.fs or FS.default, native = options.native or Native,
    platform = options.platform or Platform.id(),
    base_path = Common.absolute_path("base_path", options.base_path,
      "/sys/firmware/dmi/tables"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 60000),
  }, PortConnectors)
end

function PortConnectors:sample(context)
  local started = Common.now_ns(context)
  local input, parsed, reason, read_error = Source.load(self, context)
  if not input then return read_error end
  local source = input.source
  if not parsed then
    return Common.result("error", Common.now_ns(context), nil,
      { reason = reason, source = source })
  end
  if #parsed.ports == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { reason = "no_port_connectors", source = source })
  end
  Source.attach_metadata_issue(parsed, input, self.base_path)
  local result = { ports = parsed.ports, issues = parsed.issues,
    partial = parsed.partial, truncated = parsed.truncated,
    major = parsed.major, minor = parsed.minor, docrev = parsed.docrev,
    structure_count = parsed.structure_count, source = source }
  for _, issue in ipairs(result.issues) do
    issue.source = issue.source or (source .. string.format("@0x%x", issue.offset or 0))
  end
  for _, port in ipairs(result.ports) do port.source = source .. "#" .. port.id end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, result, { source = source,
    quality = result.partial and "partial" or "fresh",
    reason = result.partial and "port_connectors_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

function PortConnectors:probe(context)
  local result = self:sample(context)
  if result.status == "ok" then return Capability.available({ source = result.source }) end
  if result.status == "denied" then
    return Capability.denied(result.reason, { source = result.source })
  end
  return Capability.unavailable(result.reason, { source = result.source })
end

return PortConnectors
