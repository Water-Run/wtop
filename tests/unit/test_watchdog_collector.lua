package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Watchdog = require("wtop.collectors.watchdog")
local Fixture = require("support.fixture_fs")
local Snapshot = require("wtop.model.snapshot")
local Hardware = require("wtop.model.hardware")
local ViewModel = require("wtop.view_model")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Export = require("wtop.export")
local Report = require("wtop.report")

local base = "/sys/class/watchdog"
local files = {
  [base .. "/watchdog0/identity"] = "iTCO_wdt\n",
  [base .. "/watchdog0/state"] = "inactive\n",
  [base .. "/watchdog0/timeout"] = "30\n",
  [base .. "/watchdog0/timeleft"] = "1\n",
  [base .. "/watchdog0/status"] = "0x0\n",
  [base .. "/watchdog0/bootstatus"] = "0\n",
  [base .. "/watchdog0/nowayout"] = "0\n",
  [base .. "/watchdog0/fw_version"] = "6\n",
}
local links = {
  [base .. "/watchdog0"] = "../../devices/pci0000:00/0000:00:1f.4/iTCO_wdt/watchdog/watchdog0",
  [base .. "/watchdog0/device/driver"] = "../../../../bus/platform/drivers/iTCO_wdt",
}
local fs = Fixture.new({ files = files, links = links })
local original_read = fs.read
function fs:read(path, limit)
  assert(path ~= base .. "/watchdog0/timeleft",
    "an inactive watchdog must not be shown as a one-second reset countdown")
  assert(not path:match("^/dev/watchdog"), "never open a watchdog device")
  return original_read(self, path, limit)
end
local collector = Watchdog.new({ fs = fs })
local result = collector:sample({})
assert(collector:probe({}).available and result.status == "ok"
  and result.quality == "fresh" and #result.data.devices == 1)
local device = result.data.devices[1]
assert(device.identity == "iTCO_wdt" and device.driver == "iTCO_wdt"
  and device.state == "inactive" and device.timeout_seconds == 30
  and device.timeleft_seconds == nil and device.nowayout == false
  and device.status == 0 and device.bootstatus == 0
  and device.firmware_version == 6)

local state = Snapshot.merge(nil, { watchdog = result }, 1, 1)
state.inventory = { pci = { devices = { { address = "0000:00:1f.4" } } } }
local graph = Hardware.build(state)
local node = graph.by_id["watchdog:watchdog0"]
assert(node and node.parent_id == "pci:0000:00:1f.4" and node.kind == "watchdog"
  and node.resource == "watchdog", "the sysfs link provides a real PCI parent")
local i18n = assert(I18n.new({ locale = "en-US" }))
local system = ViewModel.build({ history_values = function() return {} end },
  state, i18n, {}, "system", nil, nil,
  { system_query = "bus:watchdog name:iTCO_wdt" }).system_devices
assert(#system.rows == 2 and system.ids[2] == node.id,
  "search keeps the PCI ancestor of a matched watchdog")
local detail = table.concat(TUI.hardware_detail_lines(state, node.id, i18n), "\n")
assert(detail:find("State: inactive", 1, true)
  and detail:find("Programmed timeout: 30", 1, true)
  and not detail:find("Time until reset", 1, true)
  and detail:find("no watchdog device was opened or kept alive", 1, true))
local exported = Export.snapshot(state)
assert(exported.watchdog.devices[1].timeleft_seconds == nil
  and exported.watchdog.devices[1].device_path:find("0000:00:1f.4", 1, true))
assert(Report.render(exported):find("Watchdog devices", 1, true))

local active = Watchdog.new({ fs = Fixture.new({ files = {
  [base .. "/watchdog0/identity"] = "Server WDT\n",
  [base .. "/watchdog0/state"] = "active\n",
  [base .. "/watchdog0/timeout"] = "30\n",
  [base .. "/watchdog0/timeleft"] = "12\n",
  [base .. "/watchdog0/pretimeout"] = "5\n",
  [base .. "/watchdog0/nowayout"] = "1\n",
  [base .. "/watchdog0/status"] = "0x80\n",
  [base .. "/watchdog0/bootstatus"] = "32\n",
  [base .. "/watchdog0/pretimeout_governor"] = "panic\n",
} }) }):sample({})
assert(active.status == "ok" and active.quality == "fresh")
local running = active.data.devices[1]
assert(running.state == "active" and running.timeleft_seconds == 12
  and running.pretimeout_seconds == 5 and running.nowayout == true
  and running.status == 128 and running.bootstatus == 32
  and running.pretimeout_governor == "panic")
local active_state = Snapshot.merge(nil, { watchdog = active }, 1, 1)
local active_detail = table.concat(TUI.hardware_detail_lines(active_state,
  "watchdog:watchdog0", i18n), "\n")
assert(active_detail:find("Time until reset: 12", 1, true))

local bad_state = Watchdog.new({ fs = Fixture.new({ files = {
  [base .. "/watchdog0/identity"] = "Probe\n",
  [base .. "/watchdog0/state"] = "arming\n",
  [base .. "/watchdog0/timeleft"] = "1\n",
} }) }):sample({})
assert(bad_state.quality == "partial" and bad_state.reason == "watchdog_data_incomplete"
  and bad_state.data.devices[1].state == nil
  and bad_state.data.devices[1].timeleft_seconds == nil)
local capped = Watchdog.new({ fs = Fixture.new({ files = {
  [base .. "/watchdog0/identity"] = "One\n",
  [base .. "/watchdog0/state"] = "inactive\n",
  [base .. "/watchdog1/identity"] = "Two\n",
  [base .. "/watchdog1/state"] = "inactive\n",
} }), max_devices = 1 }):sample({})
assert(capped.data.truncated and #capped.data.devices == 1
  and capped.quality == "partial")
local absent = Watchdog.new({ fs = Fixture.new({ dirs = { [base] = {} } }) }):sample({})
assert(absent.status == "unavailable" and absent.reason == "no_watchdog_devices")
local denied = Watchdog.new({ fs = Fixture.new({ denied = { [base] = true } }) })
assert(denied:sample({}).status == "denied" and denied:probe({}).state == "denied")
assert(not pcall(Watchdog.new, { base_path = "relative" }))

return true
