local M = {}

-- The order is deliberately slow-to-fast: one click advances to the next
-- denser sampling level and wraps after "very high".
local LEVELS = {
  { id = "very_low", interval_ms = 8000, label_id = "sampling.frequency.very_low", fallback = "Very low" },
  { id = "low", interval_ms = 5000, label_id = "sampling.frequency.low", fallback = "Low" },
  { id = "moderately_low", interval_ms = 3000, label_id = "sampling.frequency.moderately_low", fallback = "Moderately low" },
  { id = "medium_low", interval_ms = 2000, label_id = "sampling.frequency.medium_low", fallback = "Medium-low" },
  { id = "medium", interval_ms = 1000, label_id = "sampling.frequency.medium", fallback = "Medium" },
  { id = "medium_high", interval_ms = 750, label_id = "sampling.frequency.medium_high", fallback = "Medium-high" },
  { id = "moderately_high", interval_ms = 500, label_id = "sampling.frequency.moderately_high", fallback = "Moderately high" },
  { id = "high", interval_ms = 300, label_id = "sampling.frequency.high", fallback = "High" },
  { id = "very_high", interval_ms = 100, label_id = "sampling.frequency.very_high", fallback = "Very high" },
}

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

function M.level(index)
  if type(index) ~= "number" or index % 1 ~= 0 then return nil end
  return LEVELS[index]
end

function M.nearest_index(interval_ms)
  if not finite(interval_ms) or interval_ms < 1 then return nil end
  local best_index, best_distance
  for index, level in ipairs(LEVELS) do
    local distance = math.abs(level.interval_ms - interval_ms)
    if best_distance == nil or distance < best_distance then
      best_index, best_distance = index, distance
    end
  end
  return best_index
end

function M.cycle(index, delta)
  if not M.level(index) then return nil end
  delta = delta or 1
  if not finite(delta) or delta % 1 ~= 0 then return nil end
  return ((index - 1 + delta) % #LEVELS) + 1
end

M.LEVELS = LEVELS
M.MIN_INTERVAL_MS = LEVELS[#LEVELS].interval_ms
M.MAX_INTERVAL_MS = 10000
M.DEFAULT_INDEX = 5

return M
