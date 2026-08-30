package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local LayoutStore = require("wtop.layout_store")

local defaults = {
    overview = { "cpu", "memory", "disk" },
    processes = { "table" },
}
local orders = assert(LayoutStore.parse([[
schema_version: 1
pages:
  overview:
    - disk
    - cpu
]], defaults))
assert(table.concat(orders.overview, ",") == "disk,cpu,memory")
assert(orders.processes[1] == "table")
assert(LayoutStore.parse("schema_version: 2\npages:\n  overview:\n    - cpu\n", defaults) == nil)
assert(LayoutStore.parse("schema_version: 1\npages:\n  overview:\n    - unknown\n", defaults) == nil)

local encoded = LayoutStore.encode(orders)
local roundtrip = assert(LayoutStore.parse(encoded, defaults))
assert(table.concat(roundtrip.overview, ",") == "disk,cpu,memory")

local Layout = require("wtop.model.layout")
local custom = assert(Layout.split("horizontal", 0.6, {
    assert(Layout.leaf("disk")),
    assert(Layout.split("vertical", 0.4, {
        assert(Layout.leaf("cpu")), assert(Layout.leaf("memory")),
    }, { gap = 2 })),
}, { gap = 1 }))
local encoded_v2 = LayoutStore.encode(defaults, {
    overview = custom,
    processes = assert(Layout.leaf("table")),
})
local v2_orders, v2_trees = assert(LayoutStore.parse(encoded_v2, defaults))
assert(table.concat(v2_orders.overview, ",") == "disk,cpu,memory")
assert(v2_trees.overview.type == "split" and v2_trees.overview.axis == "horizontal")
assert(math.abs(v2_trees.overview.ratio - 0.6) < 0.000001)
assert(v2_trees.overview.children[2].gap == 2)

local migrated_orders, migrated_trees = assert(LayoutStore.parse([[
schema_version: 2
pages:
  overview:
    type: split
    axis: horizontal
    ratio_micros: 500000
    gap: 1
    children:
      - type: leaf
        widget_id: "disk"
      - type: leaf
        widget_id: "cpu"
]], defaults))
assert(table.concat(migrated_orders.overview, ",") == "disk,cpu,memory",
    "new default widgets must be appended to saved trees")
assert(#assert(Layout.to_order(migrated_trees.overview)) == 3)
assert(LayoutStore.parse(encoded_v2:gsub("ratio_micros: 600000", "ratio_micros: 0"), defaults) == nil)
local _, special_status = LayoutStore.load(defaults, "/dev/null")
assert(special_status.state == "error", "layout readers must reject special files")
assert(LayoutStore.path(function() error("hostile environment") end) == nil)
assert(LayoutStore.path(function(name)
    return name == "XDG_CONFIG_HOME" and "relative" or "/home/test"
end) == "/home/test/.config/wtop/layout.yml")
local _, unsafe_status = LayoutStore.load(defaults, "/tmp/../layout.yml")
assert(unsafe_status.state == "error" and unsafe_status.reason == "invalid layout path")
assert(LayoutStore.parse("schema_version: 1\npages: {}\n", nil) == nil)

return true
