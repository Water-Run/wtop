package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Workspace = require("wtop.workspace")

local workspace = Workspace.new({ active_tab = "overview" })
assert(workspace.active == "overview")
workspace:cycle(1)
assert(workspace.active == "processes")
assert(workspace:select(10) and workspace.active == "insights")
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

-- Canvas reuse is explicit; callers that omit it still receive independent
-- frames. A resize allocates a replacement without touching the old canvas.
local Diff = require("wtop.ui.renderer.diff")
local expected = workspace:render(60, 20, { capabilities = { colors = 0, unicode = true }, widgets = {} })
assert(expected ~= grid and expected.cells[1] ~= grid.cells[1])
grid:write(1, 1, "旧帧")
local reused = workspace:render(60, 20, { capabilities = { colors = 0, unicode = true }, widgets = {} }, grid)
assert(reused == grid and #Diff.runs(expected, reused) == 0)
local previous_line = reused:row_text(1)
local resized = workspace:render(80, 24, { capabilities = { colors = 0, unicode = false }, widgets = {} }, reused)
assert(resized ~= reused and reused:row_text(1) == previous_line)
resized:assert_valid()
assert(not pcall(workspace.render, workspace, 60, 20, {}, "invalid canvas"))

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

-- The column count is content-driven rather than dictated by the mode: the
-- solver now prefers whichever axis lets its children reach their full form,
-- which is what stops a 120-column terminal from cutting four tables down to
-- three visible columns each.  What a mode still fixes is the upper bound.
local responsive_cases = {
    { 80, 50, "narrow-tall", 2 },
    { 120, 40, "standard", 4 },
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
    assert(column_count >= 1 and column_count <= case[4],
        case[3] .. " workspace column policy regressed")
    -- Every placed widget must be wide enough to render something useful.
    for _, placement in ipairs(layout.placements) do
        assert(placement.width >= 18 and placement.height >= 2,
            case[3] .. " placed a widget too small to read")
    end
    if case[3] == "wide-tall" then
        -- Widths are only comparable between panels sharing a row.
        local rows_by_y = {}
        for _, placement in ipairs(layout.placements) do
            rows_by_y[placement.y] = rows_by_y[placement.y] or {}
            local bucket = rows_by_y[placement.y]
            bucket[#bucket + 1] = placement.width
        end
        for _, bucket in pairs(rows_by_y) do
            local minimum, maximum
            for _, width in ipairs(bucket) do
                minimum = minimum and math.min(minimum, width) or width
                maximum = maximum and math.max(maximum, width) or width
            end
            assert(maximum - minimum <= 1,
                "wide-tall responsive tracks must have balanced visual proportions")
        end
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


-- A resource the host does not expose is dropped from the rendered tree so it
-- stops claiming screen space, but it must never be dropped from the layout
-- that gets persisted: the widget has to come back the moment data appears,
-- and a user who edits the layout meanwhile must not lose it.
local LayoutModel = require("wtop.model.layout")
local suppress_page = Workspace.new({ active_tab = "overview" })
local page_order = Workspace.default_orders().overview
local function leaves(workspace)
    return assert(LayoutModel.to_order(workspace:trees().overview,
        { allowed_widgets = page_order }))
end
local full_leaves = #leaves(suppress_page)
local before = #suppress_page:layout(160, 44).placements
local absent = {
    gpu_overview = true, frequency_overview = true,
    temperature_overview = true, power_overview = true,
}
assert(suppress_page:set_suppressed(absent), "the suppressed set must be applied")
assert(not suppress_page:set_suppressed(absent), "an unchanged set must not relayout")
local suppressed_placements = #suppress_page:layout(160, 44).placements
assert(suppressed_placements == before - 4,
    "every suppressed widget must leave the rendered tree")

-- Editing while widgets are suppressed must not prune them from the model.
suppress_page:toggle_edit()
assert(suppress_page:move_focused_direction("below"))
assert(suppress_page:adjust_focused_ratio(0.05))
assert(#leaves(suppress_page) == full_leaves,
    "suppressed widgets must survive a layout edit")
local persisted = {}
for _, id in ipairs(leaves(suppress_page)) do persisted[id] = true end
for id in pairs(absent) do
    assert(persisted[id], "suppressed widget lost from the persisted tree: " .. id)
end

-- Focus must never rest on a widget that is no longer rendered.
assert(not absent[suppress_page.focus.overview],
    "focus must move off a suppressed widget")

assert(suppress_page:set_suppressed({}), "clearing the set must relayout")
assert(#suppress_page:layout(160, 44).placements == before,
    "widgets must return as soon as their resource reports again")

-- The tab bar is an ordered subset of the ten registered pages. Hidden pages
-- keep their layouts and can be restored without losing edits.
local tabs = Workspace.new({ active_tab = "system",
    tab_order = { "processes", "system", "overview" } })
assert(table.concat(tabs:tab_ids(), ",") == "processes,system,overview")
assert(tabs.active == "system" and not tabs:select(4))
assert(tabs:hide_tab("system") and tabs.active == "overview")
assert(not tabs:select("system") and tabs.pages.system and tabs.layout_trees.system)
assert(tabs:show_tab("system"))
assert(table.concat(tabs:tab_ids(), ",") == "processes,overview,system")
assert(tabs:move_tab("system", -1))
assert(table.concat(tabs:tab_ids(), ",") == "processes,system,overview")
assert(not tabs:move_tab("processes", -1))
assert(tabs:select("system") and tabs.active == "system")
assert(tabs.dirty and #tabs:tab_entries() == 10)
assert(table.concat(tabs:custom_tab_order(), ",") == "processes,system,overview")
local restored_tabs = Workspace.new({ tab_order = tabs:tab_ids(),
    active_tab = "system", layout_trees = tabs:trees() })
assert(restored_tabs.active == "system")
assert(table.concat(restored_tabs:tab_ids(), ",") == "processes,system,overview")
local last = Workspace.new({ tab_order = { "overview" }, active_tab = "system" })
assert(last.active == "overview" and not last:hide_tab("overview"))
assert(last:custom_tab_order()[1] == "overview")
assert(Workspace.new({ tab_order = { "bogus" } }):custom_tab_order() == nil)
local tab_lines = require("wtop.tui").tab_manager_lines({ index = 2,
    entries = tabs:tab_entries() },
    assert(require("wtop.i18n").new({ locale = "zh-CN" })), false)
local tab_text = table.concat(tab_lines, "\n")
assert(tab_text:find("管理标签页", 1, true)
    and tab_text:find("> *", 1, true)
    and tab_text:find("-", 1, true),
    "the tab editor names visible and hidden pages in the ASCII profile")

local dashboard = Workspace.new({ active_tab = "overview" })
local created, custom_id = dashboard:new_custom_page("cpu_overview")
assert(created and custom_id == "custom1" and dashboard.active == "custom1")
assert(dashboard:content_page() == "overview")
assert(dashboard:add_focused_widget("process_table", "after"),
    "a custom page can mix widgets from different built-in pages")
assert(table.concat(dashboard:orders().custom1, ",") == "cpu_overview,process_table")
assert(dashboard:content_page() == "processes")
assert(dashboard:focus_cycle(1) == "cpu_overview"
    and dashboard:content_page() == "overview")
assert(dashboard:rename_custom_page("custom1", "  My dashboard  "))
assert(dashboard:tab_entries()[2].label == "My dashboard")
local definitions = dashboard:custom_page_definitions()
local reloaded_dashboard = Workspace.new({ custom_pages = definitions,
    tab_order = dashboard:tab_ids(), layout_trees = dashboard:trees(),
    active_tab = "custom1" })
assert(table.concat(reloaded_dashboard:orders().custom1, ",")
    == "cpu_overview,process_table")
assert(reloaded_dashboard:remove_custom_page("custom1")
    and reloaded_dashboard.pages.custom1 == nil
    and reloaded_dashboard:custom_page_definitions() == nil)
local custom_only = Workspace.new({ custom_pages = definitions,
    tab_order = { "custom1" }, active_tab = "custom1" })
assert(not custom_only:remove_custom_page("custom1"))
local bounded_pages = Workspace.new()
for _ = 1, 8 do assert(bounded_pages:new_custom_page("cpu_overview")) end
assert(not bounded_pages:new_custom_page("cpu_overview"),
    "custom page count is bounded")
local source = Workspace.new({ active_tab = "overview" })
local source_order = table.concat(source:orders().overview, ",")
local copied, copy_id = source:duplicate_page("overview")
assert(copied and copy_id == "custom1")
assert(table.concat(source:orders().custom1, ",") == source_order,
    "duplication copies the whole page, not just its focused widget")
assert(source:remove_focused_widget())
assert(table.concat(source:orders().overview, ",") == source_order,
    "editing the copy must not mutate its source")
local copied_again, second_copy = source:duplicate_page("custom1")
assert(copied_again and second_copy == "custom2"
    and table.concat(source:orders().custom2, ",")
        == table.concat(source:orders().custom1, ","))

return true
