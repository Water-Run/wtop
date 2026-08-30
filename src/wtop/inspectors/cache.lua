local Cache = {}
Cache.__index = Cache

local MAX_TTL_MS = 7 * 24 * 60 * 60 * 1000
local MAX_KEY_BYTES = 8192
local MAX_COPY_DEPTH = 64
local MAX_COPY_NODES = 131072

local function finite_nonnegative(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge and value >= 0
end

local function valid_key(key)
  return type(key) == "string" and #key > 0 and #key <= MAX_KEY_BYTES
    and not key:find("\0", 1, true)
end

local function clone(value, seen, state, depth)
  if type(value) ~= "table" then return value end
  if depth > MAX_COPY_DEPTH or state.nodes >= MAX_COPY_NODES then
    return nil, "cache_value_too_complex"
  end
  if seen[value] then return seen[value] end
  state.nodes = state.nodes + 1
  local output = {}
  seen[value] = output
  for key, item in pairs(value) do
    local key_copy, key_error = clone(key, seen, state, depth + 1)
    if key_error then return nil, key_error end
    local item_copy, item_error = clone(item, seen, state, depth + 1)
    if item_error then return nil, item_error end
    output[key_copy] = item_copy
  end
  return output
end

local function copy_value(value)
  return clone(value, {}, { nodes = 0 }, 1)
end

function Cache.new(options)
  options = options or {}
  if type(options) ~= "table" then error("cache options must be a table", 2) end
  local maximum = options.max_entries or 512
  if type(maximum) ~= "number" or maximum % 1 ~= 0 or maximum < 1 or maximum > 65536 then
    error("cache max_entries must be an integer in 1..65536", 2)
  end
  return setmetatable({ entries = {}, max_entries = maximum, sequence = 0, count = 0 }, Cache)
end

function Cache:get(key, now_ns)
  if not valid_key(key) or not finite_nonnegative(now_ns) then
    return nil, "invalid_cache_lookup"
  end
  local entry = self.entries[key]
  if not entry then
    return nil
  end
  if entry.expires_ns and now_ns >= entry.expires_ns then
    self.entries[key] = nil
    self.count = math.max(0, self.count - 1)
    return nil
  end
  entry.sequence = self.sequence + 1
  self.sequence = entry.sequence
  return copy_value(entry.value)
end

function Cache:put(key, value, now_ns, ttl_ms)
  if not valid_key(key) or not finite_nonnegative(now_ns) then
    return nil, "invalid_cache_entry"
  end
  if ttl_ms ~= nil and (type(ttl_ms) ~= "number" or ttl_ms % 1 ~= 0
      or ttl_ms < 0 or ttl_ms > MAX_TTL_MS) then
    return nil, "invalid_cache_ttl"
  end
  local expires_ns
  if ttl_ms ~= nil then
    local delta = ttl_ms * 1000000
    if delta > math.maxinteger or now_ns > math.maxinteger - delta then
      return nil, "cache_expiry_out_of_range"
    end
    expires_ns = now_ns + delta
  end
  local stored, copy_error = copy_value(value)
  if copy_error then return nil, copy_error end
  if not self.entries[key] and self.count >= self.max_entries then
    local oldest_key, oldest_sequence
    for candidate, entry in pairs(self.entries) do
      if not oldest_sequence or entry.sequence < oldest_sequence then
        oldest_key, oldest_sequence = candidate, entry.sequence
      end
    end
    if oldest_key then
      self.entries[oldest_key] = nil
      self.count = self.count - 1
    end
  end
  self.sequence = self.sequence + 1
  if not self.entries[key] then self.count = self.count + 1 end
  self.entries[key] = {
    value = stored,
    expires_ns = expires_ns,
    sequence = self.sequence,
  }
  return copy_value(stored)
end

function Cache:invalidate(key)
  if key == nil then
    self.entries = {}
    self.count = 0
  else
    if self.entries[key] then
      self.entries[key] = nil
      self.count = math.max(0, self.count - 1)
    end
  end
end

Cache.MAX_TTL_MS = MAX_TTL_MS
Cache.copy_value = copy_value

return Cache
