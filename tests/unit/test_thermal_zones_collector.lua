package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Thermal = require("wtop.collectors.thermal_zones")
local Fixture = require("support.fixture_fs")
local Snapshot = require("wtop.model.snapshot")
local Hardware = require("wtop.model.hardware")
local ViewModel = require("wtop.view_model")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Export = require("wtop.export")
local Report = require("wtop.report")

local base = "/sys/class/thermal"
local files = {
  [base .. "/thermal_zone0/type"] = "acpitz\n",
  [base .. "/thermal_zone0/temp"] = "27800\n",
  [base .. "/thermal_zone0/mode"] = "enabled\n",
  [base .. "/thermal_zone0/policy"] = "user_space\n",
  [base .. "/thermal_zone0/trip_point_0_type"] = "critical\n",
  [base .. "/thermal_zone0/trip_point_0_temp"] = "105000\n",
  [base .. "/thermal_zone0/trip_point_1_type"] = "passive\n",
  [base .. "/thermal_zone0/trip_point_1_temp"] = "-274000\n",
  [base .. "/thermal_zone0/cdev0_trip_point"] = "0\n",
  [base .. "/thermal_zone0/cdev0_weight"] = "1024\n",
  [base .. "/thermal_zone1/type"] = "iwlwifi_1\n",
  [base .. "/thermal_zone1/temp"] = "59000\n",
  [base .. "/cooling_device0/type"] = "Fan\n",
  [base .. "/cooling_device0/max_state"] = "3\n",
  [base .. "/cooling_device0/cur_state"] = "1\n",
  [base .. "/cooling_device0/stats/total_trans"] = "4\n",
  [base .. "/cooling_device0/stats/time_in_state_ms"] =
    "state0\t100\nstate1\t200\nstate2\t0\nstate3\t50\n",
  [base .. "/cooling_device1/type"] = "Processor\n",
  [base .. "/cooling_device1/max_state"] = "3\n",
  [base .. "/cooling_device1/cur_state"] = "0\n",
}
local links = {
  [base .. "/thermal_zone0/cdev0"] = "../cooling_device0",
  [base .. "/thermal_zone0"] = "../../devices/virtual/thermal/thermal_zone0",
  ["/sys/devices/virtual/thermal/thermal_zone0/device"] =
    "../../../pci0000:00/0000:00:14.3",
}
local fs = Fixture.new({ files = files, links = links })
local original_read = fs.read
function fs:read(path, limit)
  assert(not path:match("/stats/reset$") and not path:match("/stats/trans_table$"),
    "cooling statistics are read-only and the transition matrix is outside the bounded sample")
  return original_read(self, path, limit)
end
local collector = Thermal.new({ fs = fs })
local result = collector:sample({})
assert(collector:probe({}).available and result.status == "ok"
  and result.quality == "fresh" and #result.data.zones == 2
  and #result.data.cooling_devices == 2)
local zone = result.data.zones[1]
assert(zone.type == "acpitz" and zone.temperature_celsius == 27.8
  and zone.mode == "enabled" and zone.policy == "user_space"
  and #zone.trips == 2 and zone.trips[1].temperature_celsius == 105
  and zone.trips[2].temperature_celsius == nil,
  "below-absolute-zero trip sentinel is not a real threshold")
assert(zone.device_path == "/sys/devices/pci0000:00/0000:00:14.3",
  "the physical device link is relative to the resolved class entry")
assert(#zone.bindings == 1 and zone.bindings[1].cooling_id == "cooling_device0"
  and zone.bindings[1].trip_index == 0 and zone.bindings[1].weight == 1024)
assert(result.data.cooling_devices[1].cur_state == 1
  and result.data.cooling_devices[1].max_state == 3)
local stats = assert(result.data.cooling_devices[1].stats)
assert(stats.quality == "fresh" and stats.total_transitions == 4
  and #stats.time_in_state_ms == 4
  and stats.time_in_state_ms[2].state == 1
  and stats.time_in_state_ms[2].milliseconds == 200)
assert(result.data.cooling_devices[2].stats == nil,
  "a device without a statistics directory retains its valid current state")

local state = Snapshot.merge(nil, { thermal_zones = result }, 1, 1)
state.inventory = { pci = { devices = { { address = "0000:00:14.3" } } } }
local graph = Hardware.build(state)
local zone_node = assert(graph.by_id["thermal-zone:thermal_zone0"])
local cooler_node = assert(graph.by_id["cooling-device:cooling_device0"])
assert(zone_node.parent_id == "pci:0000:00:14.3")
assert(zone_node.cooling_ids[1] == cooler_node.id
  and cooler_node.thermal_zone_ids[1] == zone_node.id)
assert(Hardware.related(graph, zone_node.id).items[1].id == cooler_node.id)
assert(Hardware.related(graph, cooler_node.id).items[1].id == zone_node.id)
local i18n = assert(I18n.new({ locale = "en-US" }))
local rows = ViewModel.build({ history_values = function() return {} end },
  state, i18n, {}, "system", nil, nil,
  { system_query = "bus:thermal name:acpitz" }).system_devices
local found = false
for _, id in ipairs(rows.ids) do if id == zone_node.id then found = true end end
assert(found, "System search includes the thermal zone")
local detail = table.concat(TUI.hardware_detail_lines(state, zone_node.id, i18n), "\n")
assert(detail:find("27.8", 1, true)
  and detail:find("critical", 1, true)
  and detail:find("105", 1, true)
  and detail:find("Fan", 1, true)
  and not detail:find("-274", 1, true))
local cooler_detail = table.concat(TUI.hardware_detail_lines(
  state, cooler_node.id, i18n), "\n")
assert(cooler_detail:find("Current state: 1", 1, true)
  and cooler_detail:find("State changes since statistics reset: 4", 1, true)
  and cooler_detail:find("1 = 200 ms", 1, true)
  and cooler_detail:find("not fan speed or percent", 1, true))
local exported = Export.snapshot(state)
assert(exported.thermal_zones.zones[1].trips[2].temperature_celsius == nil
  and exported.thermal_zones.zones[1].bindings[1].cooling_id == "cooling_device0")
assert(exported.thermal_zones.cooling_devices[1].stats.total_transitions == 4
  and exported.thermal_zones.cooling_devices[1].stats.time_in_state_ms[2].milliseconds == 200)
assert(Report.render(exported):find("Thermal cooling links", 1, true))
assert(Report.render(exported):find("Cooling state time (nonzero)", 1, true))

files[base .. "/cooling_device0/stats/total_trans"] = "1\n"
files[base .. "/cooling_device0/stats/time_in_state_ms"] =
  "state0\t5\nstate1\t2\nstate2\t0\nstate3\t1\n"
local reset = collector:sample({})
assert(reset.quality == "fresh"
  and reset.data.cooling_devices[1].stats.total_transitions == 1
  and reset.data.cooling_devices[1].stats.time_in_state_ms[2].milliseconds == 2,
  "resettable counters are published raw, without a fabricated delta")
files[base .. "/cooling_device0/stats/total_trans"] = "4\n"
files[base .. "/cooling_device0/stats/time_in_state_ms"] =
  "state0\t100\nstate1\t200\nstate2\t0\nstate3\t50\n"

local malformed = Thermal.new({ fs = Fixture.new({ files = {
  [base .. "/thermal_zone0/type"] = "bad\n",
  [base .. "/thermal_zone0/temp"] = "-274000\n",
  [base .. "/thermal_zone0/trip_point_0_temp"] = "80000\n",
  [base .. "/cooling_device0/type"] = "Fan\n",
  [base .. "/cooling_device0/max_state"] = "3\n",
  [base .. "/cooling_device0/cur_state"] = "4\n",
}, links = { [base .. "/thermal_zone0/cdev0"] = "../cooling_device99" } }) }):sample({})
assert(malformed.status == "ok" and malformed.quality == "partial"
  and malformed.reason == "thermal_data_incomplete"
  and malformed.data.zones[1].temperature_celsius == nil
  and malformed.data.zones[1].trips[1].type == nil
  and malformed.data.cooling_devices[1].cur_state == nil)
local malformed_graph = Hardware.build(Snapshot.merge(nil,
  { thermal_zones = malformed }, 1, 1))
assert(#malformed_graph.by_id["thermal-zone:thermal_zone0"].cooling_ids == 0,
  "a missing cooling device cannot become a resolved relation")
local invalid_stats = Thermal.new({ fs = Fixture.new({ files = {
  [base .. "/cooling_device0/type"] = "Fan\n",
  [base .. "/cooling_device0/max_state"] = "1\n",
  [base .. "/cooling_device0/cur_state"] = "0\n",
  [base .. "/cooling_device0/stats/total_trans"] = "bad\n",
  [base .. "/cooling_device0/stats/time_in_state_ms"] =
    "state0 3\nstate0 4\nstate2 5\n",
} }) }):sample({})
assert(invalid_stats.quality == "partial"
  and invalid_stats.data.cooling_devices[1].stats.quality == "partial"
  and invalid_stats.data.cooling_devices[1].stats.total_transitions == nil
  and #invalid_stats.data.cooling_devices[1].stats.time_in_state_ms == 1,
  "duplicate, out-of-range and missing state rows cannot become valid counters")
local capped = Thermal.new({ fs = Fixture.new({ files = files, links = links }),
  max_zones = 1, max_cooling = 1 }):sample({})
assert(capped.data.truncated and #capped.data.zones == 1
  and #capped.data.cooling_devices == 1 and capped.quality == "partial")
local absent = Thermal.new({ fs = Fixture.new({ dirs = { [base] = {} } }) }):sample({})
assert(absent.status == "unavailable" and absent.reason == "no_linux_thermal_devices")
local denied = Thermal.new({ fs = Fixture.new({ denied = { [base] = true } }) })
assert(denied:sample({}).status == "denied" and denied:probe({}).state == "denied")
assert(not pcall(Thermal.new, { base_path = "relative" }))
assert(not pcall(Thermal.new, { max_zones = 65 }))

return true
