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
assert(models.process_table.columns[3].label:find("↓", 1, true))
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

return true
