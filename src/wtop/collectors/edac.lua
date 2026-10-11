local Capability = require("wtop.core.capability")
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")

local EDAC = {}
EDAC.__index = EDAC

local function entries(fs, path, pattern, limit)
  local names, err, cut = fs:list(path, 4096)
  if not names then return nil, err end
  local ids, seen = {}, {}
  for _, name in ipairs(names) do
    local id = type(name) == "string" and name:match(pattern)
    local number = id and tonumber(id)
    if number and number <= 65535
        and name == name:match("^%a+") .. tostring(number) and not seen[name] then
      ids[#ids + 1] = { name = name, number = number }
      seen[name] = true
    end
  end
  table.sort(ids, function(a, b)
    if a.number == b.number then return a.name < b.name end
    return a.number < b.number
  end)
  return ids, nil, cut == true or #ids > limit
end

local function read_value(fs, path, numeric, issues, field)
  local value, err = fs:read(path, 512)
  if value then
    value = Common.trim(value)
    if numeric then
      if value:match("^%d+$") then
        local number = tonumber(value)
        if number and number <= 9007199254740991 and math.type(number) == "integer" then
          return number
        end
      end
    elseif value ~= "" and not value:find("[%z\1-\31\127]") and utf8.len(value) then
      return value
    end
    err = { kind = "parse_error", message = "invalid_edac_value" }
  end
  issues[#issues + 1] = { field = field, source = path,
    status = FS.error_status(err), reason = err and err.message or "read_failed" }
end

function EDAC.new(options)
  options = options or {}
  if type(options) ~= "table" then error("EDAC options must be a table", 2) end
  return setmetatable({ id = "edac", _method_style = true,
    fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/devices/system/edac/mc"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    max_controllers = Common.positive_integer("max_controllers", options.max_controllers, 64, 256),
    max_modules = Common.positive_integer("max_modules", options.max_modules, 256, 1024),
  }, EDAC)
end

function EDAC:probe(context)
  local ids, err = entries(Common.fs(context, self.fs), self.base_path, "^mc(%d+)$", self.max_controllers)
  if ids and #ids > 0 then return Capability.available({ source = self.base_path }) end
  if err and FS.error_status(err) == "denied" then
    return Capability.denied(err.message, { source = self.base_path })
  end
  return Capability.unavailable("no_edac_controllers", { source = self.base_path })
end

function EDAC:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local controllers, err, truncated = entries(fs, self.base_path, "^mc(%d+)$", self.max_controllers)
  if not controllers then return Common.error_result(err, Common.now_ns(context), self.base_path) end
  if #controllers == 0 then
    return Common.result("unavailable", Common.now_ns(context), nil,
      { source = self.base_path, reason = "no_edac_controllers" })
  end
  local data = { controllers = {}, truncated = truncated, issues = {}, source = self.base_path }
  local total_modules = 0
  for index = 1, math.min(#controllers, self.max_controllers) do
    local entry = controllers[index]
    local path = self.base_path .. "/" .. entry.name
    local controller = { id = entry.name, index = entry.number, source = path,
      modules = {}, issues = {} }
    controller.name = read_value(fs, path .. "/mc_name", false, controller.issues, "name")
    controller.correctable_errors = read_value(fs, path .. "/ce_count", true,
      controller.issues, "correctable_errors")
    controller.uncorrectable_errors = read_value(fs, path .. "/ue_count", true,
      controller.issues, "uncorrectable_errors")
    local modules, list_error, cut = entries(fs, path, "^dimm(%d+)$", self.max_modules)
    if modules then
      local ranks, rank_error, rank_cut = entries(fs, path, "^rank(%d+)$", self.max_modules)
      if ranks then
        for _, rank in ipairs(ranks) do modules[#modules + 1] = rank end
        table.sort(modules, function(a, b) return a.name < b.name end)
        cut = cut or rank_cut or #modules > self.max_modules
      elseif FS.error_status(rank_error) ~= "unavailable" then
        cut = true
      end
    end
    if not modules then
      controller.issues[#controller.issues + 1] = { field = "modules", source = path,
        status = FS.error_status(list_error), reason = list_error and list_error.message }
    else
      data.truncated = data.truncated or cut
      for module_index = 1, #modules do
        if total_modules >= self.max_modules then data.truncated = true; break end
        local item = modules[module_index]
        local base = path .. "/" .. item.name
        local module = { id = entry.name .. "/" .. item.name,
          kind = item.name:match("^rank") and "rank" or "dimm", source = base, issues = {} }
        module.label = read_value(fs, base .. "/dimm_label", false, module.issues, "label")
        module.location = read_value(fs, base .. "/dimm_location", false, module.issues, "location")
        module.correctable_errors = read_value(fs, base .. "/dimm_ce_count", true,
          module.issues, "correctable_errors")
        module.uncorrectable_errors = read_value(fs, base .. "/dimm_ue_count", true,
          module.issues, "uncorrectable_errors")
        controller.modules[#controller.modules + 1] = module
        total_modules = total_modules + 1
      end
    end
    data.controllers[#data.controllers + 1] = controller
  end
  local partial = data.truncated or #data.issues > 0
  for _, controller in ipairs(data.controllers) do
    partial = partial or #controller.issues > 0
    for _, module in ipairs(controller.modules) do partial = partial or #module.issues > 0 end
  end
  local finished = Common.now_ns(context)
  return Common.result("ok", finished, data, { source = self.base_path,
    quality = partial and "partial" or "fresh",
    reason = partial and "edac_data_incomplete" or nil,
    duration_ns = Common.elapsed_ns(finished, started) or 0 })
end

return EDAC
