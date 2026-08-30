-- Optional ANSI encoder for simple native backends.  Rich backends can consume
-- the backend-neutral runs directly and never need this module.
local M = {}

local function colour_code(colour, foreground)
  if not colour then
    return foreground and "39" or "49"
  end
  local base = foreground and "38" or "48"
  if colour.mode == "rgb" then
    return string.format("%s;2;%d;%d;%d", base, colour.r, colour.g, colour.b)
  end
  local index = assert(colour.index, "indexed colour has no index")
  if index < 8 then
    return tostring((foreground and 30 or 40) + index)
  elseif index < 16 then
    return tostring((foreground and 90 or 100) + index - 8)
  end
  return string.format("%s;5;%d", base, index)
end

function M.style(style)
  style = style or {}
  local codes = {"0"}
  if style.bold then codes[#codes + 1] = "1" end
  if style.dim then codes[#codes + 1] = "2" end
  if style.italic then codes[#codes + 1] = "3" end
  if style.underline then codes[#codes + 1] = "4" end
  if style.blink then codes[#codes + 1] = "5" end
  if style.reverse then codes[#codes + 1] = "7" end
  if style.strikethrough then codes[#codes + 1] = "9" end
  codes[#codes + 1] = colour_code(style.fg, true)
  codes[#codes + 1] = colour_code(style.bg, false)
  return "\27[" .. table.concat(codes, ";") .. "m"
end

function M.encode(runs, options)
  options = options or {}
  local chunks = {}
  for _, run in ipairs(runs or {}) do
    chunks[#chunks + 1] = string.format("\27[%d;%dH", run.y, run.x)
    chunks[#chunks + 1] = M.style(run.style)
    chunks[#chunks + 1] = run.text
  end
  if #chunks > 0 and options.leave_style ~= true then
    chunks[#chunks + 1] = "\27[0m"
  end
  return table.concat(chunks)
end

return M
