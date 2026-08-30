-- Incremental terminal key/mouse/paste decoder.  The event loop may feed
-- arbitrary byte chunks; incomplete UTF-8 and escape sequences remain buffered.
local Width = require("wtop.ui.renderer.width")

local Decoder = {}
Decoder.__index = Decoder

local DEFAULT_MAX_BUFFER_BYTES = 1024 * 1024
local HARD_MAX_BUFFER_BYTES = 16 * 1024 * 1024
local DEFAULT_MAX_SEQUENCE_BYTES = 4096
local HARD_MAX_SEQUENCE_BYTES = 65536
local MAX_MOUSE_COORDINATE = 1048576

local csi_keys = {
  A = "up", B = "down", C = "right", D = "left",
  E = "begin", F = "end", H = "home", Z = "tab",
  P = "f1", Q = "f2", R = "f3", S = "f4",
}

local tilde_keys = {
  [1] = "home", [2] = "insert", [3] = "delete", [4] = "end",
  [5] = "pageup", [6] = "pagedown", [7] = "home", [8] = "end",
  [11] = "f1", [12] = "f2", [13] = "f3", [14] = "f4",
  [15] = "f5", [17] = "f6", [18] = "f7", [19] = "f8",
  [20] = "f9", [21] = "f10", [23] = "f11", [24] = "f12",
}

local ss3_keys = {A = "up", B = "down", C = "right", D = "left",
  H = "home", F = "end", P = "f1", Q = "f2", R = "f3", S = "f4"}

local function event(key, fields)
  local result = {type = "key", key = key, ctrl = false, alt = false, shift = false}
  for name, value in pairs(fields or {}) do result[name] = value end
  return result
end

local function modifier_fields(value)
  value = tonumber(value) or 1
  if value ~= value or value == math.huge or value % 1 ~= 0 or value < 1 or value > 16 then
    value = 1
  end
  local bits = math.max(0, value - 1)
  return {
    shift = bits % 2 >= 1,
    alt = math.floor(bits / 2) % 2 >= 1,
    ctrl = math.floor(bits / 4) % 2 >= 1,
    meta = math.floor(bits / 8) % 2 >= 1,
  }
end

local function split_parameters(parameters)
  local result = {}
  for value in (parameters .. ";"):gmatch("(.-);") do
    result[#result + 1] = tonumber(value) or value
  end
  return result
end

local function utf8_length(first)
  if first < 0x80 then return 1 end
  if first >= 0xC2 and first <= 0xDF then return 2 end
  if first >= 0xE0 and first <= 0xEF then return 3 end
  if first >= 0xF0 and first <= 0xF4 then return 4 end
  return 1
end

local function printable_event(text, alt)
  local byte = text:byte(1)
  local shifted = #text == 1 and byte >= 0x41 and byte <= 0x5A
  return event(text, {text = text, alt = alt == true, shift = shifted})
end

local function control_event(byte)
  if byte == 0 then return event("space", {ctrl = true}) end
  if byte == 9 then return event("tab") end
  if byte == 10 or byte == 13 then return event("enter") end
  if byte == 127 or byte == 8 then return event("backspace") end
  if byte == 32 then return event("space", {text = " "}) end
  if byte >= 1 and byte <= 26 then
    return event(string.char(96 + byte), {ctrl = true})
  end
  local names = {[28] = "\\", [29] = "]", [30] = "^", [31] = "_"}
  if names[byte] then return event(names[byte], {ctrl = true}) end
  return event("control", {code = byte})
end

local function parse_mouse(parameters, final)
  local button, x, y = parameters:match("^<(%d+);(%d+);(%d+)$")
  if not button then return nil end
  button, x, y = tonumber(button), tonumber(x), tonumber(y)
  if not button or button > 65535 or not x or x < 1 or x > MAX_MOUSE_COORDINATE
      or not y or y < 1 or y > MAX_MOUSE_COORDINATE then
    return nil
  end
  local result = {
    type = "mouse", x = x, y = y, raw_button = button,
    shift = math.floor(button / 4) % 2 == 1,
    alt = math.floor(button / 8) % 2 == 1,
    ctrl = math.floor(button / 16) % 2 == 1,
    motion = math.floor(button / 32) % 2 == 1,
  }
  if button >= 64 and button < 68 then
    result.action = "scroll"
    local directions = {[64] = "up", [65] = "down", [66] = "left", [67] = "right"}
    result.direction = directions[button]
  else
    result.action = final == "m" and "release" or (result.motion and "drag" or "press")
    result.button = button % 4 + 1
  end
  return result
end

local function decode_csi(parameters, intermediates, final, raw)
  if (final == "M" or final == "m") and parameters:sub(1, 1) == "<" then
    local mouse = parse_mouse(parameters, final)
    if mouse then mouse.raw = raw end
    return mouse or {type = "unknown", raw = raw, family = "mouse"}
  end
  if final == "I" or final == "O" then
    return {type = "focus", focused = final == "I", raw = raw}
  end
  local parsed = split_parameters(parameters)
  local modifier = #parsed >= 2 and parsed[#parsed] or 1
  local fields = modifier_fields(modifier)
  fields.raw = raw
  local key
  if final == "~" then
    key = tilde_keys[tonumber(parsed[1])]
  elseif final == "u" then
    local codepoint = tonumber(parsed[1])
    if codepoint and codepoint >= 0 and codepoint <= 0x10FFFF then
      local ok, text = pcall(utf8.char, codepoint)
      if ok then
        fields.text = text
        key = text
      end
    end
  else
    key = csi_keys[final]
  end
  if key == "tab" and final == "Z" then fields.shift = true end
  if key then return event(key, fields) end
  return {type = "unknown", raw = raw, family = "csi",
    parameters = parameters, intermediates = intermediates, final = final}
end

function Decoder.new(options)
  options = options or {}
  if type(options) ~= "table" then error("decoder options must be a table", 2) end
  local maximum = options.max_buffer_bytes or DEFAULT_MAX_BUFFER_BYTES
  if type(maximum) ~= "number" or maximum ~= maximum or maximum < 1
      or maximum > HARD_MAX_BUFFER_BYTES or maximum % 1 ~= 0 then
    error("max_buffer_bytes must be an integer in 1..16777216", 2)
  end
  local max_sequence = options.max_sequence_bytes or DEFAULT_MAX_SEQUENCE_BYTES
  if type(max_sequence) ~= "number" or max_sequence ~= max_sequence or max_sequence < 3
      or max_sequence > HARD_MAX_SEQUENCE_BYTES or max_sequence % 1 ~= 0 then
    error("max_sequence_bytes must be an integer in 3..65536", 2)
  end
  return setmetatable({
    buffer = "", options = options, max_buffer_bytes = maximum,
    max_sequence_bytes = max_sequence,
  }, Decoder)
end

function Decoder:pending()
  return #self.buffer
end

function Decoder:feed(data, final)
  data = data or ""
  if type(data) ~= "string" then error("decoder input must be a string", 2) end
  if #data > self.max_buffer_bytes - #self.buffer then
    self.buffer = ""
    return {{type = "error", reason = "input_buffer_limit"}}
  end
  self.buffer = self.buffer .. data
  local events = {}
  local function emit(value)
    if value then events[#events + 1] = value end
  end

  while #self.buffer > 0 do
    local first = self.buffer:byte(1)
    if first ~= 27 then
      if first <= 32 or first == 127 then
        emit(control_event(first))
        self.buffer = self.buffer:sub(2)
      else
        local length = utf8_length(first)
        if #self.buffer < length and not final then break end
        local text = self.buffer:sub(1, math.min(length, #self.buffer))
        local cp, next_index, valid, reason = Width.decode_at(text, 1)
        if not cp and reason == "incomplete" and not final then break end
        if valid == false then text = "�"; length = 1 end
        emit(printable_event(text, false))
        self.buffer = self.buffer:sub(length + 1)
      end
    else
      if #self.buffer == 1 then
        if final then
          emit(event("escape", {raw = "\27"}))
          self.buffer = ""
        end
        break
      end

      if self.buffer:sub(1, 6) == "\27[200~" then
        local finish = self.buffer:find("\27[201~", 7, true)
        if not finish then
          if final then
            emit({type = "paste", text = self.buffer:sub(7), incomplete = true})
            self.buffer = ""
          end
          break
        end
        emit({type = "paste", text = self.buffer:sub(7, finish - 1)})
        self.buffer = self.buffer:sub(finish + 6)
      elseif self.buffer:sub(1, 2) == "\27[" then
        local possible_end = self.buffer:find("[@-~]", 3)
        if not possible_end and #self.buffer > self.max_sequence_bytes then
          emit({type = "error", reason = "input_sequence_limit"})
          self.buffer = self.buffer:sub(self.max_sequence_bytes + 1)
          goto continue
        elseif possible_end and possible_end > self.max_sequence_bytes then
          emit({type = "error", reason = "input_sequence_limit"})
          self.buffer = self.buffer:sub(possible_end + 1)
          goto continue
        end
        local parameters, intermediates, ending, after =
          self.buffer:match("^\27%[([0-9:;<=>?]*)([ -/]*)([@-~])()")
        if not ending then
          if final then
            emit(event("escape", {raw = "\27"}))
            self.buffer = self.buffer:sub(2)
          end
          break
        end
        local raw = self.buffer:sub(1, after - 1)
        emit(decode_csi(parameters, intermediates, ending, raw))
        self.buffer = self.buffer:sub(after)
      elseif self.buffer:sub(1, 2) == "\27O" then
        if #self.buffer < 3 then
          if final then
            emit(event("escape", {raw = "\27"}))
            self.buffer = self.buffer:sub(2)
          end
          break
        end
        local final_byte = self.buffer:sub(3, 3)
        local key = ss3_keys[final_byte]
        emit(key and event(key, {raw = self.buffer:sub(1, 3)})
          or {type = "unknown", raw = self.buffer:sub(1, 3), family = "ss3"})
        self.buffer = self.buffer:sub(4)
      else
        -- Alt/meta followed by one printable character.  Unknown ESC controls
        -- are split into Escape plus the following event on the next loop.
        local second = self.buffer:byte(2)
        if second >= 32 and second ~= 127 then
          local length = utf8_length(second)
          if #self.buffer < length + 1 and not final then break end
          local text = self.buffer:sub(2, math.min(#self.buffer, length + 1))
          local cp, _, valid, reason = Width.decode_at(text, 1)
          if not cp and reason == "incomplete" and not final then break end
          if valid == false then text, length = "�", 1 end
          emit(printable_event(text, true))
          self.buffer = self.buffer:sub(length + 2)
        else
          emit(event("escape", {raw = "\27"}))
          self.buffer = self.buffer:sub(2)
        end
      end
    end
    ::continue::
  end
  return events
end

function Decoder:flush()
  return self:feed("", true)
end

function Decoder.decode(data)
  local decoder = Decoder.new()
  return decoder:feed(data, true)
end

Decoder.DEFAULT_MAX_BUFFER_BYTES = DEFAULT_MAX_BUFFER_BYTES
Decoder.HARD_MAX_BUFFER_BYTES = HARD_MAX_BUFFER_BYTES
Decoder.DEFAULT_MAX_SEQUENCE_BYTES = DEFAULT_MAX_SEQUENCE_BYTES
Decoder.HARD_MAX_SEQUENCE_BYTES = HARD_MAX_SEQUENCE_BYTES

return Decoder
