package.path = "src/?.lua;src/?/init.lua;" .. package.path

local Backend = require("wtop.ui.backend")
local Theme = require("wtop.ui.theme")
local Grid = require("wtop.ui.renderer.grid")
local Diff = require("wtop.ui.renderer.diff")
local Renderer = require("wtop.ui.renderer")
local Width = require("wtop.ui.renderer.width")
local Ansi = require("wtop.ui.renderer.ansi")
local Sparkline = require("wtop.ui.widgets.sparkline")
local Table = require("wtop.ui.widgets.table")
local Overview = require("wtop.ui.views.overview")
local Terminal = require("wtop.terminal")

local function equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
  end
end

local function rgb(hex)
  return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16),
    tonumber(hex:sub(6, 7), 16)
end

local function linear_channel(value)
  value = value / 255
  if value <= 0.04045 then return value / 12.92 end
  return ((value + 0.055) / 1.055) ^ 2.4
end

local function luminance(hex)
  local red, green, blue = rgb(hex)
  return 0.2126 * linear_channel(red) + 0.7152 * linear_channel(green)
    + 0.0722 * linear_channel(blue)
end

local function contrast(left, right)
  local brighter, darker = luminance(left), luminance(right)
  if brighter < darker then brighter, darker = darker, brighter end
  return (brighter + 0.05) / (darker + 0.05)
end

-- Unicode measurement keeps terminal grapheme groups intact.
equal(Width.display_width("abc"), 3)
equal(Width.display_width("中文"), 4)
equal(Width.display_width("e\204\129"), 1) -- e + COMBINING ACUTE ACCENT
equal(Width.display_width("👩‍💻"), 2)
equal(Width.display_width("🇨🇳"), 2)
equal(Width.display_width("❤️"), 2)
equal(Width.display_width("1️⃣"), 2)
equal(Width.display_width("a\27b"), 3,
  "control replacement measurement must match rendered cell width")
equal(Width.display_width("A", {width_fn = function(cp)
  if cp == 65 then return 2 end
end}), 2, "injected width function")
equal(Width.display_width("A", {width_fn = function() error("broken width provider") end}), 1,
  "a failing optional width provider must fall back safely")
local clipped = Width.truncate("ab中文cd", 5)
equal(Width.display_width(clipped), 5, "truncate must not split a CJK cell")

-- Wide-cell leaders and continuations remain valid under overlap writes.
local grid = Grid.new(8, 2)
assert(not pcall(Grid.new, math.huge, 1))
assert(not pcall(Grid.new, 1001, 1000), "oversized grids must be rejected before allocation")
assert(not pcall(Grid.new, 8, 2, {width_fn = "invalid"}))
grid:write(1, 1, "A中文e\204\129")
grid:assert_valid()
equal(grid:get(2, 1).width, 2)
assert(grid:get(3, 1).continuation)
grid:set(3, 1, "x") -- overwrites the second cell of 中 and clears its leader
grid:assert_valid()
equal(grid:get(2, 1).char, " ")
equal(grid:get(3, 1).char, "x")
local safe_grid = Grid.new(20, 1)
safe_grid:write(1, 1, "name\27[31m")
assert(not safe_grid:row_text(1):find("\27", 1, true), "terminal controls must be sanitised")
local invalid_grid = Grid.new(4, 1)
invalid_grid:write(1, 1, "\255")
assert(invalid_grid:row_text(1):find("�", 1, true), "invalid UTF-8 must be replaced")
local ascii_grid = Grid.new(32, 1, {unicode = false})
ascii_grid:write(1, 1, "— · 中文 ↑ …")
assert(not ascii_grid:row_text(1):find("[\128-\255]"),
  "non-Unicode terminals must receive ASCII-only cells")

-- Narrow tables reserve every visible column at its minimum before sharing
-- spare width; a flexible name field must not consume the CPU column.
local table_grid = Grid.new(34, 3)
Table.render(table_grid, {x = 1, y = 1, width = 34, height = 3}, {
  columns = {
    {key = "pid", label = "PID", width = 8, min_width = 5},
    {key = "name", label = "Process", width = 36, min_width = 12},
    {key = "cpu", label = "CPU", width = 10, min_width = 8, align = "right"},
    {key = "memory", label = "Memory", width = 12, min_width = 9, align = "right"},
  },
  rows = {{pid = 7, name = "worker-with-a-long-name", cpu = "42%", memory = "1 GiB"}},
}, {}, "spark")
assert(table_grid:row_text(1):find("CPU", 1, true),
  "minimum-first allocation must preserve later key columns")

-- Semantic theme values degrade without changing Widget-level token usage.
local default_theme = Theme.new()
equal(Theme.DEFAULT, "lua-blue")
equal(default_theme.name, Theme.DEFAULT)
equal(Theme.LUA_BLUE, "#000080")
equal(default_theme:token("surface.base"), Theme.LUA_BLUE)
assert(contrast(default_theme:token("text.primary"), Theme.LUA_BLUE) >= 7,
  "primary text must retain enhanced contrast on Lua blue")
assert(contrast(default_theme:token("text.muted"), Theme.LUA_BLUE) >= 4.5,
  "muted text must retain normal-text contrast on Lua blue")
assert(contrast(default_theme:token("accent.primary"), Theme.LUA_BLUE) >= 4.5,
  "the lifted Lua-blue accent must remain legible on the branded background")

local lua_truecolour = Theme.new({capabilities = {truecolor = true}})
local lua_accent = lua_truecolour:colour("accent.primary")
equal(lua_accent.mode, "rgb")
equal(lua_accent.r, 128)
equal(lua_accent.g, 175)
equal(lua_accent.b, 255)
local lua_colour256 = Theme.new({capabilities = {colors = 256}})
equal(lua_colour256:colour("surface.base").index, 18)
equal(lua_colour256:colour("surface.selected").index, 24)
equal(lua_colour256:colour("accent.primary").index, 111)
local lua_colour16 = Theme.new({capabilities = {colors = 16}})
equal(lua_colour16:colour("surface.base").index, 0)
equal(lua_colour16:colour("surface.selected").index, 4)
equal(lua_colour16:colour("accent.primary").index, 12)
equal(lua_colour16:colour("text.primary").index, 15)

local truecolour = Theme.new("water-dark", {truecolor = true})
equal(truecolour.mode, "truecolor")
equal(truecolour:colour("accent.primary").mode, "rgb")
local colour256 = Theme.new("water-dark", {colors = 256})
equal(colour256.mode, "256")
assert(colour256:colour("accent.primary").index >= 0
  and colour256:colour("accent.primary").index <= 255)
local colour16 = Theme.new("water-dark", {colors = 16})
equal(colour16.mode, "16")
assert(colour16:colour("accent.primary").index < 16)
local mono = Theme.new({capabilities = {no_color = true}})
equal(mono.mode, "mono")
assert(mono:style("metric.critical", nil, {bold = true}).fg == nil)
assert(mono:style("metric.critical", nil, {bold = true}).bold)
for _, name in ipairs({"lua-blue", "water-dark", "water-light", "high-contrast", "colorblind"}) do
  assert(Theme.new(name, {colors = 16}):colour("text.primary"))
end
assert(not pcall(Theme.new, {name = "water-dark", overrides = {["accent.primary"] = {300, 0, 0}}}),
  "invalid theme channels must be rejected")
assert(not pcall(Theme.new, {name = "water-dark", overrides = "invalid"}),
  "invalid theme override maps must be rejected")

-- Diffing an equal clone produces no output; one changed cell produces one run.
local old = grid:clone()
local unchanged, unchanged_meta = Diff.runs(old, grid)
equal(#unchanged, 0)
equal(unchanged_meta.changed_cells, 0)
grid:set(8, 2, "!")
local changed, changed_meta = Diff.runs(old, grid)
equal(#changed, 1)
equal(changed[1].x, 8)
equal(changed[1].y, 2)
equal(changed[1].text, "!")
equal(changed_meta.changed_cells, 1)

-- The documented dot-call backend contract integrates with the stateful diff
-- renderer and suppresses backend.present on an unchanged frame.
local calls = {start = 0, present = 0, stop = 0}
local last_runs
local native = {
  start = function(options) calls.start = calls.start + 1; assert(options.raw ~= false) end,
  size = function() return 80, 24 end,
  poll = function(timeout_ms) return {timeout = timeout_ms} end,
  present = function(runs) calls.present = calls.present + 1; last_runs = runs; return true end,
  capabilities = function() return {colors = 256, unicode = true} end,
  stop = function() calls.stop = calls.stop + 1; return true end,
}
local backend = Backend.new(native)
assert(backend.start({raw = true}))
local columns, rows = backend.size()
equal(columns, 80); equal(rows, 24)
equal(backend.capabilities().color_depth, 256)
local renderer = Renderer.new(backend)
local frame = Grid.new(5, 2)
frame:write(1, 1, "wtop")
local first_runs = renderer:present(frame)
assert(#first_runs > 0 and #last_runs > 0)
equal(calls.present, 1)
local second_runs = renderer:present(frame)
equal(#second_runs, 0)
equal(calls.present, 1, "unchanged frame must not reach backend")
frame:set(5, 2, "x")
local third_runs = renderer:present(frame)
equal(#third_runs, 1)
equal(calls.present, 2)
assert(backend.stop())
equal(calls.start, 1); equal(calls.stop, 1)

local failed_backend = Backend.new({
  start = function() return nil, "start failed" end,
  size = function() return math.huge, 24 end,
  poll = function() end,
  present = function() end,
  capabilities = function() return {} end,
  stop = function() return nil, "stop failed" end,
})
local failed_start, failed_start_reason = failed_backend.start()
assert(failed_start == nil and failed_start_reason == "start failed")
assert(failed_backend.size() == nil)

-- A failed backend write must not advance the renderer's last-known screen.
-- Otherwise a partial terminal frame becomes permanent on the next diff.
local fail_present = true
local retry_metadata
local retry_renderer = Renderer.new({present = function(_, metadata)
  if fail_present then return nil, "write: resource temporarily unavailable" end
  retry_metadata = metadata
  return true
end})
local retry_grid = Grid.new(30, 4)
retry_grid:write(1, 1, "complete frame")
local failed_runs, failed_reason = retry_renderer:present(retry_grid)
assert(failed_runs == nil and failed_reason:find("temporarily unavailable", 1, true))
equal(retry_renderer:stats().frames, 0)
fail_present = false
local retried_runs = assert(retry_renderer:present(retry_grid))
assert(#retried_runs > 0 and retry_metadata.full == true,
  "retry after a failed write must resend the complete frame")

-- The application-owned terminal adapter uses the same point-call contract.
-- This integration also proves that backend-neutral runs become terminal ANSI.
local terminal_writes = {}
local terminal = Terminal.new({
  terminal_start = function() return true end,
  terminal_stop = function() return true end,
  terminal_size = function() return 20, 4 end,
  poll = function() return nil end,
  write = function(value) terminal_writes[#terminal_writes + 1] = value; return true end,
})
assert(terminal.start({mouse = false, color = false}))
local terminal_renderer = Renderer.new(terminal)
local terminal_grid = Grid.new(20, 4)
terminal_grid:write(1, 1, "wtop")
terminal_renderer:present(terminal_grid)
equal(#terminal_writes, 2)
assert(terminal_writes[2]:find("wtop", 1, true))
assert(terminal_writes[2]:find("\27[2J\27[H", 1, true),
  "a full frame must explicitly clear the alternate screen")
terminal_renderer:present(terminal_grid)
equal(#terminal_writes, 2, "terminal adapter must see no unchanged frame")
assert(terminal.stop())
equal(#terminal_writes, 3)

local encoded = Ansi.encode({{x = 2, y = 3, text = "x", style = colour256:style("accent.primary")}})
assert(encoded:find("\27%[3;2H") and encoded:find("x", 1, true))
equal(Width.display_width(Sparkline.render({0, 1, nil, 2}, 4)), 4)
equal(Sparkline.render({
  10, 20,
  n = 2,
  timestamps_ns = {25, 100},
  window_ns = 100,
  end_ns = 100,
}, 4, {glyphs = {"#"}, gap = ".", min = 0, max = 100}), ".#.#",
  "time-aware sparklines must preserve the fixed window and show sample density")
equal(Sparkline.render({
  10, 20, 30, 40,
  n = 4,
  timestamps_ns = {0, 25, 50, 100},
  window_ns = 100,
  end_ns = 100,
}, 4, {glyphs = {"#"}, gap = ".", min = 0, max = 100}), "####",
  "higher update rates must add points without changing the horizontal time span")
equal(Sparkline.render({
  10, 20, 30, 40,
  n = 4,
  timestamps_ns = {0, 1, 2, 4},
  window_ns = 4,
  column_ns = 1,
  end_ns = 4,
}, 6, {glyphs = {"#"}, gap = ".", min = 0, max = 100}), "..####",
  "charts wider than retained history must pad left instead of changing seconds per column")
assert(not pcall(Sparkline.render, {}, math.huge), "sparkline width must be bounded")
assert(not pcall(Sparkline.render, {[1000001] = 1}, 1),
  "sparkline indexes must be bounded")

-- Rebuilding an equivalent page creates fresh style/cell tables, but semantic
-- equality still yields zero terminal output. A metric update stays local.
local page = Overview.new()
local page_calls = 0
local page_renderer = Renderer.new({present = function() page_calls = page_calls + 1 end})
local page_state = {widgets = {cpu = {value = 10, unit = "%"}}}
local page_frame_a = page:render(80, 50, page_state)
page_renderer:present(page_frame_a)
local page_frame_b = page:render(80, 50, page_state)
local equal_page_runs = page_renderer:present(page_frame_b)
equal(#equal_page_runs, 0)
equal(page_calls, 1)
local page_frame_c = page:render(80, 50, {widgets = {cpu = {value = 11, unit = "%"}}})
local local_runs, local_metadata = page_renderer:present(page_frame_c)
assert(#local_runs > 0)
assert(local_metadata.changed_cells < page_frame_c.width * page_frame_c.height)
equal(page_calls, 2)

print("test_ui_renderer: ok")
