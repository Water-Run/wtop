-- Small, strict JSON decoder for structured optional-tool output.
-- It intentionally implements decoding only and enforces depth/input/node limits.

local DEFAULT_MAX_BYTES = 4 * 1024 * 1024
local DEFAULT_MAX_DEPTH = 64
local DEFAULT_MAX_NODES = 100000
local HARD_MAX_BYTES = 64 * 1024 * 1024
local HARD_MAX_DEPTH = 256
local HARD_MAX_NODES = 1000000

local JSON = {
  null = {},
  DEFAULT_MAX_BYTES = DEFAULT_MAX_BYTES,
  DEFAULT_MAX_DEPTH = DEFAULT_MAX_DEPTH,
  DEFAULT_MAX_NODES = DEFAULT_MAX_NODES,
  HARD_MAX_BYTES = HARD_MAX_BYTES,
  HARD_MAX_DEPTH = HARD_MAX_DEPTH,
  HARD_MAX_NODES = HARD_MAX_NODES,
}

local function decode_error(parser, message)
  error({ message = message, position = parser.position }, 0)
end

local function skip_space(parser)
  local _, finish = parser.text:find("^[ \t\r\n]*", parser.position)
  parser.position = (finish or parser.position - 1) + 1
end

local function utf8_character(codepoint)
  if codepoint < 0 or codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff) then
    return nil
  end
  return utf8.char(codepoint)
end

local parse_value

local function append_utf8_chunk(parser, chunks, first, last)
  if last < first then return end
  local chunk = parser.text:sub(first, last)
  local valid, invalid_position = utf8.len(chunk)
  if valid == nil then
    parser.position = first + invalid_position - 1
    decode_error(parser, "invalid_utf8")
  end
  chunks[#chunks + 1] = chunk
end

local function parse_string(parser)
  if parser.text:sub(parser.position, parser.position) ~= '"' then
    decode_error(parser, "expected_string")
  end
  parser.position = parser.position + 1
  local chunks = {}
  local chunk_start = parser.position
  while parser.position <= parser.length do
    local byte = parser.text:byte(parser.position)
    if byte == 34 then
      append_utf8_chunk(parser, chunks, chunk_start, parser.position - 1)
      parser.position = parser.position + 1
      return table.concat(chunks)
    elseif byte == 92 then
      append_utf8_chunk(parser, chunks, chunk_start, parser.position - 1)
      local escape = parser.text:sub(parser.position + 1, parser.position + 1)
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
        chunks[#chunks + 1] = simple[escape]
        parser.position = parser.position + 2
      elseif escape == "u" then
        local hex = parser.text:sub(parser.position + 2, parser.position + 5)
        if not hex:match("^%x%x%x%x$") then
          decode_error(parser, "invalid_unicode_escape")
        end
        local codepoint = tonumber(hex, 16)
        parser.position = parser.position + 6
        if codepoint >= 0xd800 and codepoint <= 0xdbff then
          if parser.text:sub(parser.position, parser.position + 1) ~= "\\u" then
            decode_error(parser, "missing_low_surrogate")
          end
          local low_hex = parser.text:sub(parser.position + 2, parser.position + 5)
          local low = low_hex:match("^%x%x%x%x$") and tonumber(low_hex, 16) or nil
          if not low or low < 0xdc00 or low > 0xdfff then
            decode_error(parser, "invalid_low_surrogate")
          end
          codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00)
          parser.position = parser.position + 6
        elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
          decode_error(parser, "unexpected_low_surrogate")
        end
        local character = utf8_character(codepoint)
        if not character then
          decode_error(parser, "invalid_unicode_codepoint")
        end
        chunks[#chunks + 1] = character
      else
        decode_error(parser, "invalid_escape")
      end
      chunk_start = parser.position
    elseif byte < 32 then
      decode_error(parser, "control_character_in_string")
    else
      parser.position = parser.position + 1
    end
  end
  decode_error(parser, "unterminated_string")
end

local function parse_number(parser)
  local start = parser.position
  local position = start
  local text = parser.text
  local function byte()
    return text:byte(position)
  end
  local function digit(value)
    return value and value >= 48 and value <= 57
  end

  if byte() == 45 then position = position + 1 end -- '-'

  local first = byte()
  if first == 48 then -- zero cannot be followed by another integer digit
    position = position + 1
    if digit(byte()) then decode_error(parser, "invalid_number") end
  elseif first and first >= 49 and first <= 57 then
    repeat position = position + 1 until not digit(byte())
  else
    decode_error(parser, "invalid_number")
  end

  if byte() == 46 then -- '.'
    position = position + 1
    if not digit(byte()) then decode_error(parser, "invalid_number") end
    repeat position = position + 1 until not digit(byte())
  end

  local exponent = byte()
  if exponent == 69 or exponent == 101 then -- 'E' or 'e'
    position = position + 1
    local sign = byte()
    if sign == 43 or sign == 45 then position = position + 1 end -- '+' or '-'
    if not digit(byte()) then decode_error(parser, "invalid_number") end
    repeat position = position + 1 until not digit(byte())
  end

  -- Copy only the numeric token, never the unparsed suffix.  Across an array
  -- of numbers this keeps both scanning and allocation linear in input size.
  local token = text:sub(start, position - 1)
  local value = tonumber(token)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    decode_error(parser, "number_out_of_range")
  end
  parser.position = position
  return value
end

local function count_node(parser)
  parser.nodes = parser.nodes + 1
  if parser.nodes > parser.max_nodes then
    decode_error(parser, "maximum_nodes_exceeded")
  end
end

local function enter(parser)
  parser.depth = parser.depth + 1
  if parser.depth > parser.max_depth then
    decode_error(parser, "maximum_depth_exceeded")
  end
end

local function leave(parser)
  parser.depth = parser.depth - 1
end

local function parse_array(parser)
  enter(parser)
  parser.position = parser.position + 1
  skip_space(parser)
  local result = {}
  if parser.text:sub(parser.position, parser.position) == "]" then
    parser.position = parser.position + 1
    leave(parser)
    return result
  end
  while true do
    result[#result + 1] = parse_value(parser)
    skip_space(parser)
    local character = parser.text:sub(parser.position, parser.position)
    if character == "]" then
      parser.position = parser.position + 1
      leave(parser)
      return result
    elseif character ~= "," then
      decode_error(parser, "expected_array_separator")
    end
    parser.position = parser.position + 1
    skip_space(parser)
  end
end

local function parse_object(parser)
  enter(parser)
  parser.position = parser.position + 1
  skip_space(parser)
  local result = {}
  if parser.text:sub(parser.position, parser.position) == "}" then
    parser.position = parser.position + 1
    leave(parser)
    return result
  end
  while true do
    local key = parse_string(parser)
    if result[key] ~= nil then
      decode_error(parser, "duplicate_object_key")
    end
    skip_space(parser)
    if parser.text:sub(parser.position, parser.position) ~= ":" then
      decode_error(parser, "expected_object_colon")
    end
    parser.position = parser.position + 1
    skip_space(parser)
    result[key] = parse_value(parser)
    skip_space(parser)
    local character = parser.text:sub(parser.position, parser.position)
    if character == "}" then
      parser.position = parser.position + 1
      leave(parser)
      return result
    elseif character ~= "," then
      decode_error(parser, "expected_object_separator")
    end
    parser.position = parser.position + 1
    skip_space(parser)
  end
end

parse_value = function(parser)
  skip_space(parser)
  local character = parser.text:sub(parser.position, parser.position)
  if character == '"' then
    count_node(parser)
    return parse_string(parser)
  elseif character == "{" then
    count_node(parser)
    return parse_object(parser)
  elseif character == "[" then
    count_node(parser)
    return parse_array(parser)
  elseif character == "-" or character:match("%d") then
    count_node(parser)
    return parse_number(parser)
  elseif parser.text:sub(parser.position, parser.position + 3) == "true" then
    count_node(parser)
    parser.position = parser.position + 4
    return true
  elseif parser.text:sub(parser.position, parser.position + 4) == "false" then
    count_node(parser)
    parser.position = parser.position + 5
    return false
  elseif parser.text:sub(parser.position, parser.position + 3) == "null" then
    count_node(parser)
    parser.position = parser.position + 4
    return JSON.null
  end
  decode_error(parser, "unexpected_token")
end

local function integer_option(options, key, default, minimum, maximum)
  local value = options[key]
  if value == nil then return default end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
      or value % 1 ~= 0 or value < minimum or value > maximum then
    return nil
  end
  return value
end

function JSON.decode(text, options)
  if type(text) ~= "string" then
    return nil, { message = "json_must_be_string", position = 1 }
  end
  if options == nil then
    options = {}
  elseif type(options) ~= "table" then
    return nil, { message = "invalid_options", position = 1 }
  end
  local max_bytes = integer_option(options, "max_bytes", DEFAULT_MAX_BYTES, 0, HARD_MAX_BYTES)
  if not max_bytes then
    return nil, { message = "invalid_max_bytes", position = 1 }
  end
  local max_depth = integer_option(options, "max_depth", DEFAULT_MAX_DEPTH, 0, HARD_MAX_DEPTH)
  if not max_depth then
    return nil, { message = "invalid_max_depth", position = 1 }
  end
  local max_nodes = integer_option(options, "max_nodes", DEFAULT_MAX_NODES, 1, HARD_MAX_NODES)
  if not max_nodes then
    return nil, { message = "invalid_max_nodes", position = 1 }
  end
  if #text > max_bytes then
    return nil, { message = "maximum_input_exceeded", position = 1 }
  end
  local parser = {
    text = text,
    length = #text,
    position = 1,
    depth = 0,
    max_depth = max_depth,
    nodes = 0,
    max_nodes = max_nodes,
  }
  local ok, value_or_error = pcall(parse_value, parser)
  if not ok then
    if type(value_or_error) == "table" then
      return nil, value_or_error
    end
    return nil, { message = tostring(value_or_error), position = parser.position }
  end
  skip_space(parser)
  if parser.position <= parser.length then
    return nil, { message = "trailing_content", position = parser.position }
  end
  return value_or_error
end

return JSON
