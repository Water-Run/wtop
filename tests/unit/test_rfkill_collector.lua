package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Rfkill = require("wtop.collectors.rfkill")
local Fixture = require("support.fixture_fs")
local Snapshot = require("wtop.model.snapshot")
local Hardware = require("wtop.model.hardware")
local ViewModel = require("wtop.view_model")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Export = require("wtop.export")
local Report = require("wtop.report")

local base = "/sys/class/rfkill"
local files = {
  [base .. "/rfkill0/name"] = "ideapad_wlan\n",
  [base .. "/rfkill0/type"] = "wlan\n",
  [base .. "/rfkill0/hard"] = "0\n",
  [base .. "/rfkill0/soft"] = "1\n",
  [base .. "/rfkill0/state"] = "1\n", -- contradictory legacy value is ignored
  [base .. "/rfkill0/persistent"] = "1\n",
  [base .. "/rfkill1/name"] = "hci0\n",
  [base .. "/rfkill1/type"] = "bluetooth\n",
  [base .. "/rfkill1/hard"] = "0\n",
  [base .. "/rfkill1/soft"] = "0\n",
  [base .. "/rfkill1/persistent"] = "0\n",
}
local links = {
  [base .. "/rfkill0"] = "../../devices/pci0000:00/0000:00:14.3/ieee80211/phy0/rfkill0",
  [base .. "/rfkill1"] = "../../devices/pci0000:00/0000:00:14.0/usb3/3-10/3-10:1.0/bluetooth/hci0/rfkill1",
}
local fs = Fixture.new({ files = files, links = links })
local original_read = fs.read
function fs:read(path, limit)
  assert(not path:match("/state$"), "modern hard/soft flags take precedence")
  return original_read(self, path, limit)
end
local collector = Rfkill.new({ fs = fs })
local result = collector:sample({})
assert(collector:probe({}).available and result.status == "ok"
  and result.quality == "fresh" and #result.data.devices == 2)
local wlan, bluetooth = result.data.devices[1], result.data.devices[2]
assert(wlan.name == "ideapad_wlan" and wlan.type == "wlan"
  and wlan.hard_blocked == false and wlan.soft_blocked == true
  and wlan.blocked == true and wlan.persistent == true
  and wlan.state_source == "hard_soft")
assert(bluetooth.name == "hci0" and bluetooth.type == "bluetooth"
  and bluetooth.blocked == false and bluetooth.persistent == false)

local state = Snapshot.merge(nil, { rfkill = result }, 1, 1)
state.inventory = { pci = { devices = {
  { address = "0000:00:14.3" }, { address = "0000:00:14.0" },
} }, usb = { devices = { { id = "3-10" } },
  interfaces = { { id = "3-10:1.0", parent_id = "3-10" } } } }
local graph = Hardware.build(state)
assert(graph.by_id["rfkill:rfkill0"].parent_id == "pci:0000:00:14.3")
assert(graph.by_id["rfkill:rfkill1"].parent_id == "usb-interface:3-10:1.0")
local i18n = assert(I18n.new({ locale = "en-US" }))
local system = ViewModel.build({ history_values = function() return {} end },
  state, i18n, {}, "system", nil, nil,
  { system_query = "bus:rfkill name:ideapad_wlan" }).system_devices
assert(#system.rows == 2 and system.ids[2] == "rfkill:rfkill0")
local detail = table.concat(TUI.hardware_detail_lines(state,
  "rfkill:rfkill0", i18n), "\n")
assert(detail:find("Software blocked: yes", 1, true)
  and detail:find("Hardware blocked: no", 1, true)
  and detail:find("Unblocked does not mean connected", 1, true))
local exported = Export.snapshot(state)
assert(exported.rfkill.devices[1].blocked == true
  and exported.rfkill.devices[2].blocked == false)
assert(Report.render(exported):find("RF switches", 1, true))

local legacy = Rfkill.new({ fs = Fixture.new({ files = {
  [base .. "/rfkill0/name"] = "old_wlan\n",
  [base .. "/rfkill0/type"] = "wlan\n",
  [base .. "/rfkill0/state"] = "2\n",
} }) }):sample({})
assert(legacy.status == "ok" and legacy.quality == "fresh"
  and legacy.data.devices[1].state_source == "legacy"
  and legacy.data.devices[1].hard_blocked == true
  and legacy.data.devices[1].soft_blocked == nil
  and legacy.data.devices[1].blocked == true)
local legacy_detail = table.concat(TUI.hardware_detail_lines(
  Snapshot.merge(nil, { rfkill = legacy }, 1, 1), "rfkill:rfkill0", i18n), "\n")
assert(legacy_detail:find("Legacy state cannot show", 1, true))
local mixed = Rfkill.new({ fs = Fixture.new({ files = {
  [base .. "/rfkill0/name"] = "partial\n",
  [base .. "/rfkill0/type"] = "wlan\n",
  [base .. "/rfkill0/hard"] = "0\n",
  [base .. "/rfkill0/state"] = "1\n",
} }) }):sample({})
assert(mixed.quality == "partial" and mixed.reason == "rfkill_data_incomplete"
  and mixed.data.devices[1].blocked == nil,
  "one missing modern flag must not be replaced with ambiguous legacy state")
local no_data = Rfkill.new({ fs = Fixture.new({ files = {
  [base .. "/rfkill0/name"] = "driver_without_value\n",
  [base .. "/rfkill0/type"] = "wlan\n",
  [base .. "/rfkill0/state"] = "1\n",
}, errors = {
  [base .. "/rfkill0/hard"] = 61,
  [base .. "/rfkill0/soft"] = 61,
} }) }):sample({})
assert(no_data.quality == "partial"
  and no_data.data.devices[1].state_source == nil
  and no_data.data.devices[1].blocked == nil,
  "existing hard/soft attributes without values must not use legacy state")
local invalid = Rfkill.new({ fs = Fixture.new({ files = {
  [base .. "/rfkill0/name"] = "bad\n",
  [base .. "/rfkill0/type"] = "wlan\n",
  [base .. "/rfkill0/hard"] = "2\n",
  [base .. "/rfkill0/soft"] = "0\n",
} }) }):sample({})
assert(invalid.quality == "partial" and invalid.data.devices[1].blocked == nil)
local capped = Rfkill.new({ fs = Fixture.new({ files = files }),
  max_devices = 1 }):sample({})
assert(capped.data.truncated and #capped.data.devices == 1)
local absent = Rfkill.new({ fs = Fixture.new({ dirs = { [base] = {} } }) }):sample({})
assert(absent.status == "unavailable" and absent.reason == "no_rfkill_devices")
local denied = Rfkill.new({ fs = Fixture.new({ denied = { [base] = true } }) })
assert(denied:sample({}).status == "denied" and denied:probe({}).state == "denied")
assert(not pcall(Rfkill.new, { base_path = "relative" }))

return true
