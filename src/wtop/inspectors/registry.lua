local Registry = {}
Registry.__index = Registry

local VALID_CAPABILITY = {
  available = true, unavailable = true, denied = true, degraded = true, error = true,
}

local function invoke(inspector, name, ...)
  local fn = inspector[name]
  if type(fn) ~= "function" then
    return nil, "inspector_method_unavailable"
  end
  if inspector._method_style then
    return fn(inspector, ...)
  end
  return fn(...)
end

function Registry.new()
  return setmetatable({ inspectors = {}, order = {} }, Registry)
end

function Registry:register(inspector)
  if type(inspector) ~= "table" or type(inspector.id) ~= "string" or inspector.id == "" then
    return nil, "inspector_id_required"
  end
  if self.inspectors[inspector.id] then
    return nil, "inspector_already_registered"
  end
  for _, method in ipairs({ "probe", "enumerate", "inspect" }) do
    if type(inspector[method]) ~= "function" then
      return nil, "inspector_" .. method .. "_required"
    end
  end
  self.inspectors[inspector.id] = inspector
  self.order[#self.order + 1] = inspector.id
  table.sort(self.order)
  return inspector
end

function Registry:unregister(id)
  if not self.inspectors[id] then
    return false
  end
  self.inspectors[id] = nil
  for index, value in ipairs(self.order) do
    if value == id then
      table.remove(self.order, index)
      break
    end
  end
  return true
end

function Registry:get(id)
  return self.inspectors[id]
end

function Registry:list(domain)
  if domain ~= nil and type(domain) ~= "string" then return nil, "invalid_domain" end
  local result = {}
  for _, id in ipairs(self.order) do
    local inspector = self.inspectors[id]
    if not domain or inspector.domain == domain then
      result[#result + 1] = inspector
    end
  end
  return result
end

function Registry:probe_all(context)
  local result = {}
  for _, id in ipairs(self.order) do
    local inspector = self.inspectors[id]
    local ok, capability = pcall(invoke, inspector, "probe", context)
    if ok and type(capability) == "table" and VALID_CAPABILITY[capability.state]
        and type(capability.available) == "boolean" then
      result[id] = capability
    else
      result[id] = {
        state = "error",
        available = false,
        reason = ok and "invalid_probe_result" or tostring(capability),
      }
    end
  end
  return result
end

function Registry:enumerate(id, context)
  local inspector = self.inspectors[id]
  if not inspector then
    return nil, "inspector_not_found"
  end
  local ok, result, err = pcall(invoke, inspector, "enumerate", context)
  if not ok then
    return nil, tostring(result)
  end
  if result ~= nil and type(result) ~= "table" then
    return nil, "invalid_enumerate_result"
  end
  return result, err
end

function Registry:inspect(id, context, entity, depth)
  local inspector = self.inspectors[id]
  if not inspector then
    return nil, "inspector_not_found"
  end
  local ok, result, err = pcall(invoke, inspector, "inspect", context, entity, depth)
  if not ok then
    return nil, tostring(result)
  end
  if result ~= nil and type(result) ~= "table" then
    return nil, "invalid_inspect_result"
  end
  return result, err
end

function Registry:invalidate(id, entity)
  local inspector = self.inspectors[id]
  if not inspector then
    return nil, "inspector_not_found"
  end
  if type(inspector.invalidate) ~= "function" then
    return false
  end
  local ok, result, err = pcall(invoke, inspector, "invalidate", entity)
  if not ok then return nil, tostring(result) end
  if result == nil and err ~= nil then return nil, err end
  return true
end

return Registry
