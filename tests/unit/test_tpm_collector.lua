package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local TPM = require("wtop.collectors.tpm")
local Fixture = require("support.fixture_fs")
local Snapshot = require("wtop.model.snapshot")
local Hardware = require("wtop.model.hardware")
local ViewModel = require("wtop.view_model")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Export = require("wtop.export")
local JSON = require("wtop.format.json")
local Report = require("wtop.report")

local base = "/sys/class/tpm"
local files = {
  [base .. "/tpm0/tpm_version_major"] = "2\n",
}
for index = 0, 23 do
  files[base .. "/tpm0/pcr-sha256/" .. index] = "PRIVATE-PCR-VALUE\n"
end
local fs = Fixture.new({ files = files, links = {
  [base .. "/tpm0/device/driver"] = "../../../bus/platform/drivers/tpm_crb_acpi",
} })
local original_read = fs.read
function fs:read(path, limit)
  assert(not path:match("/pcr%-%w+/%d+$"), "PCR values must never be opened")
  return original_read(self, path, limit)
end

local collector = TPM.new({ fs = fs })
local result = collector:sample({})
assert(collector:probe({}).available and result.status == "ok"
  and result.quality == "fresh" and #result.data.devices == 1)
local device = result.data.devices[1]
assert(device.id == "tpm0" and device.version_major == 2
  and device.driver == "tpm_crb_acpi" and #device.banks == 1
  and device.banks[1].algorithm == "sha256" and device.banks[1].pcr_count == 24
  and device.active == nil and device.enabled == nil)

local state = Snapshot.merge(nil, { tpm = result }, 1, 1)
local graph = Hardware.build(state)
local node = graph.by_id["tpm:tpm0"]
assert(node and node.kind == "os_tpm" and node.resource == "tpm"
  and node.parent_id == nil and not graph.by_id["firmware-tpm:tpm0"],
  "an OS TPM is a separate inventory node, not a guessed firmware match")
local i18n = assert(I18n.new({ locale = "en-US" }))
local system = ViewModel.build({ history_values = function() return {} end },
  state, i18n, {}, "system", nil, nil,
  { system_query = "bus:tpm name:tpm0" }).system_devices
assert(#system.rows == 1 and system.ids[1] == node.id)
local detail = table.concat(TUI.hardware_detail_lines(state, node.id, i18n), "\n")
assert(detail:find("TPM specification major: 2", 1, true)
  and detail:find("Kernel driver: tpm_crb_acpi", 1, true)
  and detail:find("sha256 (24)", 1, true)
  and detail:find("PCR values, keys and security posture were not read", 1, true))
local exported = Export.snapshot(state)
assert(exported.tpm.devices[1].banks[1].pcr_count == 24)
assert(not JSON.encode(exported):find("PRIVATE-PCR-VALUE", 1, true))
assert(Report.render(exported):find("Operating-system TPM devices", 1, true))

local legacy = TPM.new({ fs = Fixture.new({ files = {
  [base .. "/tpm1/tpm_version_major"] = "1\n",
  [base .. "/tpm1/device/active"] = "1\n",
  [base .. "/tpm1/device/enabled"] = "0\n",
  [base .. "/tpm1/device/temp_deactivated"] = "1\n",
} }) }):sample({})
assert(legacy.status == "ok" and legacy.quality == "fresh"
  and legacy.data.devices[1].active == true
  and legacy.data.devices[1].enabled == false
  and legacy.data.devices[1].temporarily_deactivated == true)
local old_kernel = TPM.new({ fs = Fixture.new({ files = {
  [base .. "/tpm0/device/caps"] = "Manufacturer: 0x53544d20\nTCG version: 1.2\nFirmware version: 8.16\n",
} }) }):sample({})
assert(old_kernel.status == "ok" and old_kernel.quality == "fresh"
  and old_kernel.data.devices[1].version_major == 1
  and old_kernel.data.devices[1].version_minor == 2
  and old_kernel.data.devices[1].version_source == "caps",
  "an older kernel can state TPM 1.2 through caps")

local bad_version = TPM.new({ fs = Fixture.new({ files = {
  [base .. "/tpm0/tpm_version_major"] = "unknown\n",
} }) }):sample({})
assert(bad_version.status == "ok" and bad_version.quality == "partial"
  and bad_version.reason == "tpm_data_incomplete"
  and bad_version.data.devices[1].version_major == nil)
local bad_flag = TPM.new({ fs = Fixture.new({ files = {
  [base .. "/tpm0/tpm_version_major"] = "2\n",
  [base .. "/tpm0/device/active"] = "maybe\n",
} }) }):sample({})
assert(bad_flag.quality == "partial" and bad_flag.data.devices[1].active == nil)
local many_banks = TPM.new({ fs = Fixture.new({ files = {
  [base .. "/tpm0/tpm_version_major"] = "2\n",
  [base .. "/tpm0/pcr-sha1/0"] = "PRIVATE-PCR-VALUE\n",
  [base .. "/tpm0/pcr-sha256/0"] = "PRIVATE-PCR-VALUE\n",
} }), max_banks = 1 }):sample({})
assert(many_banks.data.truncated and #many_banks.data.devices[1].banks == 1
  and many_banks.quality == "partial")
local many_devices = TPM.new({ fs = Fixture.new({ files = {
  [base .. "/tpm0/tpm_version_major"] = "2\n",
  [base .. "/tpm1/tpm_version_major"] = "1\n",
} }), max_devices = 1 }):sample({})
assert(many_devices.data.truncated and #many_devices.data.devices == 1)
local no_devices = TPM.new({ fs = Fixture.new({ dirs = { [base] = {} } }) }):sample({})
assert(no_devices.status == "unavailable" and no_devices.reason == "no_tpm_devices")
local denied = TPM.new({ fs = Fixture.new({ denied = { [base] = true } }) })
assert(denied:sample({}).status == "denied" and denied:probe({}).state == "denied")
assert(not pcall(TPM.new, { base_path = "relative" }))

return true
