-- Leases for isolated SDK readers. The old NVML process API is still safe;
-- none of the direct vendor-query entry points is a fallback.
local M = {}
local sources = { nvml = true, amdsmi = true, levelzero = true, adl = true }
local failures, pending = {}, {}
for source in pairs(sources) do
  pending[source .. "_query_pending"] = true
  for _, suffix in ipairs({ "query_timeout", "worker_unavailable", "worker_busy",
      "worker_exited", "invalid_response", "allocation_failed", "output_too_large",
      "query_failed", "worker_closed" }) do
    failures[source .. "_" .. suffix] = true
  end
end

function M.retry(...)
  for index = 1, select("#", ...) do
    local reason = select(index, ...)
    if pending[reason] then return reason, 250, false end
  end
  for index = 1, select("#", ...) do
    local reason = select(index, ...)
    if failures[reason] then return reason, 5000, true end
  end
end

function M.is_pending(reason) return pending[reason] == true end

function M.default_provider(source, native_override)
  assert(sources[source], "unknown GPU source")
  local ok, native = true, native_override
  if not native then ok, native = pcall(require, "wtop.native") end
  if not ok or type(native) ~= "table" then return nil end
  if type(native.gpu_worker_sources) == "table" and not native.gpu_worker_sources[source] then return nil end
  local open, query, close = native.gpu_worker_open, native.gpu_worker_query, native.gpu_worker_close
  if type(open) ~= "function" or type(query) ~= "function" or type(close) ~= "function" then
    if source ~= "nvml" then return nil end
    open, query, close = native.nvml_worker_open, native.nvml_worker_query, native.nvml_worker_close
    if type(open) ~= "function" or type(query) ~= "function" or type(close) ~= "function" then return nil end
  end
  local session, closed
  local function read(include_processes)
    if closed then return nil, source .. "_worker_closed" end
    if not session then
      local created, value = pcall(open, source)
      if not created then return nil, source .. "_allocation_failed" end
      if not value then return nil, source .. "_worker_unavailable" end
      session = value
    end
    local called, data, reason = pcall(query, session, include_processes == true)
    if not called then return nil, source .. "_query_failed" end
    return data, reason
  end
  return read, function()
    closed = true
    if session then return close(session, 0) end
    return true
  end
end

return M
