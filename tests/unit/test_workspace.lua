package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Workspace = require("wtop.workspace")

local workspace = Workspace.new({ active_tab = "overview" })
assert(workspace.active == "overview")
workspace:cycle(1)
assert(workspace.active == "processes")
assert(workspace:select(8) and workspace.active == "insights")
assert(not workspace:select("missing"))
workspace:select("overview")

local first = workspace.focus.overview
assert(workspace:focus_cycle(1) ~= first)
local focused = workspace.focus.overview
assert(workspace:toggle_edit())
assert(workspace:move_focused(1))
assert(workspace.focus.overview == focused)
assert(workspace:move_focused_direction("below"))
assert(workspace:adjust_focused_ratio(0.05))
local edited_order = table.concat(workspace:orders().overview, ",")
assert(workspace:undo())
assert(workspace:redo())
assert(table.concat(workspace:orders().overview, ",") == edited_order)
local persisted = workspace:trees()
local restored = Workspace.new({ active_tab = "overview", layout_trees = persisted })
assert(table.concat(restored:orders().overview, ",") == edited_order)

local grid, metadata = workspace:render(60, 20, {
    capabilities = { colors = 0, unicode = true },
    widgets = {},
})
assert(grid.width == 60 and grid.height == 20)
assert(metadata.mode == "tiny")
assert(#metadata.layout.placements > 1,
    "compact workspaces should use available cells instead of showing one oversized card")
local focused_visible = false
for _, placement in ipairs(metadata.layout.placements) do
    if placement.id == workspace.focus.overview then focused_visible = true end
end
assert(focused_visible, "focused widget must survive responsive overflow")
assert(#metadata.layout.placements + #metadata.layout.hidden == #workspace:orders().overview)
grid:assert_valid()

for _, tab in ipairs({ "overview", "processes", "compute", "storage", "network", "gpu", "workloads", "insights" }) do
    local compact = Workspace.new({ active_tab = tab })
    local _, compact_metadata = compact:render(60, 20, {
        capabilities = { colors = 0, unicode = true },
        widgets = {},
    })
    assert(#compact_metadata.layout.placements >= 1,
        "compact workspace must keep useful content on " .. tab)
    assert(#compact_metadata.layout.placements + #compact_metadata.layout.hidden
        == #compact:orders()[tab], "responsive accounting regressed on " .. tab)
end

local responsive_cases = {
    { 80, 50, "narrow-tall", 1 },
    { 120, 40, "standard", 2 },
    { 160, 24, "wide-short", 4 },
    { 180, 45, "wide-tall", 3 },
}
for _, case in ipairs(responsive_cases) do
    local responsive = Workspace.new({ active_tab = "overview" })
    local layout = responsive:layout(case[1], case[2])
    assert(layout.mode == case[3])
    local x_positions = {}
    for _, placement in ipairs(layout.placements) do x_positions[placement.x] = true end
    local column_count = 0
    for _ in pairs(x_positions) do column_count = column_count + 1 end
    assert(column_count == case[4], case[3] .. " workspace column policy regressed")
    if case[3] == "wide-tall" then
        local widths = {}
        for _, placement in ipairs(layout.placements) do widths[placement.x] = placement.width end
        local minimum, maximum
        for _, width in pairs(widths) do
            minimum = minimum and math.min(minimum, width) or width
            maximum = maximum and math.max(maximum, width) or width
        end
        assert(maximum - minimum <= 1,
            "wide-tall responsive tracks must have balanced visual proportions")
    end
end

local tiny_gpu = Workspace.new({ active_tab = "gpu" }):visible_widgets(60, 20)
assert(tiny_gpu.gpu_summary and tiny_gpu.gpu_table and not tiny_gpu.gpu_process_table,
    "compact GPU page must retain summary/device data without enabling the expensive process scan")

-- The 80x24/80x25 boundary keeps the same cards in the same column grouping.
local boundary = Workspace.new({ active_tab = "overview" })
local low, high = boundary:layout(80, 24), boundary:layout(80, 25)
assert(#low.placements == #high.placements)
for index, placement in ipairs(low.placements) do
    assert(placement.id == high.placements[index].id)
    assert(placement.x == high.placements[index].x)
end

return true
