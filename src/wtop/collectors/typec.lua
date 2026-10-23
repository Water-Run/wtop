-- Read only the kernel Type-C/PD classes. No role swaps, discovery commands,
-- identity VDO reads, USB device scans or power-supply ownership guesses.
local Common = require("wtop.collectors.common")
local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Sysfs = require("wtop.linux.sysfs")
local PD = require("wtop.format.usb_pd")
local TypeC = {}; TypeC.__index = TypeC

local function issue(row, field, path, err, reason)
  if #row.issues < 32 then row.issues[#row.issues + 1] = { field = field,
    source = path, status = FS.error_status(err), reason = reason or err and err.message } end
end

local function text(fs, path, row, key, required, allow_empty)
  local raw, err = fs:read(path, 256)
  if raw == nil then
    if required or not err or (err.kind ~= "missing" and err.kind ~= "unavailable") then issue(row, key, path, err) end
    return nil
  end
  local value = Common.trim(raw)
  if type(value) ~= "string" or #value > 255 or value:find("[%z\1-\31\127]") or not utf8.len(value)
      or (value == "" and not allow_empty) then
    issue(row, key, path, { kind = "parse_error" }, "invalid_typec_attribute"); return nil
  end
  return value
end

local function revision(fs, path, row, key, required)
  local value = text(fs, path, row, key, required)
  if value == nil then return nil end
  if #value <= 16 and value:match("^%d+%.%d+$") then return value end
  issue(row, key, path, { kind = "parse_error" }, "invalid_typec_attribute")
end

local function choices(fs, path, row, key, allowed)
  local raw = text(fs, path, row, key)
  if not raw then return nil, {} end
  local selected, values, seen = nil, {}, {}
  for token in raw:gmatch("%S+") do
    local marked = token:match("^%[([%w_]+)%]$")
    local value = marked or token
    if #values >= 16 or #value > 32 or not value:match("^[%w_]+$") or seen[value]
        or (allowed and not allowed[value]) or (marked and selected) then
      issue(row, key, path, { kind = "parse_error" }, "invalid_typec_attribute"); return nil, {}
    end
    seen[value] = true; values[#values + 1] = value
    if marked then selected = marked end
  end
  if #values == 1 and not selected then selected = values[1] end
  if not selected then issue(row, key, path, { kind = "parse_error" }, "invalid_typec_attribute") end
  return selected, values
end

local function listing(fs, base, prefix, maximum)
  local entries, err, truncated = fs:list(base, 512)
  if not entries then return nil, nil, err end
  local list, all = {}, {}
  for _, name in ipairs(entries) do
    all[name] = true
    local digits = type(name) == "string" and name:match("^" .. prefix .. "(%d+)$")
    local index = digits and tonumber(digits)
    if index and index <= 65535 and name == prefix .. index then list[#list + 1] = { id = name, index = index } end
  end
  table.sort(list, function(a, b) return a.index < b.index end)
  return list, all, nil, truncated == true or #list > maximum
end

local function link(fs, path)
  return type(fs.readlink) == "function" and fs:readlink(path) or nil
end

local function device_path(fs, path)
  local resolved = Sysfs.device_path(fs, path)
  return resolved and Sysfs.device_path(fs, resolved .. "/device") or Sysfs.device_path(fs, path .. "/device")
end

local function profile(fs, path, name, direction)
  local position, kind = name:match("^([1-9]%d*):([%w_]+)$")
  position = tonumber(position)
  if not position or position > 255 or #kind > 48 or name ~= position .. ":" .. kind then return nil end
  local row = { id = name, position = position, kind = kind, direction = direction,
    declarations_only = true, source = path .. "/" .. name, issues = {} }
  local fields = PD.fields(kind, direction, position)
  if #fields == 0 then issue(row, "kind", row.source, { kind = "unavailable" }, "unsupported_pd_profile") end
  for _, key in ipairs(fields) do
    local source = row.source .. "/" .. key
    local raw = text(fs, source, row, key, PD.required(key))
    if raw then
      local value, field = PD.parse(key, raw)
      if value == nil then issue(row, key, source, { kind = "parse_error" }, "invalid_pd_attribute")
      else row[field] = value end
    end
  end
  if row.minimum_voltage_volts and row.maximum_voltage_volts
      and row.minimum_voltage_volts > row.maximum_voltage_volts then
    issue(row, "voltage_range", row.source, { kind = "parse_error" }, "invalid_pd_attribute")
  end
  row.quality = #row.issues > 0 and "partial" or "fresh"
  return row
end

local function read_pd(self, fs, entry, context, budget)
  local path = self.pd_path .. "/" .. entry.id
  local before = link(fs, path)
  local row = { id = entry.id, index = entry.index, source = path, issues = {},
    profiles = {}, capability_status = {}, read_started_ns = Common.now_ns(context),
    identity_quality = before and "path" or "estimated", _class_target = Sysfs.device_path(fs, path) }
  row.revision = revision(fs, path .. "/revision", row, "revision", true)
  row.version = revision(fs, path .. "/version", row, "version")
  local revision_before = row.revision
  for _, direction in ipairs({ "source", "sink" }) do
    local base = path .. "/" .. direction .. "-capabilities"
    local names, err, cut = fs:list(base, 64)
    row.capability_status[direction] = names and "available" or FS.error_status(err)
    if not names then
      if err and err.kind ~= "missing" and err.kind ~= "unavailable" then issue(row, direction, base, err) end
    else
      table.sort(names, function(a, b)
        local left, right = tonumber(a:match("^(%d+):")), tonumber(b:match("^(%d+):"))
        if left and right and left ~= right then return left < right end
        return a < b
      end)
      row.truncated = row.truncated or cut == true
      local count = 0
      for _, name in ipairs(names) do
        if name:match("^[1-9]%d*:[%w_]+$") then
          if count >= 32 or budget.count >= self.max_profiles then row.truncated = true; break end
          local object = profile(fs, base, name, direction)
          if object then
            count = count + 1; budget.count = budget.count + 1
            row.profiles[#row.profiles + 1] = object
          end
        end
      end
    end
  end
  table.sort(row.profiles, function(a, b)
    if a.direction ~= b.direction then return a.direction == "source" end
    return a.position < b.position
  end)
  row.device_path = device_path(fs, path)
  row.observed_at_ns = Common.now_ns(context)
  row.quality = (#row.issues > 0 or row.truncated) and "partial" or "fresh"
  for _, object in ipairs(row.profiles) do if object.quality ~= "fresh" then row.quality = "partial" end end
  if link(fs, path) ~= before or revision(fs, path .. "/revision", row, "revision") ~= revision_before then
    row.quality = "gap"; for _, object in ipairs(row.profiles) do object.quality = "gap" end
  end
  if row.quality == "fresh" and #row.issues > 0 then row.quality = "partial" end
  return row
end

local function peripheral(fs, path, id, cable)
  local row = { id = id, source = path, issues = {} }
  row.type = text(fs, path .. "/type", row, "type")
  row.usb_power_delivery_revision = revision(fs, path .. "/usb_power_delivery_revision", row, "usb_power_delivery_revision")
  if cable then row.plug_type = text(fs, path .. "/plug_type", row, "plug_type")
  else
    row.accessory_mode = text(fs, path .. "/accessory_mode", row, "accessory_mode")
    local pd = text(fs, path .. "/supports_usb_power_delivery", row, "supports_usb_power_delivery")
    if pd == "yes" then row.supports_usb_power_delivery = true elseif pd == "no" then row.supports_usb_power_delivery = false
    elseif pd then issue(row, "supports_usb_power_delivery", path, { kind = "parse_error" }, "invalid_typec_attribute") end
    row.usb_mode, row.usb_modes = choices(fs, path .. "/usb_mode", row, "usb_mode")
  end
  row.quality = #row.issues > 0 and "partial" or "fresh"
  return row
end

local function read_port(self, fs, entry, all, complete, context)
  local path = self.base_path .. "/" .. entry.id
  local before = link(fs, path)
  local row = { id = entry.id, index = entry.index, source = path, issues = {},
    read_started_ns = Common.now_ns(context), identity_quality = before and "path" or "estimated" }
  row.data_role, row.data_roles = choices(fs, path .. "/data_role", row, "data_role", { host = true, device = true })
  row.power_role, row.power_roles = choices(fs, path .. "/power_role", row, "power_role", { source = true, sink = true })
  row.port_type = text(fs, path .. "/port_type", row, "port_type")
  row.preferred_role = text(fs, path .. "/preferred_role", row, "preferred_role", false, true)
  row.power_operation_mode = text(fs, path .. "/power_operation_mode", row, "power_operation_mode")
  row.orientation = text(fs, path .. "/orientation", row, "orientation")
  local vconn = text(fs, path .. "/vconn_source", row, "vconn_source")
  if vconn == "yes" then row.vconn_source = true elseif vconn == "no" then row.vconn_source = false
  elseif vconn then issue(row, "vconn_source", path, { kind = "parse_error" }, "invalid_typec_attribute") end
  row.usb_typec_revision = revision(fs, path .. "/usb_typec_revision", row, "usb_typec_revision")
  row.usb_power_delivery_revision = revision(fs, path .. "/usb_power_delivery_revision", row, "usb_power_delivery_revision")
  row.usb_default_mode, row.usb_capabilities = choices(fs, path .. "/usb_capability", row, "usb_capability")
  for _, kind in ipairs({ "partner", "cable" }) do
    local id = entry.id .. "-" .. kind
    if all[id] then row[kind] = peripheral(fs, self.base_path .. "/" .. id, id, kind == "cable")
    elseif complete then row[kind .. "_observed"] = false end
    if row[kind] then row[kind .. "_observed"] = true end
  end
  local class = Sysfs.device_path(fs, path)
  row._pd_target = class and Sysfs.device_path(fs, class .. "/usb_power_delivery")
    or Sysfs.device_path(fs, path .. "/usb_power_delivery")
  row.device_path = device_path(fs, path)
  local data_role = choices(fs, path .. "/data_role", row, "data_role", { host = true, device = true })
  local power_role = choices(fs, path .. "/power_role", row, "power_role", { source = true, sink = true })
  local power_mode = text(fs, path .. "/power_operation_mode", row, "power_operation_mode")
  local pd_after = class and Sysfs.device_path(fs, class .. "/usb_power_delivery")
    or Sysfs.device_path(fs, path .. "/usb_power_delivery")
  row.observed_at_ns = Common.now_ns(context)
  row.quality = #row.issues > 0 and "partial" or "fresh"
  for _, key in ipairs({ "partner", "cable" }) do
    if row[key] and row[key].quality ~= "fresh" then row.quality = "partial" end
  end
  if link(fs, path) ~= before or row.data_role ~= data_role or row.power_role ~= power_role
      or row.power_operation_mode ~= power_mode or row._pd_target ~= pd_after then row.quality = "gap" end
  return row
end

function TypeC.new(options)
  options = options or {}; if type(options) ~= "table" then error("Type-C options must be a table", 2) end
  return setmetatable({ id = "typec", _method_style = true, fs = options.fs or FS.default,
    base_path = Common.absolute_path("base_path", options.base_path, "/sys/class/typec"),
    pd_path = Common.absolute_path("pd_path", options.pd_path, "/sys/class/usb_power_delivery"),
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    max_ports = Common.positive_integer("max_ports", options.max_ports, 32, 64),
    max_pd_devices = Common.positive_integer("max_pd_devices", options.max_pd_devices, 32, 64),
    max_profiles = Common.positive_integer("max_profiles", options.max_profiles, 256, 256) }, TypeC)
end

function TypeC:sample(context)
  local start = Common.now_ns(context); local fs = Common.fs(context, self.fs)
  local ports, all, port_error, cut = listing(fs, self.base_path, "port", self.max_ports)
  local devices, _, pd_error, pd_cut = listing(fs, self.pd_path, "pd", self.max_pd_devices)
  if not ports and not devices then
    for _, err in ipairs({port_error or false, pd_error or false}) do
      if err and err.kind ~= "missing" and err.kind ~= "unavailable" then
        return Common.error_result(err, Common.now_ns(context), self.base_path)
      end
    end
  end
  if #(ports or {}) + #(devices or {}) == 0 then
    for _, err in ipairs({port_error or false, pd_error or false}) do
      if err and err.kind ~= "missing" and err.kind ~= "unavailable" then
        return Common.error_result(err, Common.now_ns(context), self.base_path)
      end
    end
    return Common.result("unavailable", Common.now_ns(context), nil, { source = self.base_path, reason = "no_typec_devices" })
  end
  local data = { ports = {}, pd_devices = {}, issues = {}, source = self.base_path, truncated = cut or pd_cut or false }
  for _, failure in ipairs({ {port_error, self.base_path}, {pd_error, self.pd_path} }) do
    if failure[1] and failure[1].kind ~= "missing" and failure[1].kind ~= "unavailable" then
      issue(data, "directory", failure[2], failure[1])
    end
  end
  local budget, targets = { count = 0 }, {}
  for index = 1, math.min(#(devices or {}), self.max_pd_devices) do
    local row = read_pd(self, fs, devices[index], context, budget)
    data.pd_devices[#data.pd_devices + 1] = row
    if row._class_target then
      if targets[row._class_target] == nil then targets[row._class_target] = row else targets[row._class_target] = false end
    end
    data.truncated = data.truncated or row.truncated == true
  end
  for index = 1, math.min(#(ports or {}), self.max_ports) do
    local row = read_port(self, fs, ports[index], all, not cut, context)
    local pd = row._pd_target and targets[row._pd_target]
    if pd and not pd_cut and row.quality ~= "gap" and pd.quality ~= "gap"
        and Sysfs.device_path(fs, self.pd_path .. "/" .. pd.id) == row._pd_target then row.pd_id = pd.id end
    row._pd_target = nil; data.ports[#data.ports + 1] = row
  end
  local _, after, after_error, after_cut = listing(fs, self.base_path, "port", self.max_ports)
  for _, row in ipairs(data.ports) do
    if not after or after_error or after_cut or (all[row.id .. "-partner"] == true) ~= (after[row.id .. "-partner"] == true)
        or (all[row.id .. "-cable"] == true) ~= (after[row.id .. "-cable"] == true) then
      row.quality, row.pd_id = "gap", nil
    end
  end
  data.partial = #data.issues > 0
  for _, list in ipairs({data.ports, data.pd_devices}) do
    for _, row in ipairs(list) do
      row._class_target = nil
      if row.quality ~= "fresh" then data.partial = true end
    end
  end
  local now = Common.now_ns(context)
  return Common.result("ok", now, data, { source = self.base_path,
    quality = (data.partial or data.truncated) and "partial" or "fresh",
    reason = (data.partial or data.truncated) and "typec_data_incomplete" or nil,
    duration_ns = Common.elapsed_ns(now, start) or 0 })
end

function TypeC:probe(context)
  local rows, _, err = listing(Common.fs(context, self.fs), self.base_path, "port", self.max_ports)
  if rows and #rows > 0 then return Capability.available({ source = self.base_path }) end
  local pd = listing(Common.fs(context, self.fs), self.pd_path, "pd", self.max_pd_devices)
  if pd and #pd > 0 then return Capability.available({ source = self.pd_path }) end
  if err and FS.error_status(err) == "denied" then return Capability.denied(err.message, {source=self.base_path}) end
  return Capability.unavailable("no_typec_devices", {source=self.base_path})
end

return TypeC
