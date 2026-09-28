-- A pseudolocale stress-tests layout code with text that is both longer and
-- full of wide/combining characters, the way untested translations arrive.
-- Every page must still render a grid exactly the terminal rectangle and keep
-- chrome rows intact; nothing may error out mid-render.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local English = require("wtop.generated.locales.en-US")
local Overview = require("wtop.ui.views.overview")
local Table = require("wtop.ui.widgets.table")
local Width = require("wtop.ui.renderer.width")

local accents = {
  a = "á", b = "ḅ", c = "ç", d = "ḍ", e = "é", f = "ḟ", g = "ĝ", h = "ḥ",
  i = "í", j = "ĵ", k = "ḳ", l = "ḷ", m = "ṁ", n = "ñ", o = "ó", p = "ṗ",
  q = "ẏ", r = "ṛ", s = "ṡ", t = "ṭ", u = "ú", v = "ṽ", w = "ẇ", x = "ẋ",
  y = "ý", z = "ẑ",
}

-- Expand to roughly 130% while preserving placeholders such as {count} so
-- parameter substitution still produces a displayable string.
local function pseudo(text)
  if type(text) ~= "string" then return tostring(text) end
  local expanded = {}
  local index = 1
  while index <= #text do
    local placeholder = text:match("{[a-zA-Z0-9_]+}", index)
    if placeholder and #placeholder > 0 and text:sub(index, index) == "{" then
      expanded[#expanded + 1] = placeholder
      index = index + #placeholder
    else
      local character = text:sub(index, index)
      expanded[#expanded + 1] = accents[character] or character
      index = index + 1
    end
  end
  local body = table.concat(expanded)
  if #body < 96 then
    body = body .. (" Żž"):rep(math.ceil(#body * 0.3 / 3))
  end
  return body
end

local function substitute(pattern, parameters)
  return (pattern:gsub("{([a-zA-Z0-9_]+)}", function(name)
    local value = parameters and parameters[name]
    if value == nil then return "{" .. name .. "}" end
    return tostring(value)
  end))
end

local pseudo_i18n = setmetatable({}, { __index = function(_, key)
  error("pseudolocale facade must not be used for " .. tostring(key))
end })

local messages = English.messages
pseudo_i18n.t = function(_, id, parameters)
  local pattern = messages[id]
  if type(pattern) ~= "string" then return id end
  return pseudo(substitute(pattern, parameters))
end

-- The longest shipped messages must survive the transform without tripping
-- any width function: display width stays finite and at least the source.
local longest = { id = "", source = "" }
for id, text in pairs(messages) do
  if #text > #longest.source then
    longest.id, longest.source = id, text
  end
end
local stretched = assert(pseudo_i18n:t(longest.id, {}))
assert(Width.display_width(stretched) >= Width.display_width(longest.source),
  "pseudolocale expansion must not shorten a message")

-- Full-page rendering at the four required aspect ratios. Grids must stay
-- exactly the terminal rectangle with every chrome row intact.
local page = Overview.new({tabs = {
  {id = "overview", label = pseudo_i18n:t("tabs.overview")},
  {id = "processes", label = pseudo_i18n:t("tabs.processes")},
  {id = "compute", label = pseudo_i18n:t("tabs.compute")},
  {id = "storage", label = pseudo_i18n:t("tabs.storage")},
}})
local cases = { {60, 20}, {80, 50}, {160, 24}, {180, 45} }
for _, case in ipairs(cases) do
  local columns, rows = case[1], case[2]
  local grid, metadata = page:render(columns, rows, {
    active_tab = "overview",
    paused = false,
    frequency_label = pseudo_i18n:t("sampling.frequency.medium"),
    capabilities = {truecolor = true, unicode = true},
    i18n = pseudo_i18n,
    widgets = {
      cpu = {label = pseudo_i18n:t("metrics.cpu"), value = 31.5, unit = "%",
        history = {1, 4, 2, 8}},
      memory = {label = pseudo_i18n:t("metrics.memory"), value = 42, unit = "%",
        history = {2, 3, 4}},
      pressure = {label = pseudo_i18n:t("metrics.pressure"), value = 0.4,
        unit = "%", history = {0, nil, 0.4}},
    },
    status = {data_age = pseudo_i18n:t("status.fresh")},
  })
  assert(grid and grid.width == columns and grid.height == rows,
    "pseudolocale render must fill the requested rectangle")
  assert(grid:assert_valid(),
    ("pseudolocale grid must stay valid at %dx%d"):format(columns, rows))
  assert(Width.display_width(grid:row_text(1)) == columns,
    ("pseudolocale tab bar must be exactly %d cells"):format(columns))
  assert(Width.display_width(grid:row_text(rows)) == columns,
    ("pseudolocale status bar must be exactly %d cells"):format(columns))
  assert(metadata.mode and metadata.mode ~= "",
    "responsive mode must still be selected under pseudolocale")
end

-- Data tables truncate cell content to their column rectangle; wide pseudo
-- labels must not widen columns or push neighbours out of the grid.
local Grid = require("wtop.ui.renderer.grid")
local table_grid = Grid.new(34, 5)
local table_meta = Table.render(table_grid, { x = 1, y = 1, width = 34, height = 5 }, {
  columns = {
    {key = "name", label = pseudo_i18n:t("process.sort.name"), width = 12,
      min_width = 6, priority = 60},
    {key = "user", label = pseudo_i18n:t("metrics.user"), width = 10,
      min_width = 6, priority = 50},
    {key = "state", label = pseudo_i18n:t("metrics.state"), width = 8,
      min_width = 4, priority = 40,
      format = function(value)
        return pseudo_i18n:t("status." .. tostring(value))
      end},
  },
  rows = {
    {name = pseudo_i18n:t("app.name"), user = "Administrator", state = "partial"},
    {name = string.rep("Ż", 40), user = pseudo_i18n:t("metrics.memory"),
      state = "fresh"},
  },
}, {unicode = true}, "full")
assert(table_grid:assert_valid(), "table with pseudolocale cells stays valid")
assert(Width.display_width(table_grid:row_text(1)) <= 34,
  "table header must not exceed its rectangle under pseudolocale")
assert((table_meta.columns_visible or 0) >= 1,
  "at least one pseudolocale column stays visible")

print("ok: pseudolocale layout (longest message " .. longest.id .. ")")
