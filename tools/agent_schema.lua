-- Validate a document against the subset of JSON Schema that
-- docs/agent-v1.schema.json actually uses.
--
-- Why this exists.  `make check` parsed that schema and stopped there: it proved
-- the file is JSON, which is a statement about the schema and not about the
-- document wtop emits.  Nothing in the tree ever applied it, so a contract
-- published for downstream consumers -- an LLM or a script that reads
-- `--agent` -- was kept by hand and could drift in either direction without
-- anything noticing.  The drift is not hypothetical in the shape: the three
-- collection limits in `export.lua` and the three `maxItems` in the schema are
-- the same numbers written down independently, and the comment beside the first
-- three says they "are part of agent-v1.schema.json", which is a relationship
-- only a check can hold.
--
-- Why it is written in Lua and uses this project's own decoder.  The check has
-- to run wherever the suite runs, including the manylinux2014 container whose
-- interpreter is Python 3.6, and it has to run inside `make check` next to
-- everything else.  A second JSON parser would also be a second opinion about
-- what the document is.
--
-- The rule that makes this worth having: a keyword this file does not implement
-- is a hard error, never a silent pass.  A validator that ignores what it does
-- not understand is exactly the defect it was written to remove -- a document
-- asserting a conclusion nobody established, in the shape of a tool reporting
-- that a document is valid.  So `unsupported_keywords` is checked first, and a
-- schema that grows `$ref` to another file, or `oneOf`, or `pattern`, stops the
-- check with a message naming the keyword rather than validating less.

local JSON = require("wtop.core.json")

local M = {}

-- Every keyword this validator implements, and nothing else is tolerated.
local SUPPORTED = {
  -- applicators
  ["$ref"] = true, ["$defs"] = true, ["properties"] = true,
  ["items"] = true, ["additionalProperties"] = true, ["required"] = true,
  -- assertions
  ["type"] = true, ["const"] = true, ["enum"] = true, ["minimum"] = true,
  ["minLength"] = true, ["maxLength"] = true, ["maxItems"] = true,
  -- annotations, which constrain nothing and are carried for completeness
  ["$schema"] = true, ["$id"] = true, ["title"] = true, ["description"] = true,
}

-- JSON has one number type, one string type and one boolean type, so those map
-- onto Lua's directly.  Objects and arrays are both tables, and the schema
-- distinguishes them -- it says "array" for `signals` and "object" for
-- `metrics`, and a validator that cannot tell them apart would accept a string
-- where a list belongs.  The distinction is the same one the wire format makes:
-- an array has exactly the keys 1..n and nothing else.
local KNOWN_TYPES = {
  object = true, array = true, string = true, number = true,
  integer = true, boolean = true, null = true,
}

local function is_array(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then return false end
  end
  -- An empty table is deliberately not called an array.  `{}` and `[]` are
  -- distinguishable on the wire and indistinguishable after decoding, so this
  -- reports the more conservative of the two and matches_type widens it back
  -- out; see the note there for what that costs.
  return count > 0
end

local function is_empty_table(value)
  return type(value) == "table" and next(value) == nil
end

local function type_of(value)
  if value == nil then return "null" end
  if type(value) == "table" then
    return is_array(value) and "array" or "object"
  end
  return type(value)
end

local function matches_type(value, wanted)
  if wanted == "null" then return value == nil end
  if wanted == "integer" then
    -- Lua does not distinguish 1 from 1.0 the way the wire format does, so an
    -- integer is a number with no fractional part.
    return type(value) == "number" and value == math.floor(value)
  end
  if type(wanted) == "table" then
    for _, one in ipairs(wanted) do
      if matches_type(value, one) then return true end
    end
    return false
  end
  -- An empty table satisfies both "object" and "array".  The decoder hands
  -- back one Lua type for two JSON types, so the alternative is to accept a
  -- real violation -- an empty list where the schema wants an object -- or to
  -- reject a legitimate empty one.  The cost is that an empty container in the
  -- wrong place passes, which is a narrower hole than the alternative and is
  -- stated here rather than left for a reader to discover.
  if is_empty_table(value) and (wanted == "object" or wanted == "array") then
    return true
  end
  return type_of(value) == wanted
end

-- Walk every subschema and report any keyword this file does not implement.
local function unsupported_keywords(node, found, path)
  if type(node) ~= "table" then return found end
  for key, value in pairs(node) do
    -- `type` is checked first and on its own.  It is an assertion rather than
    -- an applicator, so there is nothing below to walk into, and a type name
    -- this file does not implement is a rule it cannot test.  Putting this
    -- behind `SUPPORTED[key]` instead made it unreachable -- `type` is in that
    -- table -- and the only symptom was a test that passed for the wrong
    -- reason: a schema asking for a made-up type was rejected as a plain
    -- mismatch, which is a different finding wearing the same coat.
    if key == "type" then
      local names = type(value) == "table" and value or { value }
      for _, name in ipairs(names) do
        if not KNOWN_TYPES[name] then
          found[path] = "type:" .. tostring(name)
        end
      end
    elseif SUPPORTED[key] then
      if key == "properties" or key == "$defs" then
        if type(value) == "table" then
          for name, child in pairs(value) do
            unsupported_keywords(child, found, path .. "." .. key .. "." .. name)
          end
        end
      elseif key == "items" or key == "additionalProperties" then
        if type(value) == "table" then
          unsupported_keywords(value, found, path .. "." .. key)
        end
      end
    else
      found[path] = key
    end
  end
  return found
end

local function resolve(schema, root, path, errors)
  local ref = schema["$ref"]
  if type(ref) ~= "string" then return schema end
  if not ref:match("^#/") then
    errors[#errors + 1] = path .. ": $ref " .. ref
      .. " points outside this document; this validator resolves only local references"
    return schema
  end
  local target = root
  for part in ref:sub(3):gmatch("[^/]+") do
    if type(target) ~= "table" or target[part] == nil then
      errors[#errors + 1] = path .. ": $ref " .. ref .. " does not resolve"
      return schema
    end
    target = target[part]
  end
  return target
end

local function validate_node(value, schema, root, path, errors)
  schema = resolve(schema, root, path, errors)
  if type(schema) ~= "table" then
    errors[#errors + 1] = path .. ": the schema here is not an object"
    return
  end

  if schema.type ~= nil then
    if not matches_type(value, schema.type) then
      errors[#errors + 1] = string.format("%s: expected %s, found %s",
        path, schema.type, type_of(value))
      return
    end
  end

  if schema.const ~= nil and value ~= schema.const then
    errors[#errors + 1] = string.format("%s: expected the constant %q, found %q",
      path, tostring(schema.const), tostring(value))
  end

  if type(schema.enum) == "table" then
    local found = false
    for _, allowed in ipairs(schema.enum) do
      if allowed == value then found = true break end
    end
    if not found then
      errors[#errors + 1] = string.format("%s: %q is not one of the allowed values",
        path, tostring(value))
    end
  end

  if type(value) == "string" then
    if type(schema.minLength) == "number" and #value < schema.minLength then
      errors[#errors + 1] = string.format("%s: shorter than minLength %d",
        path, schema.minLength)
    end
    if type(schema.maxLength) == "number" and #value > schema.maxLength then
      errors[#errors + 1] = string.format("%s: longer than maxLength %d (%d characters)",
        path, schema.maxLength, #value)
    end
  end

  if type(value) == "number" then
    if type(schema.minimum) == "number" and value < schema.minimum then
      errors[#errors + 1] = string.format("%s: below the minimum %s", path,
        tostring(schema.minimum))
    end
  end

  if type(value) == "table" then
    if type(schema.maxItems) == "number" and #value > schema.maxItems then
      errors[#errors + 1] = string.format("%s: %d items exceeds maxItems %d",
        path, #value, schema.maxItems)
    end
    if type(schema.items) == "table" then
      for index, item in ipairs(value) do
        validate_node(item, schema.items, root,
          string.format("%s[%d]", path, index), errors)
      end
    end
    if type(schema.required) == "table" then
      for _, name in ipairs(schema.required) do
        if value[name] == nil then
          errors[#errors + 1] = string.format("%s: required property %q is absent",
            path, name)
        end
      end
    end
    local properties = type(schema.properties) == "table" and schema.properties or {}
    local extra = schema.additionalProperties
    for name, child in pairs(value) do
      if properties[name] ~= nil then
        validate_node(child, properties[name], root, path .. "." .. name, errors)
      elseif extra == false then
        errors[#errors + 1] = string.format("%s: property %q is not permitted here",
          path, name)
      elseif type(extra) == "table" then
        validate_node(child, extra, root, path .. "." .. name, errors)
      end
    end
  end
end

--- Validate `document` against `schema`.
-- Returns an array of human-readable error strings; empty means conforming.
-- An unsupported keyword in the schema is itself an error, never a pass.
function M.validate(document, schema)
  local errors = {}
  if type(schema) ~= "table" then
    return { "the schema is not a decoded JSON object" }
  end
  local unknown = unsupported_keywords(schema, {}, "$")
  if next(unknown) ~= nil then
    local names = {}
    for path, keyword in pairs(unknown) do
      names[#names + 1] = string.format("%s: %s", path, keyword)
    end
    table.sort(names)
    return names
  end
  validate_node(document, schema, schema, "$", errors)
  return errors
end

--- Decode both files and validate.  Returns errors, or nil plus a reason.
function M.validate_files(schema_path, document_path)
  local function slurp(path)
    local handle = io.open(path, "rb")
    if not handle then return nil, "cannot read " .. path end
    local body = handle:read("*a")
    handle:close()
    return body
  end
  local schema_text, schema_err = slurp(schema_path)
  if not schema_text then return nil, schema_err end
  local document_text, document_err = slurp(document_path)
  if not document_text then return nil, document_err end
  local schema, decode_error = JSON.decode(schema_text)
  if not schema then
    return nil, schema_path .. " is not decodable JSON: " .. tostring(decode_error and decode_error.message)
  end
  local document, document_error = JSON.decode(document_text)
  if not document then
    return nil, document_path .. " is not decodable JSON: " .. tostring(document_error and document_error.message)
  end
  return M.validate(document, schema), nil
end

return M
