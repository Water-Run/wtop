-- Narrow terminal backend boundary. The concrete adapter is injected by the
-- application, so this module itself has no dependency on wtop.terminal or C.
local Backend = {}

local required = {"start", "size", "poll", "present", "capabilities", "stop"}

local function normalise_capabilities(capabilities)
  capabilities = capabilities or {}
  if type(capabilities) ~= "table" then capabilities = {} end
  local result = {}
  for key, value in pairs(capabilities) do
    result[key] = value
  end
  if result.truecolor then
    result.color_depth = "truecolor"
    result.colors = result.colors or 16777216
  elseif result.color_depth == nil then
    if (result.colors or 0) >= 256 then
      result.color_depth = 256
    elseif result.colors == 0 or result.no_color then
      result.color_depth = "mono"
    else
      result.color_depth = 16
    end
  end
  result.unicode = result.unicode ~= false
  result.mouse = result.mouse == true
  result.bracketed_paste = result.bracketed_paste ~= false
  return result
end

function Backend.validate(native)
  if type(native) ~= "table" then
    return nil, "backend must be a table"
  end
  for _, method in ipairs(required) do
    if type(native[method]) ~= "function" then
      return nil, "backend is missing " .. method .. "()"
    end
  end
  return true
end

function Backend.new(native)
  local valid, reason = Backend.validate(native)
  if not valid then
    error(reason, 2)
  end
  local state = {active = false}
  -- The public shape deliberately follows docs/ARCHITECTURE.md: every method is
  -- a closure called with dot syntax.  This also prevents accidental leakage of
  -- an OO calling convention into injected native adapters.
  return {
    start = function(options)
      if state.active then return true end
      if options ~= nil and type(options) ~= "table" then
        return nil, "backend start options must be a table"
      end
      local called, result, reason = pcall(native.start, options or {})
      if not called then return nil, "terminal backend start failed: " .. tostring(result) end
      if result == false or (result == nil and reason ~= nil) then
        return nil, reason or "terminal backend failed to start"
      end
      state.active = true
      return true
    end,
    size = function()
      local called, first, second = pcall(native.size)
      if not called then return nil, "terminal backend size failed: " .. tostring(first) end
      local columns, rows
      if type(first) == "table" then
        columns = first.columns or first.cols or first.width
        rows = first.rows or first.height
      else
        columns, rows = first, second
      end
      columns, rows = tonumber(columns), tonumber(rows)
      if not columns or not rows or columns ~= columns or rows ~= rows
          or columns == math.huge or rows == math.huge
          or columns < 1 or rows < 1 or columns > 10000 or rows > 10000
          or columns % 1 ~= 0 or rows % 1 ~= 0 then
        return nil, "backend returned an invalid terminal size"
      end
      return columns, rows
    end,
    poll = function(timeout_ms)
      timeout_ms = timeout_ms or 0
      if type(timeout_ms) ~= "number" or timeout_ms ~= timeout_ms or timeout_ms == math.huge
          or timeout_ms == -math.huge or timeout_ms % 1 ~= 0
          or timeout_ms < -1 or timeout_ms > 60000 then
        return nil, "backend poll timeout must be an integer in -1..60000"
      end
      local called, result, reason = pcall(native.poll, timeout_ms)
      if not called then return nil, "terminal backend poll failed: " .. tostring(result) end
      return result, reason
    end,
    present = function(runs, metadata)
      if not state.active then
        return nil, "terminal backend is not active"
      end
      if type(runs) ~= "table" then return nil, "terminal runs must be a table" end
      local called, result, reason = pcall(native.present, runs, metadata)
      if not called then return nil, "terminal backend present failed: " .. tostring(result) end
      return result, reason
    end,
    capabilities = function()
      local called, result = pcall(native.capabilities)
      return normalise_capabilities(called and result or {})
    end,
    stop = function()
      if not state.active then return true end
      -- Mark inactive first so a failing stop cannot cause a second teardown to
      -- fight the first one. The application can still report the returned error.
      state.active = false
      local called, result, reason = pcall(native.stop)
      if not called then return nil, "terminal backend stop failed: " .. tostring(result) end
      if result == false or (result == nil and reason ~= nil) then
        return nil, reason or "terminal backend failed to stop"
      end
      return true
    end,
    is_active = function() return state.active end,
  }
end

Backend.normalize_capabilities = normalise_capabilities

return Backend
