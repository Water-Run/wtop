local Width = require("wtop.ui.renderer.width")

local Grid = {}
Grid.__index = Grid

local MAX_DIMENSION = 10000
local MAX_CELLS = 1000000

local ascii_glyphs = {
  ["—"] = "-", ["–"] = "-", ["−"] = "-", ["·"] = ".", ["…"] = ".",
  ["×"] = "x", ["↑"] = "^", ["↓"] = "v", ["←"] = "<", ["→"] = ">",
  ["‹"] = "<", ["›"] = ">", ["▸"] = ">", ["▾"] = "v", ["●"] = "*",
  ["°"] = "o", ["Ⅰ"] = "I", ["Ⅱ"] = "II",
  ["▁"] = ".", ["▂"] = ":", ["▃"] = "-", ["▄"] = "=",
  ["▅"] = "+", ["▆"] = "*", ["▇"] = "#", ["█"] = "#",
}

local function ascii_grapheme(grapheme, width)
  if not grapheme:find("[\128-\255]") then return grapheme, width end
  local replacement = ascii_glyphs[grapheme]
  if replacement then return replacement, #replacement end
  -- Preserve an ASCII base letter when the cluster only adds a combining
  -- mark; other unsupported glyphs become a terminal-safe placeholder.
  local first = grapheme:byte(1)
  if first and first < 0x80 then return grapheme:sub(1, 1), 1 end
  return "?", 1
end

local function blank(style)
  return {char = " ", width = 1, style = style}
end

local function copy_cell(cell)
  return {
    char = cell.char,
    width = cell.width,
    style = cell.style,
    continuation = cell.continuation,
    lead_x = cell.lead_x,
  }
end

local function valid_dimension(value, name)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge
      or value < 1 or value > MAX_DIMENSION or value ~= math.floor(value) then
    error(name .. " must be a positive integer", 3)
  end
  return value
end

function Grid.new(width, height, options)
  if options ~= nil and type(options) ~= "table" then
    error("grid options must be a table", 2)
  end
  options = options or {}
  if options.width_fn ~= nil and type(options.width_fn) ~= "function" then
    error("grid width_fn must be a function", 2)
  end
  for _, name in ipairs({"ambiguous_is_wide", "unicode"}) do
    if options[name] ~= nil and type(options[name]) ~= "boolean" then
      error("grid " .. name .. " must be a boolean", 2)
    end
  end
  if options.default_style ~= nil and type(options.default_style) ~= "table" then
    error("grid default_style must be a table", 2)
  end
  width = valid_dimension(width, "grid width")
  height = valid_dimension(height, "grid height")
  if width > MAX_CELLS // height then
    error("grid exceeds maximum cell count", 2)
  end
  local self = setmetatable({
    width = width,
    height = height,
    width_options = {
      width_fn = options.width_fn,
      ambiguous_is_wide = options.ambiguous_is_wide,
      unicode = options.unicode,
    },
    default_style = options.default_style,
    cells = {},
    dirty = {},
    dirty_all = true,
  }, Grid)
  for index = 1, width * height do
    self.cells[index] = blank(options.default_style)
  end
  return self
end

function Grid:_index(x, y)
  return (y - 1) * self.width + x
end

function Grid:contains(x, y)
  return x >= 1 and x <= self.width and y >= 1 and y <= self.height
end

function Grid:get(x, y)
  if not self:contains(x, y) then
    return nil
  end
  return self.cells[self:_index(x, y)]
end

function Grid:_mark_dirty(x, y)
  local row = self.dirty[y]
  if not row then
    row = {}
    self.dirty[y] = row
  end
  row[x] = true
end

function Grid:_raw_blank(x, y, style)
  self.cells[self:_index(x, y)] = blank(style or self.default_style)
  self:_mark_dirty(x, y)
end

function Grid:_clear_occupant(x, y)
  if not self:contains(x, y) then
    return
  end
  local cell = self:get(x, y)
  local start = cell.continuation and cell.lead_x or x
  local lead = self:get(start, y)
  local span = lead and not lead.continuation and (lead.width or 1) or 1
  for current = start, math.min(self.width, start + span - 1) do
    self:_raw_blank(current, y)
  end
end

-- Place one terminal grapheme. Width zero appends to the preceding cell, which
-- is useful for a leading combining mark received in a separate write call.
function Grid:set(x, y, grapheme, style, cell_width)
  x, y = math.floor(x), math.floor(y)
  if not self:contains(x, y) then
    return false
  end
  grapheme = tostring(grapheme or " ")
  if cell_width == nil then
    cell_width = Width.display_width(grapheme, self.width_options)
  end
  cell_width = math.max(0, math.floor(cell_width))
  if cell_width == 0 then
    local previous = self:get(x - 1, y)
    if previous then
      local lead_x = previous.continuation and previous.lead_x or x - 1
      local lead = self:get(lead_x, y)
      if lead then
        lead.char = lead.char .. grapheme
        self:_mark_dirty(lead_x, y)
        return true
      end
    end
    return false
  end
  if x + cell_width - 1 > self.width then
    return false
  end

  -- Remove both an old wide glyph under the target and wide glyphs intersected
  -- by the new span before writing the new leader/continuations.
  for current = x, x + cell_width - 1 do
    self:_clear_occupant(current, y)
  end
  local lead = {char = grapheme, width = cell_width, style = style}
  self.cells[self:_index(x, y)] = lead
  self:_mark_dirty(x, y)
  for current = x + 1, x + cell_width - 1 do
    self.cells[self:_index(current, y)] = {
      char = "",
      width = 0,
      style = style,
      continuation = true,
      lead_x = x,
    }
    self:_mark_dirty(current, y)
  end
  return true
end

function Grid:write(x, y, text, style, max_width)
  x, y = math.floor(x), math.floor(y)
  text = tostring(text or "")
  local origin = x
  local limit = max_width and math.max(0, math.floor(max_width)) or math.huge
  local used = 0
  for source_grapheme, source_width in Width.graphemes(text, self.width_options) do
    local grapheme, width = source_grapheme, source_width
    local codepoint = Width.decode_at(grapheme, 1)
    if codepoint == 0x0A or codepoint == 0x0D then
      break
    end
    -- Never pass C0/C1/DEL bytes from process names or external tools through
    -- to the terminal. Tabs become one blank cell; other controls use a visible
    -- replacement marker, preventing ANSI/OSC injection through metric data.
    if codepoint and (codepoint < 0x20 or (codepoint >= 0x7F and codepoint < 0xA0)) then
      grapheme, width = codepoint == 0x09 and " " or "�", 1
    end
    if self.width_options.unicode == false then
      grapheme, width = ascii_grapheme(grapheme, width)
    end
    if width == 0 then
      self:set(x, y, grapheme, style, 0)
    elseif used + width > limit or x + width - 1 > self.width then
      break
    else
      self:set(x, y, grapheme, style, width)
      x = x + width
      used = used + width
    end
  end
  return x, x - origin
end

function Grid:write_aligned(rect, text, style, align)
  local clipped = Width.truncate(text, rect.width, self.width_options)
  local used = Width.display_width(clipped, self.width_options)
  local x = rect.x
  if align == "right" then
    x = rect.x + rect.width - used
  elseif align == "center" then
    x = rect.x + math.floor((rect.width - used) / 2)
  end
  self:write(x, rect.y, clipped, style, rect.width)
  return x, used
end

function Grid:fill(rect, character, style)
  rect = rect or {x = 1, y = 1, width = self.width, height = self.height}
  character = character or " "
  if Width.display_width(character, self.width_options) ~= 1 then
    error("fill character must occupy exactly one cell", 2)
  end
  local left = math.max(1, rect.x)
  local top = math.max(1, rect.y)
  local right = math.min(self.width, rect.x + rect.width - 1)
  local bottom = math.min(self.height, rect.y + rect.height - 1)
  for y = top, bottom do
    -- Clear only boundary intersections before the fast path. Any wide glyph
    -- wholly inside the rectangle has both its leader and continuations
    -- overwritten below; boundary glyphs may extend outside and must first be
    -- removed as a unit to preserve the grid invariant.
    self:_clear_occupant(left, y)
    if right ~= left then self:_clear_occupant(right, y) end
    for x = left, right do
      self.cells[self:_index(x, y)] = {char = character, width = 1, style = style}
      self:_mark_dirty(x, y)
    end
  end
  return self
end

function Grid:clear(style)
  self.default_style = style or self.default_style
  for y = 1, self.height do
    for x = 1, self.width do
      self.cells[self:_index(x, y)] = blank(self.default_style)
    end
  end
  self.dirty_all = true
  self.dirty = {}
  return self
end

function Grid:clone()
  local result = setmetatable({
    width = self.width,
    height = self.height,
    width_options = self.width_options,
    default_style = self.default_style,
    cells = {},
    dirty = {},
    dirty_all = false,
  }, Grid)
  for index, cell in ipairs(self.cells) do
    result.cells[index] = copy_cell(cell)
  end
  return result
end

function Grid:mark_clean()
  self.dirty_all = false
  self.dirty = {}
end

function Grid:is_dirty(x, y)
  return self.dirty_all or (self.dirty[y] and self.dirty[y][x]) or false
end

function Grid:row_text(y)
  if y < 1 or y > self.height then
    return nil
  end
  local result = {}
  for x = 1, self.width do
    local cell = self:get(x, y)
    if not cell.continuation then
      result[#result + 1] = cell.char
    end
  end
  return table.concat(result)
end

function Grid:assert_valid()
  assert(#self.cells == self.width * self.height, "invalid cell count")
  for y = 1, self.height do
    for x = 1, self.width do
      local cell = self:get(x, y)
      if cell.continuation then
        assert(cell.lead_x and cell.lead_x < x, "continuation lacks leader")
        local lead = self:get(cell.lead_x, y)
        assert(lead and not lead.continuation, "continuation points to invalid leader")
        assert(cell.lead_x + lead.width - 1 >= x, "continuation outside leader span")
      else
        assert((cell.width or 1) >= 1, "leader has invalid width")
      end
    end
  end
  return true
end

Grid.MAX_DIMENSION = MAX_DIMENSION
Grid.MAX_CELLS = MAX_CELLS

return Grid
