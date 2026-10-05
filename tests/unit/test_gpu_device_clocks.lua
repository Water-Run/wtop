-- A GPU device's own frequency domains, side by side.
--
-- The device table promotes one clock into a single Frequency cell and, when a
-- device publishes several, says how many it is not showing.  That stops the
-- cell implying it is the only clock, and it still leaves every other clock
-- unreadable anywhere on screen.  A client has had this view one level down
-- since the DRM drill-down; this is the device above it, and the level that
-- still exists when no client is running.
--
-- The fixture shape is the amdgpu one that motivated it: a graphics clock and a
-- memory clock, each with its own DPM states, one of which is the clock the
-- table is currently showing.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local I18n = require("wtop.i18n")
local TUI = require("wtop.tui")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

local function check(condition, message)
  if not condition then error(message, 2) end
end

local function text_of(lines)
  return table.concat(lines, "\n")
end

--- Did any clock on this screen render as zero?
---
--- Matching the text "0 MHz" would be a trap: it is a substring of "300 MHz",
--- which is a real reading, and a screen full of correct clocks would be failed
--- by it.  So the number is parsed as a whole and compared, which is also what
--- catches a zero written "0.0 GHz" rather than "0 Hz".
local function renders_a_zero_clock(rendered)
  local found_positive = false
  for number, unit in rendered:gmatch("([%d][%d%.]*)%s+([kKMG]?Hz)") do
    if tonumber(number) == 0 then return true end
    found_positive = true
  end
  return false, found_positive
end

local function find_line(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then return line end
  end
  return nil
end

local translator = assert(I18n.new({ locale = "en-US" }))

local function amd_device()
  return {
    id = "card0", stable_id = "pci-0000:03:00.0",
    model_name = "Raphael", vendor_name = "AMD", driver = "amdgpu",
    pci_bdf = "0000:03:00.0",
    metrics = { frequency_domain = "sclk" },
    frequencies = {
      domains = {
        {
          id = "sclk", source_kind = "amdgpu_dpm",
          actual_hz = 2400000000, current_hz = 2400000000,
          minimum_hz = 300000000, maximum_hz = 2500000000,
          states = {
            { level = 0, frequency_hz = 300000000 },
            { level = 1, frequency_hz = 2400000000, active = true },
            { level = 2, frequency_hz = 2500000000 },
          },
        },
        {
          id = "mclk", source_kind = "amdgpu_dpm",
          actual_hz = 1000000000, current_hz = 1000000000,
          minimum_hz = 625000000, maximum_hz = 1000000000,
          states = {
            { level = 0, frequency_hz = 625000000 },
            { level = 1, frequency_hz = 1000000000, active = true },
          },
        },
      },
      truncated = false,
    },
  }
end

-- 1. Both clocks are listed, each with its own reading, range, ceiling share and
--    performance states, and the one the table is showing is named as such.
local amd = TUI.gpu_device_clock_detail_lines(amd_device(), translator)
local amd_text = text_of(amd)
check(amd_text:find("Device · Raphael", 1, true), "the device is named")
check(amd_text:find("AMD", 1, true) and amd_text:find("amdgpu", 1, true),
  "the vendor and driver are named")
check(amd_text:find("0000:03:00.0", 1, true), "the PCI address is named")
local sclk = find_line(amd, "sclk")
check(sclk ~= nil, "the graphics clock is listed")
check(sclk:find("2.4 GHz", 1, true), "the graphics clock reading is shown")
check(sclk:find("300 MHz–2.5 GHz", 1, true), "the graphics clock range is shown")
check(sclk:find("96% of 2.5 GHz max", 1, true), "the share of the ceiling is arithmetic")
check(sclk:find("shown in the table", 1, true), "the promoted clock is marked")
check(sclk:find("amdgpu_dpm", 1, true), "the domain names the source it came from")
local mclk = find_line(amd, "mclk")
check(mclk ~= nil, "the memory clock is listed")
check(mclk:find("1 GHz", 1, true), "the memory clock reading is shown")
check(mclk:find("shown in the table", 1, true) == nil,
  "only the clock the table shows is marked as shown")
check(amd_text:find("Performance states", 1, true), "the performance states are listed")
check(amd_text:find("1: 2.4 GHz · active", 1, true), "the active state is marked")
check(amd_text:find("0: 300 MHz", 1, true), "an inactive state is listed without the mark")
-- The hardware ceiling is only worth a line when it differs from the ceiling the
-- driver will actually pick; a card whose states span its range would otherwise
-- print the same pair twice.
check(amd_text:find("hardware", 1, true) == nil,
  "a hardware range equal to the driver range is not printed twice")

-- 2. A clock that differs from its own hardware ceiling says both, because they
--    are two different statements about the same domain.
local split = TUI.gpu_device_clock_detail_lines({
  id = "card0", model_name = "Test",
  frequencies = { domains = { {
    id = "gt0", source_kind = "xe_gt",
    actual_hz = 1200000000,
    minimum_hz = 400000000, maximum_hz = 1600000000,
    hardware_minimum_hz = 100000000, hardware_maximum_hz = 2000000000,
  } } },
}, translator)
local split_sclk = find_line(split, "gt0")
check(split_sclk:find("400 MHz–1.6 GHz", 1, true), "the driver range is shown")
check(split_sclk:find("hardware 100 MHz–2 GHz", 1, true),
  "a hardware range that differs from the driver range is shown as well")

-- 3. A powered-down clock reports no rate at all.  This is the same invariant
--    the device table is held to: a clock that is off reads 0, and 0 is a state
--    rather than a frequency, so the collector keeps the domain for its maximum
--    and marks its quality instead.
local asleep = TUI.gpu_device_clock_detail_lines({
  id = "card0", model_name = "Sleeping",
  frequencies = { domains = { {
    id = "gt0", source_kind = "i915_gt",
    actual_hz = 0, current_hz = 0,
    maximum_hz = 1500000000,
    quality = "unavailable",
  } } },
}, translator)
local asleep_text = text_of(asleep)
check(not renders_a_zero_clock(asleep_text), "a powered-down clock never renders a zero rate")
local asleep_line = find_line(asleep, "gt0")
check(asleep_line:find("Maximum 1.5 GHz", 1, true),
  "a clock with no reading still states its ceiling, labelled so it is not one")
check(asleep_line:find("Unavailable", 1, true), "the clock says why it has no reading")
check(asleep_line:find("of", 1, true) == nil, "a clock with no reading has no share of a ceiling")

-- 4. A device that publishes no clock says so, rather than opening an empty
--    section a reader has to interpret.
local bare = TUI.gpu_device_clock_detail_lines({
  id = "card0", model_name = "Bare", frequencies = { domains = {} },
}, translator)
check(text_of(bare):find("publishes no clock domain", 1, true),
  "a device with no clock domain says so")

-- 5. A truncated domain list is stated, so the two clocks shown are not read as
--    the only two the card has.
local cut = TUI.gpu_device_clock_detail_lines({
  id = "card0", model_name = "Truncated",
  frequencies = { truncated = true, domains = { {
    id = "sclk", actual_hz = 2400000000, maximum_hz = 2500000000,
  } } },
}, translator)
check(text_of(cut):find("more clock domains exist than were read", 1, true),
  "a truncated domain list says so")

-- 6. One device goes straight to its clocks; several go through a list, because
--    reaching the only answer should not cost a keypress and choosing between
--    several should not be guessed.
local single = TUI.gpu_device_clock_lines(
  { devices = { amd_device() }, index = 1 }, translator, true)
check(text_of(single):find("sclk", 1, true), "a single device renders its clocks directly")
check(text_of(single):find("Up/Down selects", 1, true) == nil,
  "a single device does not put a picker in the way")

local two = TUI.gpu_device_clock_lines({ devices = {
  amd_device(),
  { id = "card1", stable_id = "pci-0000:04:00.0", model_name = "Navi",
    driver = "amdgpu", frequencies = { domains = { { id = "sclk" } } } },
}, index = 2 }, translator, true)
local two_text = text_of(two)
check(two_text:find("Up/Down selects", 1, true), "several devices get a picker")
check(two_text:find("Navi", 1, true) and two_text:find("Raphael", 1, true),
  "the picker names every device")
check(two_text:find("▸ Raphael", 1, true) == nil, "the unselected device is not marked")
check(two_text:find("▸ Navi", 1, true), "the selected device is marked")
check(two_text:find("1 Clocks", 1, true), "the picker states how many clocks a device has")

-- The ASCII profile has no glyph for the marker, and a box-drawing character in
-- an ASCII terminal is a mojibake box, not a selection.
local ascii_two = TUI.gpu_device_clock_lines({ devices = {
  amd_device(),
  { id = "card1", model_name = "Navi", frequencies = { domains = {} } },
}, index = 2 }, translator, false)
check(text_of(ascii_two):find("> Navi", 1, true), "the ASCII profile uses its own marker")
check(text_of(ascii_two):find("▸", 1, true) == nil, "the ASCII profile draws no box glyph")

-- 7. No device at all is a fact about the scan, and the screen says it instead of
--    opening a picker with nothing in it.
local none = TUI.gpu_device_clock_lines({ devices = {}, index = 1 }, translator, true)
check(text_of(none):find("publishes no clock domain", 1, true),
  "an empty device list says so")
check(text_of(none):find("Up/Down selects", 1, true) == nil,
  "an empty device list does not offer a picker")

-- 8. No clock anywhere on this screen may read zero.  The device table is held
--    to the same invariant, and this is the assertion that holds it here.  The
--    screens that do draw clocks must be shown to draw at least one, so that a
--    renderer which drew nothing at all cannot pass by having nothing to be
--    wrong about.  The picker is not among them: it counts clocks, it does not
--    read them, so the chosen device is used here instead.
local two_detail = TUI.gpu_device_clock_lines({ devices = {
  amd_device(),
  { id = "card1", model_name = "Navi", driver = "amdgpu",
    frequencies = { domains = { { id = "sclk" } } } },
}, device = amd_device(), index = 1 }, translator, true)
check(text_of(two_detail):find("sclk", 1, true),
  "a chosen device renders behind the picker too")
for _, case in ipairs({ { "amd", amd }, { "split", split }, { "asleep", asleep },
                        { "cut", cut }, { "single", single },
                        { "two-detail", two_detail } }) do
  local rendered = text_of(case[2])
  local zero, positive = renders_a_zero_clock(rendered)
  check(not zero, case[1] .. ": a clock rendered a zero rate")
  check(positive, case[1] .. ": the screen drew no clock at all, so the check proves nothing")
end

print("ok: a GPU device's own clock domains side by side")
