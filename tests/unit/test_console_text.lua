package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

-- Classic Windows consoles cannot draw Unicode line art, but a double-byte
-- code page such as 936 shows Chinese text in two cells per character. The
-- renderer asks the console, through console_cells, what it can show.
local Width = require("wtop.ui.renderer.width")
local Grid = require("wtop.ui.renderer.grid")

local function equal(actual, expected, message)
    assert(actual == expected,
        string.format("%s: expected %q, got %q", message, tostring(expected), tostring(actual)))
end

-- A stand-in for code page 936: CJK and pinyin letters are double-byte,
-- Cyrillic is single-byte, and emoji cannot be encoded.
local function cp936(codepoint)
    if codepoint < 0x80 then return 1 end
    if codepoint >= 0x4E00 and codepoint <= 0x9FFF then return 2 end
    if codepoint == 0x00E9 then return 2 end
    if codepoint >= 0x0410 and codepoint <= 0x044F then return 1 end
    return 0
end

local ascii = { unicode = false }
local console = { unicode = false, console_cells = cp936 }

-- What a grid actually draws for a line of text.
local function drawn(text, options, columns)
    local grid = Grid.new(columns or 24, 1, options)
    grid:write(1, 1, text)
    local out = {}
    for x = 1, grid.width do
        local cell = grid:get(x, 1)
        if not cell.continuation then out[#out + 1] = cell.char end
    end
    return (table.concat(out):gsub("%s+$", ""))
end

-- Without console information everything non-ASCII collapses, and is now
-- measured at the width it is drawn with.
equal(Width.display_width("本地连接", ascii), 4, "unknown glyphs are one '?' each")
equal(drawn("本地连接", ascii), "????", "substituted text")

-- With a double-byte console the text is kept and measured in its cells.
equal(Width.display_width("本地连接", console), 8, "CJK takes two console cells")
equal(drawn("本地连接", console), "本地连接", "CJK is preserved")
equal(Width.display_width("café", console), 5, "a double-byte accented letter")
equal(Width.display_width("Сеть", console), 4, "single-byte Cyrillic")
equal(drawn("ok 😀", console), "ok ?", "unencodable glyphs still become '?'")

-- Line art always uses the ASCII stand-in, even where the code page could
-- encode it, because such consoles draw it at an unpredictable width.
equal(drawn("● ↓ 1 KiB/s", console), "* v 1 KiB/s", "line art falls back")
equal(Width.display_width("—", console), 1, "an em dash is one ASCII cell")

-- Truncation cuts by console cells.
equal(Width.truncate("网络接口表", 7, console, "."), "网络接.", "truncated in cells")

-- The grid places a double-byte character across two cells.
local grid = Grid.new(12, 1, { unicode = false, console_cells = cp936 })
local _, used = grid:write(1, 1, "网络 ok")
equal(used, 7, "grid advance matches console cells")
local lead, trail = grid:get(1, 1), grid:get(2, 1)
equal(lead.char, "网", "lead cell")
equal(lead.width, 2, "lead cell width")
assert(trail.continuation, "trailing cell is a continuation")
equal(grid:get(6, 1).char, "o", "ASCII resumes after the wide cells")

-- Control bytes never reach the console, even in this mode.
local safe = Grid.new(4, 1, { unicode = false, console_cells = cp936 })
safe:write(1, 1, "a\27b")
equal(safe:get(2, 1).char, "?", "a control byte becomes '?'")

local invalid_ok = pcall(Grid.new, 2, 1, { console_cells = "936" })
assert(not invalid_ok, "console_cells must be a function")

-- ---------------------------------------------------------------------------
-- Windows default language: follow the display language only when the
-- console can show it.
-- ---------------------------------------------------------------------------

local function load_tui(fake)
    package.loaded["wtop.tui"] = nil
    package.loaded["wtop.native"] = fake
    local ok, module = pcall(require, "wtop.tui")
    package.loaded["wtop.native"] = nil
    package.loaded["wtop.tui"] = nil
    assert(ok, module)
    return module
end

local function no_environment() return nil end

local chinese_console = load_tui({
    available = true,
    user_locale = function() return "zh-CN" end,
    console_cells = function(codepoint) return codepoint == 0x4E2D and 2 or 1 end,
})
equal(chinese_console.windows_default_locale(no_environment), "zh-CN",
    "a CP936 console follows a Chinese display language")
equal(chinese_console.windows_default_locale(function(name)
    return name == "LANG" and "en_US.UTF-8" or nil
end), nil, "LANG still wins")

local western_console = load_tui({
    available = true,
    user_locale = function() return "zh-CN" end,
    console_cells = function() return 0 end,
})
equal(western_console.windows_default_locale(no_environment), nil,
    "a console that cannot show Chinese stays in English")

local pipe = load_tui({
    available = true,
    user_locale = function() return "ja-JP" end,
    console_cells = function() return nil end,
})
equal(pipe.windows_default_locale(no_environment), nil, "no classic console, no guess")

local hong_kong = load_tui({
    available = true,
    user_locale = function() return "zh-HK" end,
    console_cells = function() return 2 end,
})
equal(hong_kong.windows_default_locale(no_environment), "zh-TW",
    "Hong Kong Chinese uses the Traditional catalog")

local swiss = load_tui({
    available = true,
    user_locale = function() return "de-CH" end,
    console_cells = function() return 1 end,
})
equal(swiss.windows_default_locale(no_environment), "de-DE", "same-language fallback")

local english = load_tui({
    available = true,
    user_locale = function() return "en-GB" end,
    console_cells = function() return 1 end,
})
equal(english.windows_default_locale(no_environment), nil, "English needs no override")

return true
