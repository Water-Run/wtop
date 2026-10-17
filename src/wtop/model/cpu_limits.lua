-- Current CPU package flags are independent of power/cap comparisons.
local Power = require("wtop.model.power")

local M = {}
local MAX_DOMAINS, MAX_REASONS = 512, 64

function M.reduce(data, state)
  local quality = type(state) == "table" and (state.quality or state.status) or state
  local status = type(state) == "table" and state.status or nil
  local result = {
    packages = {}, reasons = {}, known_active = 0, known_inactive = 0,
    unknown = 0, complete = false,
  }
  if status and status ~= "ok" then result.quality = status; return result end
  if Power.unusable(quality) or (quality and quality ~= "fresh" and quality ~= "partial") then
    result.quality = quality
    return result
  end
  if type(data) ~= "table" or type(data.domains) ~= "table" then
    result.quality = "unavailable"
    return result
  end

  -- Duplicate identities cannot establish which package observation is current.
  local identities, seen_reasons = {}, {}
  for index, domain in ipairs(data.domains) do
    if index > MAX_DOMAINS then break end
    if type(domain) == "table" and type(domain.id) == "string" then
      identities[domain.id] = (identities[domain.id] or 0) + 1
    end
  end
  for index, domain in ipairs(data.domains) do
    if index > MAX_DOMAINS then result.truncated = true; break end
    if type(domain) ~= "table" or domain.scope ~= "cpu_package"
        or type(domain.id) ~= "string" or identities[domain.id] > 1 then
      result.unknown = result.unknown + 1
    else
      local row = {
        id = domain.id, package_id = domain.package_id, reader_cpu = domain.cpu_id,
        source = domain.source, quality = domain.quality, reasons = {},
        observed_at_ns = domain.observed_at_ns,
      }
      local usable = domain.quality == "fresh" or domain.quality == "partial"
      local invalid = domain.reasons ~= nil and type(domain.reasons) ~= "table"
      if usable and not invalid then
        for reason_index, reason in ipairs(domain.reasons or {}) do
          if reason_index > MAX_REASONS then invalid = true; break end
          if type(reason) == "table" and reason.active == true then
            if type(reason.id) == "string" and #reason.id <= 64
                and reason.id:match("^[a-z0-9_]+$") then
              row.reasons[#row.reasons + 1] = reason.id
            else
              invalid = true
            end
          end
        end
        if domain.active == false and #row.reasons > 0 then invalid = true end
        -- Keep false: an inactive observation differs from an unknown one.
        if not invalid and type(domain.active) == "boolean" then row.active = domain.active end
      end
      if row.active == true then
        result.known_active = result.known_active + 1
        for _, id in ipairs(row.reasons) do
          if not seen_reasons[id] then
            result.reasons[#result.reasons + 1] = id
            seen_reasons[id] = true
          end
        end
      elseif row.active == false then
        result.known_inactive = result.known_inactive + 1
      else
        result.unknown = result.unknown + 1
        row.reasons = {}
      end
      row.partial = domain.quality == "partial"
      result.packages[#result.packages + 1] = row
    end
  end
  result.truncated = result.truncated or data.truncated == true
  result.complete = data.coverage_complete == true and #result.packages > 0
    and result.unknown == 0 and not result.truncated
  if result.known_active > 0 then
    result.active = true
  elseif result.complete then
    result.active = false
  end
  result.quality = result.complete and "fresh" or "partial"
  for _, row in ipairs(result.packages) do
    if row.partial then result.quality = "partial" end
  end
  table.sort(result.reasons)
  return result
end

return M
