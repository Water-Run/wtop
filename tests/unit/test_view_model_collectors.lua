-- The Insights "Collectors" table has one row per registered collector, and a
-- row's status, quality and reason are read out of the snapshot slot that
-- collector writes.  The map connecting the two is a hand-written literal in
-- `view_model.lua`, and it had sixteen entries for seventeen registered
-- collectors: `inventory` was the one missing, so its row read a nil slot and
-- printed `ready` and two em dashes whatever the collector published.  Nothing
-- noticed, because the row still looked like a row -- a collector that is
-- reporting `truncated` and a collector that is reporting nothing are drawn
-- identically.  Measured with the probe in this increment's notes, not inferred
-- from the list looking short.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Collectors = require("wtop.collectors")
local Snapshot = require("wtop.model.snapshot")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")
local Technical = require("wtop.i18n.technical")

-- The registry is asked, not restated.  A test that listed the seventeen ids
-- itself would still pass after someone adds an eighteenth collector, which is
-- the moment a missing map entry becomes possible at all.
local registered = {}
for id in pairs(Collectors.constructors) do
  if type(id) == "string" then registered[#registered + 1] = id end
end
table.sort(registered)
assert(#registered > 0, "the collector registry is empty; the guard below is vacuous")

-- Each slot gets a reason no other slot can be showing: the slot's own name.
-- A row that reads a neighbour's slot therefore displays the neighbour's name,
-- which is the failure this is for, and a row with no slot at all displays an
-- em dash, which is the one that was there before the fix.
local capabilities, quality = {}, {}
for _, id in ipairs(registered) do
  capabilities[id] = { available = true, state = "available", source = "probe" }
  local slot = Snapshot.resource_for_collector(id)
  assert(type(slot) == "string" and slot ~= "",
    "collector `" .. id .. "` resolves to no snapshot slot, so no row can be "
      .. "asked for its state; `ID_TO_RESOURCE` owns that relation")
  quality[slot] = { status = "ok", quality = "measured", reason = "slot_" .. slot }
end

local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }
local rendered = ViewModel.build(engine, {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
  cpu_frequency = {}, mounts = {}, workloads = {}, connections = {},
  sensors = { devices = {} }, inventory = {}, quality = quality,
}, translator, capabilities, "insights")

local rows = {}
for _, row in ipairs((rendered.collector_table or {}).rows or {}) do
  rows[tostring(row.collector)] = row
end
for _, id in ipairs(registered) do
  local row = rows[id]
  if row == nil then
    error("the Insights collectors table has no row for the registered "
      .. "collector `" .. id .. "`", 2)
  end
  local expected = "slot_" .. Snapshot.resource_for_collector(id)
  if row.reason ~= expected then
    error("collector `" .. id .. "` shows reason " .. tostring(row.reason)
      .. " where the slot it writes (" .. expected:sub(6) .. ") says "
      .. tostring(expected) .. ".  Either `COLLECTOR_RESOURCE` in "
      .. "`view_model.lua` has no entry for it, and the row then prints `ready` "
      .. "beside an em dash for a collector that may be publishing a failure, "
      .. "or it points at another collector's slot and the row reports a "
      .. "neighbour's state as its own.", 2)
  end
  if row.status ~= "ok" or row.quality ~= "measured" then
    error("collector `" .. id .. "` shows status " .. tostring(row.status)
      .. " and quality " .. tostring(row.quality) .. " although the slot it "
      .. "writes holds `ok`/`measured`", 2)
  end
end

-- A reason that reaches the table has to reach the operator in a language that
-- is not the code.  `device_enumeration_truncated` is the reason the device
-- inventory publishes when an enumeration stopped at its cap, and this row is
-- the only place a user learns of it, so the row is checked with the real code
-- in the slot rather than the `slot_` stand-in.
local english = {}
for _, id in ipairs(registered) do
  english[id] = Snapshot.resource_for_collector(id)
end
local truncated = { cpu = {}, memory = {}, pressure = {}, disks = {}, network = {},
  processes = {}, cpu_frequency = {}, mounts = {}, workloads = {}, connections = {},
  sensors = { devices = {} }, inventory = {},
  quality = { inventory = { status = "ok", quality = "truncated",
    reason = "device_enumeration_truncated" } } }
local with_truncation = ViewModel.build(engine, truncated, translator,
  capabilities, "insights")
local inventory_row
for _, row in ipairs((with_truncation.collector_table or {}).rows or {}) do
  if row.collector == "inventory" then inventory_row = row end
end
assert(inventory_row ~= nil, "the truncated inventory still produces no row")
assert(inventory_row.reason == "device_enumeration_truncated",
  "the inventory row shows " .. tostring(inventory_row.reason)
    .. " instead of the truncation reason; a collector that stopped at its "
    .. "device cap is indistinguishable from one that read everything")
assert(inventory_row.quality == "truncated",
  "the inventory row shows quality " .. tostring(inventory_row.quality)
    .. " where the slot holds `truncated`")
for _, locale in ipairs({ "en-US", "zh-CN", "ja-JP", "ru-RU" }) do
  local catalog = assert(I18n.new({ locale = locale }))
  local shown = Technical.reason(catalog, inventory_row.reason)
  assert(type(shown) == "string" and shown ~= "device_enumeration_truncated"
      and #shown > 0,
    locale .. " renders the inventory truncation reason as the raw code")
end
assert(english.inventory == "inventory",
  "the inventory collector writes the `inventory` slot; if that changed, the "
    .. "fixture above is no longer testing the row it claims to test")

print(string.format("ok: collector table rows (%d registered collectors read "
  .. "their own slot)", #registered))
