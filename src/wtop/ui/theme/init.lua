-- Semantic Waterline themes with terminal colour-depth degradation.
local Theme = {}
Theme.__index = Theme

-- Lua's official logo defines its planet colour as RGB (0, 0, 0.5), or
-- #000080. The default palette anchors its background to that exact blue and
-- lifts interactive accents enough to remain readable against it.
local LUA_BLUE = "#000080"
local DEFAULT_NAME = "lua-blue"

local palettes = {
  ["lua-blue"] = {
    ["surface.base"] = LUA_BLUE,
    ["surface.raised"] = "#070743",
    ["surface.focus"] = "#121B62",
    ["surface.header"] = "#0B1252",
    ["surface.row_alt"] = "#090948",
    ["surface.selected"] = "#173C99",
    ["text.primary"] = "#F3F6FF",
    ["text.muted"] = "#ABB7D8",
    ["text.inverse"] = "#020420",
    ["accent.primary"] = "#80AFFF",
    ["metric.good"] = "#4CD8B1",
    ["metric.warn"] = "#FFD166",
    ["metric.critical"] = "#FF6B88",
    ["chart.secondary"] = "#C39BFF",
    ["border.subtle"] = "#354C9C",
  },
  ["water-dark"] = {
    ["surface.base"] = "#080C12",
    ["surface.raised"] = "#0E151F",
    ["surface.focus"] = "#142537",
    ["surface.header"] = "#121D29",
    ["surface.row_alt"] = "#101923",
    ["surface.selected"] = "#193149",
    ["text.primary"] = "#D6E2EE",
    ["text.muted"] = "#75879A",
    ["text.inverse"] = "#071018",
    ["accent.primary"] = "#57C7FF",
    ["metric.good"] = "#45D6B3",
    ["metric.warn"] = "#F6C177",
    ["metric.critical"] = "#FF7A90",
    ["chart.secondary"] = "#B6A0FF",
    ["border.subtle"] = "#243345",
  },
  ["water-light"] = {
    ["surface.base"] = "#F5FAFD",
    ["surface.raised"] = "#EAF2F7",
    ["surface.focus"] = "#D8ECF8",
    ["surface.header"] = "#DFECF3",
    ["surface.row_alt"] = "#EEF5F8",
    ["surface.selected"] = "#C9E7F7",
    ["text.primary"] = "#152532",
    ["text.muted"] = "#526B7C",
    ["text.inverse"] = "#F8FCFF",
    ["accent.primary"] = "#037FAD",
    ["metric.good"] = "#087F5B",
    ["metric.warn"] = "#A65D00",
    ["metric.critical"] = "#C42F4D",
    ["chart.secondary"] = "#6D4CC7",
    ["border.subtle"] = "#B6CBD7",
  },
  ["high-contrast"] = {
    ["surface.base"] = "#000000",
    ["surface.raised"] = "#101010",
    ["surface.focus"] = "#003B57",
    ["surface.header"] = "#202020",
    ["surface.row_alt"] = "#181818",
    ["surface.selected"] = "#005078",
    ["text.primary"] = "#FFFFFF",
    ["text.muted"] = "#C7C7C7",
    ["text.inverse"] = "#000000",
    ["accent.primary"] = "#00D7FF",
    ["metric.good"] = "#00FF87",
    ["metric.warn"] = "#FFFF00",
    ["metric.critical"] = "#FF5F87",
    ["chart.secondary"] = "#D7AFFF",
    ["border.subtle"] = "#A8A8A8",
  },
  -- Okabe-Ito inspired metric colours.  Status always has a text/symbol cue,
  -- so this palette remains useful for several forms of colour blindness.
  ["colorblind"] = {
    ["surface.base"] = "#101417",
    ["surface.raised"] = "#182126",
    ["surface.focus"] = "#263842",
    ["surface.header"] = "#202D33",
    ["surface.row_alt"] = "#1B262B",
    ["surface.selected"] = "#304955",
    ["text.primary"] = "#F0F3F5",
    ["text.muted"] = "#9DAAB0",
    ["text.inverse"] = "#071014",
    ["accent.primary"] = "#56B4E9",
    ["metric.good"] = "#009E73",
    ["metric.warn"] = "#E69F00",
    ["metric.critical"] = "#D55E00",
    ["chart.secondary"] = "#CC79A7",
    ["border.subtle"] = "#3C4B52",
  },
}

local aliases = {
  ["background"] = "surface.base",
  ["panel"] = "surface.raised",
  ["focus"] = "accent.primary",
  ["normal"] = "text.primary",
  ["muted"] = "text.muted",
  ["good"] = "metric.good",
  ["warn"] = "metric.warn",
  ["critical"] = "metric.critical",
}

local ansi16 = {
  {0, 0, 0}, {205, 49, 49}, {13, 188, 121}, {229, 229, 16},
  {36, 114, 200}, {188, 63, 188}, {17, 168, 205}, {229, 229, 229},
  {102, 102, 102}, {241, 76, 76}, {35, 209, 139}, {245, 245, 67},
  {59, 142, 234}, {214, 112, 214}, {41, 184, 219}, {255, 255, 255},
}

local function parse_hex(value)
  if type(value) == "table" then
    local r, g, b = value[1] or value.r, value[2] or value.g, value[3] or value.b
    for _, channel in ipairs({r, g, b}) do
      if type(channel) ~= "number" or channel ~= channel or channel == math.huge
          or channel == -math.huge or channel % 1 ~= 0 or channel < 0 or channel > 255 then
        error("theme RGB channels must be integers in 0..255", 3)
      end
    end
    return r, g, b
  end
  if type(value) ~= "string" or not value:match("^#%x%x%x%x%x%x$") then
    error("invalid theme colour: " .. tostring(value), 3)
  end
  return tonumber(value:sub(2, 3), 16), tonumber(value:sub(4, 5), 16),
    tonumber(value:sub(6, 7), 16)
end

local function distance(r1, g1, b1, r2, g2, b2)
  -- Perceptual weighting is intentionally simple and deterministic.
  local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
  return 2 * dr * dr + 4 * dg * dg + 3 * db * db
end

local function nearest16(r, g, b)
  local best, best_distance = 0, math.huge
  for index, colour in ipairs(ansi16) do
    local current = distance(r, g, b, colour[1], colour[2], colour[3])
    if current < best_distance then
      best, best_distance = index - 1, current
    end
  end
  return best
end

local function cube_value(index)
  if index == 0 then
    return 0
  end
  return 55 + index * 40
end

local function nearest256(r, g, b)
  local best, best_distance = nearest16(r, g, b), math.huge
  local base = ansi16[best + 1]
  best_distance = distance(r, g, b, base[1], base[2], base[3])

  for red = 0, 5 do
    for green = 0, 5 do
      for blue = 0, 5 do
        local current = distance(r, g, b, cube_value(red), cube_value(green), cube_value(blue))
        if current < best_distance then
          best = 16 + 36 * red + 6 * green + blue
          best_distance = current
        end
      end
    end
  end
  for gray = 0, 23 do
    local value = 8 + gray * 10
    local current = distance(r, g, b, value, value, value)
    if current < best_distance then
      best, best_distance = 232 + gray, current
    end
  end
  return best
end

local function colour_mode(capabilities)
  capabilities = capabilities or {}
  if type(capabilities) ~= "table" then
    error("theme capabilities must be a table", 3)
  end
  if capabilities.no_color or capabilities.color == false
      or capabilities.color_depth == "mono" or capabilities.colors == 0 then
    return "mono"
  end
  local depth = capabilities.color_depth or capabilities.colour_depth
  if capabilities.truecolor or depth == "truecolor" or depth == 24
      or (type(depth) == "number" and depth >= 16777216) then
    return "truecolor"
  end
  if depth == 256 or depth == "256" or (capabilities.colors or 0) >= 256 then
    return "256"
  end
  return "16"
end

local function resolve_colour(value, mode)
  if value == nil or mode == "mono" then
    return nil
  end
  local r, g, b = parse_hex(value)
  if mode == "truecolor" then
    return {mode = "rgb", r = r, g = g, b = b}
  elseif mode == "256" then
    return {mode = "indexed", index = nearest256(r, g, b)}
  end
  return {mode = "indexed", index = nearest16(r, g, b)}
end

local function shallow_copy(source)
  if source ~= nil and type(source) ~= "table" then
    error("theme mapping must be a table", 3)
  end
  local result = {}
  for key, value in pairs(source or {}) do
    result[key] = value
  end
  return result
end

function Theme.new(name_or_options, capabilities)
  local options
  if type(name_or_options) == "table" then
    options = shallow_copy(name_or_options)
  else
    if name_or_options ~= nil and type(name_or_options) ~= "string" then
      error("theme name must be a string", 2)
    end
    options = {name = name_or_options, capabilities = capabilities}
  end
  local name = options.name or DEFAULT_NAME
  local palette = options.palette or palettes[name]
  if not palette then
    error("unknown theme: " .. tostring(name), 2)
  end
  local merged = shallow_copy(palette)
  if options.overrides ~= nil and type(options.overrides) ~= "table" then
    error("theme overrides must be a table", 2)
  end
  for token, value in pairs(options.overrides or {}) do
    if not palette[token] and not aliases[token] then
      error("unknown semantic theme token: " .. tostring(token), 2)
    end
    merged[aliases[token] or token] = value
  end
  local caps = options.capabilities or capabilities or {}
  if type(caps) ~= "table" then error("theme capabilities must be a table", 2) end
  for token, value in pairs(merged) do
    if type(token) ~= "string" then error("theme tokens must be strings", 2) end
    parse_hex(value)
  end
  return setmetatable({
    name = name,
    palette = merged,
    capabilities = caps,
    mode = colour_mode(caps),
    _cache = {},
  }, Theme)
end

function Theme:token(name)
  name = aliases[name] or name
  local value = self.palette[name]
  if value == nil then
    error("unknown semantic theme token: " .. tostring(name), 2)
  end
  return value
end

function Theme:colour(name)
  name = aliases[name] or name
  local cached = self._cache[name]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end
  local resolved = resolve_colour(self:token(name), self.mode)
  self._cache[name] = resolved or false
  return resolved
end

Theme.color = Theme.colour

-- Accept either style(fg, bg, attrs) or style{fg=..., bg=..., bold=...}.
function Theme:style(foreground, background, attributes)
  local specification
  if type(foreground) == "table" then
    specification = foreground
  else
    if attributes ~= nil and type(attributes) ~= "table" then
      error("theme style attributes must be a table", 2)
    end
    specification = shallow_copy(attributes)
    specification.fg = foreground
    specification.bg = background
  end
  local result = {
    fg = specification.fg and self:colour(specification.fg) or nil,
    bg = specification.bg and self:colour(specification.bg) or nil,
  }
  for _, attribute in ipairs({"bold", "dim", "italic", "underline", "blink", "reverse", "strikethrough"}) do
    if specification[attribute] then
      result[attribute] = true
    end
  end
  -- Semantic names are retained for diagnostics and backend-specific remaps.
  result.fg_token = specification.fg
  result.bg_token = specification.bg
  return result
end

function Theme:with_capabilities(capabilities)
  return Theme.new({
    name = self.name,
    palette = self.palette,
    capabilities = capabilities,
  })
end

function Theme.available()
  local result = {}
  for name in pairs(palettes) do
    result[#result + 1] = name
  end
  table.sort(result)
  return result
end

Theme.palettes = palettes
Theme.DEFAULT = DEFAULT_NAME
Theme.LUA_BLUE = LUA_BLUE
Theme.nearest16 = nearest16
Theme.nearest256 = nearest256
Theme.colour_mode = colour_mode

return Theme
