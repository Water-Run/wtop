-- Real PCI identity, per-domain power and actual clocks from Sysman.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local LEVELZERO = require("wtop.collectors.levelzero")
local GPU = require("wtop.collectors.gpu")
local Fixture = require("support.fixture_fs")
local Power = require("wtop.model.power")
local Export = require("wtop.export")
local function equal(actual, expected, message)
  assert(actual==expected,(message or "values differ")..": "..tostring(actual).." / "..tostring(expected))
end
local function truthy(value,message) assert(value,message) end
local _,err=LEVELZERO.query(function() error("boom") end)
equal(err,"levelzero_query_failed")
local _,why=LEVELZERO.query(nil);equal(why,"levelzero_provider_unavailable")
local levelzero_data={driver_count=1,transport="process",sample_started_ns=1000000,devices={
 {index=0,pci_bdf="00000000:00:02.0",vendor_id=0x8086,uuid="gpu-first",name="First GPU",
  temperature_celsius=47,graphics_clock_hz=1200000000,memory_clock_hz=6400000000,
  board_power_watts=28.5,power_watts=28.5,power_limit_watts=40,power_scope="card",power_quality="fresh",power_measurement="average",power_interval_ns=100000000,
  frequency_domains={{index=0,kind="gpu",actual_hz=1200000000,requested_hz=1300000000,throttle_raw_hex="0x0000000000000001",throttle_quality="fresh"}},
  power_domains={{index=0,scope="card",power_watts=28.5,quality="fresh",limits={{watts=40,unit_code=2}}}}},
 {index=1,pci_bdf="0000:00:03.0",vendor_id=0x8086,name="Second GPU",temperature_celsius=52,board_power_watts=61.25},
}}
local function card(id)
 return {id=id,pci_bdf=id,driver="xe",metrics={},capabilities={},processes={list={},by_id={},summary={}}}
end
local arc,arc2=card("0000:00:02.0"),card("0000:00:03.0")
-- Reversed DRM enumeration still binds each measurement to its own PCI address.
local devices={arc2,arc}
local status=LEVELZERO.merge(devices,levelzero_data,{by_bdf={[arc.id]=arc,[arc2.id]=arc2}},{used_ids={}})
equal(status.status,"ok");equal(status.merged_devices,2);equal(status.added_devices,0)
equal(arc.metrics.temperature_celsius,47);equal(arc2.metrics.temperature_celsius,52)
equal(arc.metrics.power_watts,28.5);equal(arc.metrics.power_source,"levelzero")
equal(Power.gpu(arc.metrics,nil,arc.quality).comparison.percent,71.25)
equal(arc.frequencies.domains[1].actual_hz,1200000000)
equal(arc.frequencies.domains[1].requested_hz,1300000000)
equal(arc.performance_limits.domains[1].observed_at_ns,1000000)
equal(arc.performance_limits.domains[1].reasons[1].active,true)
equal(arc.sysman.power_domains[1].power_watts,28.5)
local filled=card("0000:00:02.0");filled.metrics={temperature_celsius=39,power_watts=12,power_source="nvml"}
LEVELZERO.merge({filled},levelzero_data,{filled},{used_ids={}})
equal(filled.metrics.temperature_celsius,39);equal(filled.metrics.power_watts,12)
assert(Power.gpu(filled.metrics,nil,filled.quality).comparison==nil,"don't pair different provider sources")
local unknown={driver_count=1,devices={{index=0,uuid="unknown",temperature_celsius=99}}}
local original=card("0000:00:02.0");local set={original}
local unresolved=LEVELZERO.merge(set,unknown,{original},{used_ids={}})
equal(original.metrics.temperature_celsius,nil,"a missing BDF does not authorize a positional join")
equal(unresolved.unmatched_devices,1);equal(set[2].identity_quality,"estimated")
local separate={};local standalone=LEVELZERO.merge(separate,levelzero_data,nil,{used_ids={}})
equal(standalone.added_devices,2);equal(standalone.status,"ok");equal(separate[1].pci_bdf,arc.id)
local duplicate=LEVELZERO.merge({}, {devices={levelzero_data.devices[1],levelzero_data.devices[1]}},nil,{used_ids={}})
equal(duplicate.duplicates,1);equal(duplicate.status,"partial")
local cold={};LEVELZERO.merge(cold,{devices={{index=0,pci_bdf="0000:06:00.0",temperature_celsius=-20}}},nil,{used_ids={}})
equal(cold[1].metrics.temperature_celsius,-20,"valid subzero Celsius is retained")
local warm=LEVELZERO.merge({}, {devices={{index=0,pci_bdf=arc.id,power_reason="levelzero_power_warmup"}}},nil,{used_ids={}})
assert(warm.pending_measurements)

-- The collector: an i915 fixture tree plus an injected provider.
local card = "/sys/class/drm/card1"
local intel_tree = {
  files = {
    [card .. "/dev"] = "226:0\n",
    [card .. "/uevent"] = "MAJOR=226\nMINOR=0\nDEVNAME=dri/card1\n",
    [card .. "/device/vendor"] = "0x8086\n",
    [card .. "/device/device"] = "0x56a0\n",
    [card .. "/device/class"] = "0x030000\n",
  },
  links = {
    [card] = "../../devices/pci0000:00/0000:00:02.0/drm/card1",
    [card .. "/device"] = "../../../0000:00:02.0",
    [card .. "/device/driver"] = "../../../../bus/pci/drivers/i915",
  },
}

local calls = 0
local single = { driver_count = 1, devices = { levelzero_data.devices[1] } }
local collector = GPU.new({ fs = Fixture.new(intel_tree), scan_processes = false,
  levelzero = function()
    calls = calls + 1
    return single
  end })
local merged = collector:sample({ now_ns = function() return 1 end })
equal(merged.status, "ok", "the collector runs with a Level Zero provider")
equal(merged.data.providers.levelzero.status, "ok", "a fully matched provider is ok")
equal(merged.data.providers.levelzero.merged_devices, 1, "the card is joined")
equal(calls, 1, "the provider is consulted once per sample")
local device = merged.data.by_id["0000:00:02.0"]
truthy(device, "the DRM device keeps its bus-address ID")
equal(device.metrics.board_power_watts, 28.5, "package power reaches the DRM device")
equal(device.metrics.board_power_source, "levelzero", "with its source")
equal(#merged.data.devices, 1, "no stray device is invented")

-- A provider that sees more devices than the page has cards must not
-- cross-wire them onto the wrong card.
local wide = GPU.new({ fs = Fixture.new(intel_tree), scan_processes = false,
  levelzero = function() return levelzero_data end })
local wide_sample = wide:sample({ now_ns = function() return 6 end })
equal(wide_sample.data.providers.levelzero.status, "ok",
  "a verified PCI identity remains valid without a DRM card")
equal(wide_sample.data.providers.levelzero.unmatched_devices, 0, "verified address is not an inferred association")
equal(#wide_sample.data.devices, 2, "the extra device is listed on its own")
equal(wide_sample.data.devices[2].identity_quality, "fresh",
  "the SDK supplies its PCI identity")

-- Safe mode must not load a vendor library.
local safe = collector:sample({ now_ns = function() return 2 end, safe_mode = true })
equal(safe.data.providers.levelzero.reason, "safe_mode", "safe mode skips Level Zero")
equal(safe.data.devices[1].metrics.board_power_watts, nil,
  "and no vendor figure reaches the panel")

-- A host with no loader still works, and says why.
local bare = GPU.new({ fs = Fixture.new(intel_tree), scan_processes = false,
  levelzero = function() return nil, "levelzero_library_not_found" end })
local bare_sample = bare:sample({ now_ns = function() return 3 end })
equal(bare_sample.status, "ok", "the DRM path works without Level Zero")
equal(bare_sample.data.providers.levelzero.status, "unavailable", "provider unavailable")
equal(bare_sample.data.providers.levelzero.reason, "levelzero_library_not_found",
  "with its reason")
equal(#bare_sample.data.devices, 1, "and the card is still listed")

-- A fixture filesystem gets no host library unless a test injects one.
local injected = GPU.new({ fs = Fixture.new(intel_tree), scan_processes = false })
local injected_sample = injected:sample({ now_ns = function() return 4 end })
equal(injected_sample.data.providers.levelzero.reason, "levelzero_provider_unavailable",
  "a fixture filesystem never reaches the host loader")
equal(#injected_sample.data.devices, 1, "and only sees its own tree")

-- A card at another PCI address is not given this provider's measurements.
local nvidia_card = "/sys/class/drm/card1"
local nvidia_tree = {
  files = {
    [nvidia_card .. "/dev"] = "226:1\n",
    [nvidia_card .. "/uevent"] = "MAJOR=226\nMINOR=1\nDEVNAME=dri/card1\n",
    [nvidia_card .. "/device/vendor"] = "0x10de\n",
    [nvidia_card .. "/device/device"] = "0x2520\n",
    [nvidia_card .. "/device/class"] = "0x030000\n",
  },
  links = {
    [nvidia_card] = "../../devices/pci0000:00/0000:00:01.0/0000:01:00.0/drm/card1",
    [nvidia_card .. "/device"] = "../../../0000:01:00.0",
    [nvidia_card .. "/device/driver"] = "../../../../bus/pci/drivers/nvidia",
  },
}
local foreign = GPU.new({ fs = Fixture.new(nvidia_tree), scan_processes = false,
  levelzero = function() return levelzero_data end })
local foreign_sample = foreign:sample({ now_ns = function() return 5 end })
equal(#foreign_sample.data.devices, 3,
  "the NVIDIA card is listed and both Level Zero devices stand alone")
local nv = foreign_sample.data.by_id["0000:01:00.0"]
truthy(nv.driver == "nvidia", "the DRM card is the NVIDIA one")
equal(nv.metrics.temperature_celsius, nil,
  "an Intel reading is never attached to another vendor's card")
equal(nv.metrics.board_power_watts, nil, "nor is board power")

print("ok: Level Zero provider (Intel join, board power, partial identity, safe mode)")
return true
