-- A deliberately small, non-extensible YAML 1.2 profile parser.
--
-- It supports the data model needed by wtop catalogs: block mappings and
-- sequences, quoted/plain strings, decimal integers, booleans and null.  It
-- never constructs objects or executes tags, and rejects aliases, anchors,
-- merge keys, flow collections (except empty []/{}) and multi-document input.

local M = {}
local FS = require("wtop.linux.fs")

M.null = setmetatable({}, {
  __tostring = function()
    return "null"
  end,
})

local DEFAULT_MAX_BYTES = 1024 * 1024
local DEFAULT_MAX_DEPTH = 32
local DEFAULT_MAX_NODES = 20000
local DEFAULT_MAX_SCALAR_BYTES = 65536
local MAX_DOCUMENT_BYTES = 16 * 1024 * 1024
local MAX_DEPTH = 128
local MAX_NODES = 200000
local MAX_SCALAR_BYTES = 1024 * 1024
local MAX_SOURCE_BYTES = 4096

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function pointer(path)
  if #path == 0 then
    return "/"
  end
  local parts = {}
  for i, item in ipairs(path) do
    local encoded = tostring(item):gsub("~", "~0"):gsub("/", "~1")
    parts[i] = encoded
  end
  return "/" .. table.concat(parts, "/")
end

local function child_path(path, item)
  local result = {}
  for i, value in ipairs(path) do
    result[i] = value
  end
  result[#result + 1] = item
  return result
end

local function locate(info, path, line, column)
  info.locations[pointer(path)] = { line = line, column = column }
end

local function failure(source, line, column, message)
  return string.format("%s:%d:%d: %s", source, line or 1, column or 1, message)
end

local function checked_source(value, fallback)
  value = value == nil and fallback or value
  if type(value) ~= "string" or value == "" or #value > MAX_SOURCE_BYTES
      or value:find("[%z\1-\31\127]") then
    return nil, "source must be a non-empty safe string"
  end
  return value
end

local function checked_limit(value, default, maximum, name)
  if value == nil then return default end
  if type(value) ~= "number" or math.type(value) ~= "integer"
      or value < 1 or value > maximum then
    return nil, name .. " must be a positive integer no greater than " .. maximum
  end
  return value
end

local function strip_comment(text)
  local single, double, escaped = false, false, false
  local i = 1
  while i <= #text do
    local char = text:sub(i, i)
    if double then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        double = false
      end
    elseif single then
      if char == "'" and text:sub(i + 1, i + 1) == "'" then
        i = i + 1
      elseif char == "'" then
        single = false
      end
    elseif char == '"' then
      double = true
    elseif char == "'" then
      single = true
    elseif char == "#" and (i == 1 or text:sub(i - 1, i - 1):match("%s")) then
      return text:sub(1, i - 1):gsub("%s+$", "")
    end
    i = i + 1
  end
  return text:gsub("%s+$", "")
end

local function find_mapping_colon(text)
  local single, double, escaped = false, false, false
  local i = 1
  while i <= #text do
    local char = text:sub(i, i)
    if double then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        double = false
      end
    elseif single then
      if char == "'" and text:sub(i + 1, i + 1) == "'" then
        i = i + 1
      elseif char == "'" then
        single = false
      end
    elseif char == '"' then
      double = true
    elseif char == "'" then
      single = true
    elseif char == ":" then
      local following = text:sub(i + 1, i + 1)
      if following == "" or following:match("%s") then
        return i
      end
    end
    i = i + 1
  end
  return nil
end

local function utf8_character(codepoint)
  if codepoint < 0 or codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff) then
    return nil
  end
  return utf8.char(codepoint)
end

local function parse_double_quoted(text, source, line, column)
  local output = {}
  local i = 2
  while i <= #text do
    local char = text:sub(i, i)
    if char == '"' then
      if trim(text:sub(i + 1)) ~= "" then
        return nil, failure(source, line, column + i, "characters after quoted scalar")
      end
      return table.concat(output)
    end
    if char ~= "\\" then
      output[#output + 1] = char
      i = i + 1
    else
      local escape = text:sub(i + 1, i + 1)
      local simple = {
        ['"'] = '"',
        ["\\"] = "\\",
        ["/"] = "/",
        b = "\b",
        f = "\f",
        n = "\n",
        r = "\r",
        t = "\t",
      }
      if simple[escape] then
        output[#output + 1] = simple[escape]
        i = i + 2
      elseif escape == "x" or escape == "u" or escape == "U" then
        local digits = escape == "x" and 2 or (escape == "u" and 4 or 8)
        local hexadecimal = text:sub(i + 2, i + 1 + digits)
        if #hexadecimal ~= digits or not hexadecimal:match("^[0-9a-fA-F]+$") then
          return nil, failure(source, line, column + i, "invalid Unicode escape")
        end
        local encoded = utf8_character(tonumber(hexadecimal, 16))
        if not encoded then
          return nil, failure(source, line, column + i, "invalid Unicode code point")
        end
        output[#output + 1] = encoded
        i = i + 2 + digits
      else
        return nil, failure(source, line, column + i, "unsupported escape sequence")
      end
    end
  end
  return nil, failure(source, line, column, "unterminated double-quoted scalar")
end

local function parse_single_quoted(text, source, line, column)
  local output = {}
  local i = 2
  while i <= #text do
    local char = text:sub(i, i)
    if char == "'" then
      if text:sub(i + 1, i + 1) == "'" then
        output[#output + 1] = "'"
        i = i + 2
      else
        if trim(text:sub(i + 1)) ~= "" then
          return nil, failure(source, line, column + i, "characters after quoted scalar")
        end
        return table.concat(output)
      end
    else
      output[#output + 1] = char
      i = i + 1
    end
  end
  return nil, failure(source, line, column, "unterminated single-quoted scalar")
end

local function parse_scalar(text, state, token, column, path)
  if #text > state.max_scalar_bytes then
    return nil, failure(state.source, token.line, column, "scalar exceeds configured size limit")
  end

  if text:sub(1, 1) == '"' then
    return parse_double_quoted(text, state.source, token.line, column)
  end
  if text:sub(1, 1) == "'" then
    return parse_single_quoted(text, state.source, token.line, column)
  end
  if text == "[]" then
    state.info.kinds[pointer(path)] = "sequence"
    return {}
  end
  if text == "{}" then
    state.info.kinds[pointer(path)] = "mapping"
    return {}
  end
  if text:match("^[%[%]{},]") then
    return nil, failure(state.source, token.line, column, "flow collections are not supported")
  end
  if text:match("^[&*!]") then
    return nil, failure(state.source, token.line, column, "anchors, aliases and tags are forbidden")
  end
  if text == "|" or text == ">" or text:match("^[|>]%d") then
    return nil, failure(state.source, token.line, column, "block scalars are not supported by this profile")
  end
  if text == "true" then
    return true
  end
  if text == "false" then
    return false
  end
  if text == "null" or text == "~" then
    return M.null
  end
  if text:match("^[-+]?%d+$") then
    if text:match("^[-+]?0%d") then
      return nil, failure(state.source, token.line, column, "integers with leading zeroes are forbidden")
    end
    local number = tonumber(text)
    if not number or math.type(number) ~= "integer" then
      return nil, failure(state.source, token.line, column, "integer is outside the Lua integer range")
    end
    return number
  end
  if text:find(":%s") then
    return nil, failure(state.source, token.line, column, "plain scalar contains an unquoted mapping separator")
  end
  return text
end

local function parse_key(text, state, token, column)
  if text == "" then
    return nil, failure(state.source, token.line, column, "empty mapping key")
  end
  local key, err
  if text:sub(1, 1) == '"' then
    key, err = parse_double_quoted(text, state.source, token.line, column)
  elseif text:sub(1, 1) == "'" then
    key, err = parse_single_quoted(text, state.source, token.line, column)
  elseif text:match("^[A-Za-z0-9_.-]+$") then
    key = text
  else
    err = failure(state.source, token.line, column, "mapping key must be quoted or use [A-Za-z0-9_.-]")
  end
  if not key then
    return nil, err
  end
  if key == "<<" then
    return nil, failure(state.source, token.line, column, "YAML merge keys are forbidden")
  end
  return key
end

local function tokenize(text, state)
  local tokens = {}
  local content_started, document_ended, explicit_document = false, false, false
  local line_number = 0

  local function append(token)
    if #tokens >= state.max_tokens then
      return nil, failure(state.source, token.line, token.indent + 1,
        "document exceeds configured token limit")
    end
    tokens[#tokens + 1] = token
    return true
  end

  for raw_line in (text .. "\n"):gmatch("(.-)\n") do
    line_number = line_number + 1
    if raw_line:find("\r", 1, true) then
      return nil, failure(state.source, line_number, 1, "bare carriage return is forbidden")
    end
    local spaces = raw_line:match("^( *)")
    local indent = #spaces
    if raw_line:sub(indent + 1, indent + 1) == "\t" then
      return nil, failure(state.source, line_number, indent + 1, "tabs are forbidden in indentation")
    end
    local content = strip_comment(raw_line:sub(indent + 1))
    if content ~= "" then
      if content == "---" then
        if indent ~= 0 or content_started or explicit_document or document_ended then
          return nil, failure(state.source, line_number, indent + 1, "multiple YAML documents are forbidden")
        end
        explicit_document = true
      elseif content == "..." then
        if indent ~= 0 or not content_started or document_ended then
          return nil, failure(state.source, line_number, indent + 1, "invalid document end marker")
        end
        document_ended = true
      elseif content:sub(1, 1) == "%" then
        return nil, failure(state.source, line_number, indent + 1, "YAML directives are not supported")
      elseif document_ended then
        return nil, failure(state.source, line_number, indent + 1, "content after document end marker")
      else
        content_started = true
        local remainder = content:match("^%-%s+(.+)$")
        if remainder and find_mapping_colon(remainder) then
          local appended, append_error = append({ indent = indent, content = "-", line = line_number })
          if not appended then return nil, append_error end
          appended, append_error = append({
            indent = indent + 2,
            content = remainder,
            line = line_number,
            virtual = true,
          })
          if not appended then return nil, append_error end
        else
          local appended, append_error = append({ indent = indent, content = content, line = line_number })
          if not appended then return nil, append_error end
        end
      end
    end
  end
  return tokens
end

local parse_block

local function add_node(state, token)
  state.nodes = state.nodes + 1
  if state.nodes > state.max_nodes then
    return nil, failure(state.source, token.line, token.indent + 1, "document exceeds configured node limit")
  end
  return true
end

local function parse_mapping(tokens, position, indent, state, path, depth)
  local result, seen = {}, {}
  state.info.kinds[pointer(path)] = "mapping"

  while position <= #tokens do
    local token = tokens[position]
    if token.indent < indent then
      break
    end
    if token.indent > indent then
      return nil, position, failure(state.source, token.line, token.indent + 1, "unexpected indentation")
    end
    if token.content == "-" or token.content:match("^%-%s") then
      return nil, position, failure(state.source, token.line, token.indent + 1, "cannot mix sequence and mapping entries")
    end

    local colon = find_mapping_colon(token.content)
    if not colon then
      return nil, position, failure(state.source, token.line, token.indent + 1, "expected a mapping entry")
    end
    local raw_key = trim(token.content:sub(1, colon - 1))
    local key_column = token.indent + 1
    local key, key_err = parse_key(raw_key, state, token, key_column)
    if not key then
      return nil, position, key_err
    end
    if seen[key] then
      return nil, position, failure(
        state.source,
        token.line,
        key_column,
        string.format("duplicate key %q (first declared on line %d)", key, seen[key])
      )
    end
    seen[key] = token.line

    local ok, node_err = add_node(state, token)
    if not ok then
      return nil, position, node_err
    end

    local value_path = child_path(path, key)
    locate(state.info, value_path, token.line, key_column)
    local raw_value = trim(token.content:sub(colon + 1))
    position = position + 1
    local value
    if raw_value == "" then
      local next_token = tokens[position]
      if next_token and next_token.indent > indent then
        value, position, node_err = parse_block(tokens, position, next_token.indent, state, value_path, depth + 1)
        if not value then
          return nil, position, node_err
        end
      else
        value = M.null
      end
    else
      local value_column = token.indent + colon + 1
      value, node_err = parse_scalar(raw_value, state, token, value_column, value_path)
      if value == nil then
        return nil, position, node_err
      end
    end
    result[key] = value
  end
  return result, position
end

local function parse_sequence(tokens, position, indent, state, path, depth)
  local result = {}
  state.info.kinds[pointer(path)] = "sequence"

  while position <= #tokens do
    local token = tokens[position]
    if token.indent < indent then
      break
    end
    if token.indent > indent then
      return nil, position, failure(state.source, token.line, token.indent + 1, "unexpected indentation")
    end
    if token.content ~= "-" and not token.content:match("^%-%s") then
      return nil, position, failure(state.source, token.line, token.indent + 1, "cannot mix mapping and sequence entries")
    end

    local ok, node_err = add_node(state, token)
    if not ok then
      return nil, position, node_err
    end

    local item_path = child_path(path, #result + 1)
    locate(state.info, item_path, token.line, token.indent + 1)
    local raw_value = token.content == "-" and "" or trim(token.content:sub(2))
    position = position + 1
    local value
    if raw_value == "" then
      local next_token = tokens[position]
      if next_token and next_token.indent > indent then
        value, position, node_err = parse_block(tokens, position, next_token.indent, state, item_path, depth + 1)
        if not value then
          return nil, position, node_err
        end
      else
        value = M.null
      end
    else
      value, node_err = parse_scalar(raw_value, state, token, token.indent + 3, item_path)
      if value == nil then
        return nil, position, node_err
      end
    end
    result[#result + 1] = value
  end
  return result, position
end

parse_block = function(tokens, position, indent, state, path, depth)
  if depth > state.max_depth then
    local token = tokens[position]
    return nil, position, failure(state.source, token.line, token.indent + 1, "document exceeds configured depth limit")
  end
  local token = tokens[position]
  if not token or token.indent ~= indent then
    return nil, position, failure(state.source, token and token.line or 1, token and token.indent + 1 or 1, "invalid indentation")
  end
  if token.content == "-" or token.content:match("^%-%s") then
    return parse_sequence(tokens, position, indent, state, path, depth)
  end
  return parse_mapping(tokens, position, indent, state, path, depth)
end

function M.parse(text, options)
  if options == nil then
    options = {}
  elseif type(options) == "string" then
    options = { source = options }
  elseif type(options) ~= "table" then
    return nil, failure("<yaml>", 1, 1, "options must be a table or source string")
  end
  local source, source_err = checked_source(options.source, "<yaml>")
  if not source then return nil, failure("<yaml>", 1, 1, source_err) end
  if type(text) ~= "string" then
    return nil, failure(source, 1, 1, "input must be a string")
  end
  local max_bytes, limit_err = checked_limit(
    options.max_bytes, DEFAULT_MAX_BYTES, MAX_DOCUMENT_BYTES, "max_bytes")
  if not max_bytes then return nil, failure(source, 1, 1, limit_err) end
  local max_depth
  max_depth, limit_err = checked_limit(options.max_depth, DEFAULT_MAX_DEPTH, MAX_DEPTH, "max_depth")
  if not max_depth then return nil, failure(source, 1, 1, limit_err) end
  local max_nodes
  max_nodes, limit_err = checked_limit(options.max_nodes, DEFAULT_MAX_NODES, MAX_NODES, "max_nodes")
  if not max_nodes then return nil, failure(source, 1, 1, limit_err) end
  local max_tokens
  max_tokens, limit_err = checked_limit(options.max_tokens, max_nodes, MAX_NODES, "max_tokens")
  if not max_tokens then return nil, failure(source, 1, 1, limit_err) end
  local max_scalar_bytes
  max_scalar_bytes, limit_err = checked_limit(
    options.max_scalar_bytes, DEFAULT_MAX_SCALAR_BYTES, MAX_SCALAR_BYTES, "max_scalar_bytes")
  if not max_scalar_bytes then return nil, failure(source, 1, 1, limit_err) end
  if max_scalar_bytes > max_bytes then max_scalar_bytes = max_bytes end
  if #text > max_bytes then
    return nil, failure(source, 1, 1, "document exceeds configured size limit")
  end
  if text:find("\0", 1, true) then
    return nil, failure(source, 1, 1, "NUL bytes are forbidden")
  end
  local valid, invalid_position = utf8.len(text)
  if not valid then
    local prefix = text:sub(1, invalid_position - 1):gsub("\r\n", "\n")
    local line = 1
    for _ in prefix:gmatch("\n") do
      line = line + 1
    end
    local last_newline = prefix:match(".*()\n")
    local column = invalid_position - (last_newline or 0)
    return nil, failure(source, line, column, "input is not valid UTF-8")
  end
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  text = text:gsub("\r\n", "\n")

  local info = { source = source, locations = {}, kinds = {} }
  local state = {
    source = source,
    info = info,
    nodes = 0,
    max_depth = max_depth,
    max_nodes = max_nodes,
    max_tokens = max_tokens,
    max_scalar_bytes = max_scalar_bytes,
  }

  local tokens, token_err = tokenize(text, state)
  if not tokens then
    return nil, token_err
  end
  if #tokens == 0 then
    return nil, failure(source, 1, 1, "empty YAML document")
  end
  if tokens[1].indent ~= 0 then
    return nil, failure(source, tokens[1].line, tokens[1].indent + 1, "root node must start at column 1")
  end

  locate(info, {}, tokens[1].line, 1)
  local value, position, parse_err = parse_block(tokens, 1, 0, state, {}, 1)
  if not value then
    return nil, parse_err
  end
  if position <= #tokens then
    local token = tokens[position]
    return nil, failure(source, token.line, token.indent + 1, "unexpected trailing content")
  end
  return value, info
end

function M.parse_file(path, options)
  if options == nil then options = {} end
  if type(options) ~= "table" then
    return nil, failure("<yaml>", 1, 1, "options must be a table")
  end
  if type(path) ~= "string" or path == "" or #path > MAX_SOURCE_BYTES
      or path:find("[%z\1-\31\127]") then
    return nil, failure("<yaml>", 1, 1, "path must be a non-empty safe string")
  end
  local source, source_err = checked_source(options.source, path)
  if not source then return nil, failure("<yaml>", 1, 1, source_err) end
  local max_bytes, limit_err = checked_limit(
    options.max_bytes, DEFAULT_MAX_BYTES, MAX_DOCUMENT_BYTES, "max_bytes")
  if not max_bytes then return nil, failure(source, 1, 1, limit_err) end
  local text, read_error = FS.default:read(path, max_bytes)
  if not text then
    local reason = read_error and read_error.kind == "too_large"
        and "document exceeds configured size limit"
      or ("cannot read file: " .. tostring(read_error and read_error.message or "unknown error"))
    return nil, failure(source, 1, 1, reason)
  end
  local parse_options = {}
  for key, value in pairs(options) do
    parse_options[key] = value
  end
  parse_options.source = source
  return M.parse(text, parse_options)
end

M.DEFAULT_MAX_BYTES = DEFAULT_MAX_BYTES
M.MAX_DOCUMENT_BYTES = MAX_DOCUMENT_BYTES
M.MAX_DEPTH = MAX_DEPTH
M.MAX_NODES = MAX_NODES
M.MAX_SCALAR_BYTES = MAX_SCALAR_BYTES

return M
