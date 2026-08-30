local Model = {}

local VALID_QUALITY = {
  fresh = true,
  stale = true,
  gap = true,
  partial = true,
  reset = true,
  measured = true,
  estimated = true,
  unavailable = true,
  denied = true,
  error = true,
}

local VALID_STATUS = {
  ok = true,
  unavailable = true,
  denied = true,
  error = true,
}

local function options_table(options, level)
  options = options or {}
  if type(options) ~= "table" then
    error("inspector model options must be a table", level or 3)
  end
  return options
end

local function valid_time(value, allow_nil)
  return (allow_nil and value == nil) or (type(value) == "number"
    and value == value and value ~= math.huge and value ~= -math.huge and value >= 0)
end

local function check_quality(quality, level)
  if not VALID_QUALITY[quality] then
    error("invalid inspector quality: " .. tostring(quality), level or 3)
  end
end

function Model.field(value, unit, options)
  options = options_table(options, 2)
  local quality = options.quality or (value == nil and "unavailable" or "fresh")
  check_quality(quality, 2)
  if not valid_time(options.timestamp_ns, true) then
    error("invalid field timestamp", 2)
  end
  return {
    value = value,
    unit = unit,
    source = options.source,
    timestamp_ns = options.timestamp_ns,
    quality = quality,
    estimated = quality == "estimated" or options.estimated == true,
    permission = options.permission or "user",
    provider = options.provider,
    provider_version = options.provider_version,
    reason = options.reason,
    raw = options.raw,
  }
end

function Model.section(id, fields, options)
  options = options_table(options, 2)
  if type(id) ~= "string" or id == "" or #id > 256 or id:find("\0", 1, true) then
    error("invalid inspector section id", 2)
  end
  if fields ~= nil and type(fields) ~= "table" then
    error("inspector section fields must be a table", 2)
  end
  local quality = options.quality or "fresh"
  check_quality(quality, 2)
  return {
    id = id,
    title_key = options.title_key or ("inspector.section." .. id),
    fields = fields or {},
    quality = quality,
    source = options.source,
  }
end

function Model.entity(id, kind, options)
  options = options_table(options, 2)
  if type(id) ~= "string" or id == "" or #id > 4096 or id:find("\0", 1, true) then
    error("invalid inspector entity id", 2)
  end
  if type(kind) ~= "string" or kind == "" or #kind > 256 or kind:find("\0", 1, true) then
    error("invalid inspector entity kind", 2)
  end
  return {
    id = id,
    kind = kind,
    name = options.name or id,
    identity = options.identity or {},
    summary = options.summary or {},
    metrics = options.metrics or {},
    properties = options.properties or {},
    health = options.health or {},
    relations = options.relations or {},
    evidence = options.evidence or {},
    operations = options.operations or {},
  }
end

function Model.result(status, entity, sections, options)
  options = options_table(options, 2)
  if not VALID_STATUS[status] then
    error("invalid inspector status: " .. tostring(status), 2)
  end
  if entity ~= nil and type(entity) ~= "table" then
    error("inspector result entity must be a table or nil", 2)
  end
  if sections ~= nil and type(sections) ~= "table" then
    error("inspector result sections must be a table", 2)
  end
  local quality = options.quality or (status == "ok" and "fresh" or status)
  check_quality(quality, 2)
  if not valid_time(options.timestamp_ns, true)
      or not valid_time(options.duration_ns or 0, false) then
    error("invalid inspector result timing", 2)
  end
  return {
    status = status,
    timestamp_ns = options.timestamp_ns,
    duration_ns = options.duration_ns or 0,
    quality = quality,
    reason = options.reason,
    entity = entity,
    sections = sections or {},
    source = options.source,
    permission = options.permission or "user",
    provider = options.provider,
    provider_version = options.provider_version,
    cache_ttl_ms = options.cache_ttl_ms,
    cached = options.cached == true,
    details = options.details,
  }
end

Model.VALID_QUALITY = VALID_QUALITY
Model.VALID_STATUS = VALID_STATUS

return Model
