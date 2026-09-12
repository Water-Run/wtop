package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local I18n = require("wtop.i18n")
local ProcessTable = require("wtop.model.process_table")
local TUI = require("wtop.tui")
local ViewModel = require("wtop.view_model")

local translator = assert(I18n.new({ locale = "zh-CN" }))
local engine = {
    history_values = function() return {} end,
}
local function snapshot(processes)
    return {
        cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, gpus = {},
        cpu_frequency = {}, sensors = {}, mounts = {}, workloads = {}, quality = {},
        processes = { list = processes },
    }
end
local function process(pid, starttime, parent_pid, name, cpu)
    return {
        id = tostring(pid) .. ":" .. tostring(starttime),
        pid = pid,
        starttime_ticks = starttime,
        parent_pid = parent_pid,
        name = name,
        command = name .. " --worker",
        user = "tester",
        state = "S",
        cpu_percent = cpu,
        resident_bytes = pid * 1024,
        virtual_bytes = pid * 4096,
        threads = 2,
        io = { read_bytes = pid * 10, write_bytes = pid * 20 },
    }
end

local root = process(1, 10, 0, "init", 1)
local child = process(2, 20, 1, "needle", 20)
local other = process(3, 30, 1, "other", 10)
local controller = ProcessTable.new({ sort_key = "cpu", descending = true })
local models = ViewModel.build(engine, snapshot({ root, child, other }), translator, {},
    "processes", controller)
assert(models.process_table.rows[1].id == "2:20")
assert(models.process_table.rows[1].process.starttime_ticks == 20)
-- The sort arrow is drawn by the table widget from the model's sort state
-- instead of being concatenated into a column label, so the header can stay
-- in step when the sort changes.
assert(models.process_table.sort_key == "cpu")
assert(models.process_table.sort_descending == true)
local sortable = 0
for _, column in ipairs(models.process_table.columns) do
  if column.sort_key then sortable = sortable + 1 end
end
assert(sortable >= 6, "process columns must be clickable for sorting")
assert(models.process_table.status_text:find("排序", 1, true))
assert(controller:select_id("3:30"))

-- View-model rebuilds use controller rows and preserve generation selection
-- even when the collector list and sort values reorder.
other.cpu_percent = 99
models = ViewModel.build(engine, snapshot({ other, root, child }), translator, {},
    "processes", controller)
assert(models.process_table.rows[1].id == "3:30")
assert(controller:selected_id() == "3:30")

controller:toggle_tree()
controller:set_query("needle")
models = ViewModel.build(engine, snapshot({ child, other, root }), translator, {},
    "processes", controller)
assert(#models.process_table.rows == 2)
assert(models.process_table.rows[1].id == "1:10")
assert(models.process_table.rows[2].id == "2:20")
assert(models.process_table.rows[2].name:find("  · ", 1, true))
assert(models.process_table.status_text:find("needle", 1, true))
assert(models.process_table.status_text:find("进程树", 1, true))

-- Search editing removes one Unicode codepoint, not one byte.
assert(TUI.utf8_backspace("abc测试") == "abc测")
assert(TUI.utf8_backspace("中") == "")
assert(TUI.utf8_backspace("") == "")

local details = TUI.process_detail_lines(child, translator)
assert(details[1]:find("进程详情", 1, true))
assert(#details > 20, "process details should exercise scrolling overlays")
local joined = table.concat(details, "\n")
assert(joined:find("2:20", 1, true))
assert(joined:find("needle --worker", 1, true))
assert(joined:find("I/O", 1, true))

local smart_devices = TUI.smart_selection_lines({
    { path = "/dev/nvme0n1", model = "Fast NVMe", rotational = 0 },
    { path = "/dev/sda", vendor = "Disk Corp", rotational = 1 },
}, 2, translator, true)
local smart_joined = table.concat(smart_devices, "\n")
assert(smart_joined:find("/dev/nvme0n1", 1, true))
assert(smart_joined:find("▸ /dev/sda", 1, true))
assert(smart_joined:find("HDD", 1, true))
assert(smart_joined:find("截断", 1, true))

-- Overlay reflow: a long line must wrap to the overlay width with every
-- continuation row the same width and indent.  Before this, overlays hard-clipped
-- and a long command line simply disappeared past the frame.
local Grid = require("wtop.ui.renderer.grid")
local Theme = require("wtop.ui.renderer.width") and require("wtop.ui.theme")
local Width = require("wtop.ui.renderer.width")
local overlay_grid = Grid.new(60, 20)
local long_line = "  命令        "
    .. string.rep("/usr/lib/systemd/systemd --system --deserialize=88 ", 6)
TUI.draw_overlay(overlay_grid, Theme.new("lua-blue", { truecolor = true }),
    { "标题", long_line, "尾行" }, 0, { unicode = true })
local wrapped_rows, saw_continuation = 0, false
for row = 1, 20 do
    local text = overlay_grid:row_text(row)
    assert(Width.display_width(text) <= 60,
        "overlay row " .. row .. " must not exceed the terminal width")
    if text:find("deserialize", 1, true) then
        wrapped_rows = wrapped_rows + 1
        if text:find("^%s+│%s+%-%-") then saw_continuation = true end
    end
end
assert(wrapped_rows > 1, "a long line must wrap across several overlay rows")

-- A short overlay must not gain a scrollbar, and a long one must.
local short_grid = Grid.new(40, 20)
TUI.draw_overlay(short_grid, Theme.new("lua-blue", { truecolor = true }),
    { "标题", "一行" }, 0, { unicode = true })
local short_text = table.concat({ short_grid:row_text(9), short_grid:row_text(10) }, "")
assert(not short_text:find("█", 1, true), "content that fits gets no scrollbar")

local many = { "标题" }
for index = 1, 60 do many[#many + 1] = "row " .. index end
local scroll_grid = Grid.new(40, 12)
TUI.draw_overlay(scroll_grid, Theme.new("lua-blue", { truecolor = true }), many, 0,
    { unicode = true })
local scroll_text = {}
for row = 1, 12 do scroll_text[#scroll_text + 1] = scroll_grid:row_text(row) end
scroll_text = table.concat(scroll_text, "\n")
assert(scroll_text:find("█", 1, true), "content that overflows shows a scrollbar")
assert(scroll_text:find("/60", 1, true), "the overflow counter names the total")

return true
