local UI = require("wtop.ui")
local LayoutModel = require("wtop.model.layout")

local Workspace = {}
Workspace.__index = Workspace

local function translated(i18n, id, fallback, variables)
    local value = i18n and i18n:t(id, variables)
    if value and value ~= id then return value end
    -- A missing key falls back to the English literal, which may itself carry
    -- {placeholders}.  Leaving them unsubstituted printed "{sort} {direction}"
    -- straight into panel titles, so the fallback gets the same interpolation
    -- the catalogue entry would have received.
    if variables and i18n and i18n.format and type(fallback) == "string"
        and fallback:find("{", 1, true) then
        local ok, interpolated = pcall(i18n.format.interpolate, i18n.format, fallback, variables)
        if ok and type(interpolated) == "string" then return interpolated end
    end
    return fallback
end

local TAB_DEFINITIONS = {
    { id = "overview", label_id = "tabs.overview", label = "Overview" },
    { id = "processes", label_id = "tabs.processes", label = "Processes" },
    { id = "compute", label_id = "tabs.compute", label = "Compute" },
    { id = "memory", label_id = "tabs.memory", label = "Memory" },
    { id = "storage", label_id = "tabs.storage", label = "Storage & I/O" },
    { id = "network", label_id = "tabs.network", label = "Network" },
    { id = "gpu", label_id = "tabs.gpu", label = "GPU" },
    { id = "workloads", label_id = "tabs.workloads", label = "Workloads" },
    { id = "system", label_id = "tabs.system", label = "System" },
    { id = "insights", label_id = "tabs.insights", label = "Insights" },
}

local function widget(id, kind, title, priority, dimensions)
    dimensions = dimensions or {}
    local bordered = dimensions.border ~= false
    -- Form minima describe the complete panel rectangle.  A bordered panel
    -- consumes two rows and two columns for its frame; keeping that chrome out
    -- of these values used to create 2-3 row panels with no room for content.
    -- Below roughly 30 columns a table degenerates into a single truncated
    -- field.  Treat that as overflow when sibling summaries are available;
    -- a page containing only the table may still render below its minimum.
    -- key_value, bars, and segments carry list-shaped content, so they need a
    -- table's floor rather than a single metric's.
    local listy = kind == "table" or kind == "key_value" or kind == "bars"
    local value_width = dimensions.value_width or (listy and 32 or 18)
    local value_height = dimensions.value_height
        or (listy and (bordered and 7 or 5) or (bordered and 4 or 2))
    return UI.Layout.widget({
        id = id,
        kind = kind,
        priority = priority or 0,
        min_width = dimensions.width or (listy and 48 or 26),
        min_height = dimensions.height or (listy and 10 or 6),
        compact_min_width = dimensions.compact_width,
        compact_min_height = dimensions.compact_height or value_height,
        spark_min_width = dimensions.spark_width or value_width,
        spark_min_height = dimensions.spark_height or value_height,
        value_min_width = value_width,
        value_min_height = value_height,
        panel_title = title,
        border = bordered,
    })
end

local function page(id, tabs, children)
    return UI.Views.Page.new({
        id = id,
        tabs = tabs,
        brand = "wtop",
        layout = UI.Layout.flow(children, { id = id .. ":layout", gap = 1 }),
    })
end

local function build_pages(tabs, i18n)
    local function t(id, fallback) return translated(i18n, id, fallback) end
    return {
        overview = page("overview", tabs, {
            widget("cpu_overview", "metric", t("metrics.cpu", "CPU"), 100),
            widget("memory_overview", "metric", t("metrics.memory", "Memory"), 95),
            widget("host_overview", "key_value", t("widgets.host", "Host"), 92,
                { width = 34, height = 8 }),
            widget("core_overview", "bars", t("widgets.per_core", "Per-core CPU"), 88,
                { width = 30, height = 6 }),
            widget("pressure_overview", "metric", t("metrics.pressure", "PSI"), 80),
            widget("disk_overview", "metric", t("metrics.disk_io", "Disk I/O"), 75),
            widget("network_overview", "metric", t("metrics.network", "Network"), 70),
            widget("gpu_overview", "metric", t("metrics.gpu", "GPU"), 65),
            widget("frequency_overview", "metric", t("metrics.frequency", "Frequency"), 62),
            widget("temperature_overview", "metric", t("metrics.temperature", "Temperature"), 60),
            widget("power_overview", "metric", t("metrics.power", "Power"), 58),
        }),
        processes = page("processes", tabs, {
            widget("process_table", "table", t("widgets.processes", "Processes"),
                100, { width = 56, height = 12 }),
        }),
        compute = page("compute", tabs, {
            widget("cpu_total", "metric", t("widgets.cpu_utilization", "CPU utilization"), 100),
            widget("core_bars", "bars", t("widgets.per_core", "Per-core CPU"), 96,
                { width = 30, height = 6 }),
            widget("cpu_identity", "key_value", t("widgets.cpu_identity", "CPU identity"),
                94, { width = 42, height = 9 }),
            widget("core_table", "table", t("widgets.logical_cpus", "Logical CPUs"),
                88, { width = 52, height = 12 }),
            widget("load_summary", "key_value", t("widgets.load_average", "Load average"),
                80, { width = 26, height = 7 }),
            widget("cpufreq_table", "table", t("widgets.frequency_policies", "Frequency policies"),
                70, { width = 58, height = 10 }),
            widget("sensor_table", "table", t("widgets.sensors", "Sensors"),
                65, { width = 56, height = 10 }),
            widget("power_table", "table", t("widgets.power_zones", "Power zones"),
                64, { width = 62, height = 10 }),
        }),
        memory = page("memory", tabs, {
            widget("memory_total", "metric", t("widgets.memory_utilization", "Memory utilization"), 100),
            widget("memory_segments", "segments", t("widgets.memory_composition", "Composition"),
                96, { width = 36, height = 6, value_height = 3 }),
            widget("memory_detail", "key_value", t("widgets.memory_detail", "Memory detail"),
                92, { width = 34, height = 10 }),
            widget("swap_detail", "key_value", t("widgets.swap", "Swap"),
                84, { width = 34, height = 8 }),
            widget("memory_pressure", "metric", t("widgets.memory_pressure", "Memory pressure"), 78),
            widget("memory_counters", "key_value", t("widgets.paging", "Paging & faults"),
                70, { width = 34, height = 9 }),
        }),
        storage = page("storage", tabs, {
            widget("storage_summary", "metric", t("widgets.storage_throughput", "Storage throughput"), 100),
            widget("disk_table", "table", t("widgets.block_devices", "Block devices"),
                95, { width = 56, height = 12 }),
            widget("mount_table", "table", t("widgets.filesystems", "Filesystems & mounts"),
                90, { width = 62, height = 12 }),
            widget("io_pressure", "metric", t("widgets.io_pressure", "I/O pressure"), 60),
            widget("smart_hint", "key_value", t("widgets.deep_health", "Deep health"),
                50, { width = 34, height = 7 }),
        }),
        network = page("network", tabs, {
            widget("network_summary", "metric", t("widgets.network_throughput", "Network throughput"), 100),
            widget("network_table", "table", t("widgets.interfaces", "Interfaces"),
                95, { width = 54, height = 12 }),
            widget("connection_table", "table", t("widgets.connections", "Sockets & connections"),
                88, { width = 72, height = 14 }),
            widget("address_table", "table", t("widgets.addresses", "Addresses & routes"),
                80, { width = 52, height = 10 }),
        }),
        gpu = page("gpu", tabs, {
            widget("gpu_summary", "metric", t("widgets.gpu_utilization", "GPU utilization"), 100),
            widget("gpu_table", "table", t("widgets.gpu_devices", "Graphics devices"),
                95, { width = 58, height = 12 }),
            widget("gpu_process_table", "table", t("widgets.gpu_processes", "GPU processes"),
                90, { width = 68, height = 14 }),
        }),
        workloads = page("workloads", tabs, {
            widget("workload_summary", "metric", t("widgets.workload_summary", "Workload pressure"),
                100),
            widget("workload_table", "table", t("widgets.cgroups", "cgroup v2 workloads"),
                95, { width = 66, height = 14 }),
            widget("workload_detail", "key_value", t("widgets.workload_detail", "Workload details"),
                70, { width = 38, height = 9 }),
        }),
        system = page("system", tabs, {
            widget("system_identity", "key_value", t("widgets.system_identity", "Host & operating system"),
                100, { width = 44, height = 12 }),
            widget("system_kernel", "key_value", t("widgets.kernel", "Kernel & boot"),
                92, { width = 44, height = 10 }),
            widget("system_firmware", "key_value", t("widgets.firmware", "Hardware & firmware"),
                86, { width = 44, height = 10 }),
            widget("system_limits", "key_value", t("widgets.kernel_limits", "Limits & counters"),
                80, { width = 40, height = 10 }),
            widget("battery_bars", "bars", t("widgets.power_supplies", "Power supplies"),
                70, { width = 34, height = 6 }),
        }),
        insights = page("insights", tabs, {
            widget("collector_table", "table", t("widgets.collectors", "Collectors"),
                100, { width = 58, height = 12 }),
            widget("inspector_table", "table", t("widgets.inspectors", "Deep inspectors"),
                90, { width = 54, height = 10 }),
            widget("advice_list", "key_value", t("widgets.advice", "Findings & next steps"),
                80, { width = 44, height = 10 }),
        }),
    }
end

local function page_widgets(current_page)
    local widgets, order = {}, {}
    for _, node in ipairs(current_page.layout.children) do
        widgets[node.id] = node
        order[#order + 1] = node.id
    end
    return widgets, order
end

local function ordered_widgets(default_order, requested)
    local allowed, seen, result = {}, {}, {}
    for _, id in ipairs(default_order) do allowed[id] = true end
    for _, id in ipairs(requested or {}) do
        if allowed[id] and not seen[id] then
            seen[id] = true
            result[#result + 1] = id
        end
    end
    for _, id in ipairs(default_order) do
        if not seen[id] then result[#result + 1] = id end
    end
    return result
end

-- `suppressed` names widgets the current snapshot has nothing to say about —
-- a GPU meter on a machine with no GPU, a temperature card with no hwmon.
-- Leaving them in the tree gave an absent resource the same screen area as a
-- live one, which on a headless host is most of the page.  They stay in the
-- persisted layout and return the moment data appears.
local function ui_tree(tree, widgets, path, depth, branch, suppressed)
    path = path or "root"
    depth = depth or 0
    branch = branch or ""
    if tree.type == "leaf" then
        if suppressed and suppressed[tree.widget_id] then return nil end
        return assert(widgets[tree.widget_id])
    end
    local axes = {
        tiny = "column",
        ["narrow-tall"] = "column",
        standard = depth == 0 and "row" or "column",
        ["wide-short"] = depth <= 1 and "row" or "column",
        -- A balanced tree cannot express three equal columns exactly.  Split
        -- the left half once and stack the right half to preserve grouping,
        -- authored ratios and a maximum of three columns.
        ["wide-tall"] = (depth == 0 or (depth == 1 and branch == "1")) and "row" or "column",
    }
    local first = ui_tree(tree.children[1], widgets, path .. ".1", depth + 1,
        branch .. "1", suppressed)
    local second = ui_tree(tree.children[2], widgets, path .. ".2", depth + 1,
        branch .. "2", suppressed)
    -- A split with one surviving child collapses to that child; the removed
    -- side must not leave an empty half behind.
    if not first then return second end
    if not second then return first end
    return UI.Layout.split(
        tree.axis == "horizontal" and "row" or "column",
        tree.ratio,
        first,
        second,
        { id = "layout:" .. path, gap = tree.gap, reflow = true, axes = axes }
    )
end

--- Build a page's UI tree, hiding widgets the snapshot has nothing for.
--
-- Pruning leaves in place is not enough: the parent's split ratio still
-- reserves the removed widget's share, so dropping four of five cards handed
-- the survivor half the screen.  When anything is suppressed the surviving
-- order is rebalanced instead, which keeps the widgets in their authored
-- sequence while giving each a fair share.  Persisted ratios are untouched and
-- come back as soon as the data does.
local function page_layout(tree, widgets, page_id, suppressed, allowed_order)
    if not suppressed or not next(suppressed) then
        return assert(ui_tree(tree, widgets, page_id))
    end
    local order = assert(LayoutModel.to_order(tree, { allowed_widgets = allowed_order }))
    local surviving = {}
    for _, id in ipairs(order) do
        if not suppressed[id] then surviving[#surviving + 1] = id end
    end
    if #surviving == 0 then
        return assert(ui_tree(tree, widgets, page_id))
    end
    local rebalanced = LayoutModel.from_order(surviving, {
        allowed_widgets = allowed_order,
        axis = "horizontal",
        alternate_axes = true,
    })
    if not rebalanced then
        return assert(ui_tree(tree, widgets, page_id))
    end
    return assert(ui_tree(rebalanced, widgets, page_id))
end

local function tree_options(self, page_id)
    return { allowed_widgets = self.widget_orders[page_id] }
end

function Workspace.new(options)
    options = options or {}
    local tabs = {}
    for index, specification in ipairs(TAB_DEFINITIONS) do
        tabs[index] = {
            id = specification.id,
            label_id = specification.label_id,
            label = specification.label,
        }
    end
    local pages = build_pages(tabs, options.i18n)
    local widgets, widget_orders, layout_trees = {}, {}, {}
    for page_id, current_page in pairs(pages) do
        local default_order
        widgets[page_id], default_order = page_widgets(current_page)
        widget_orders[page_id] = default_order
        local tree = options.layout_trees and options.layout_trees[page_id]
        if tree then
            tree = assert(LayoutModel.clone(tree, { allowed_widgets = default_order }))
        else
            local order = ordered_widgets(default_order, options.orders and options.orders[page_id])
            tree = assert(LayoutModel.from_order(order, {
                allowed_widgets = default_order,
                axis = "horizontal",
                alternate_axes = true,
            }))
        end
        layout_trees[page_id] = tree
        current_page.layout = page_layout(tree, widgets[page_id], page_id, nil, default_order)
    end
    local active = options.active_tab and pages[options.active_tab] and options.active_tab or "overview"
    local self = setmetatable({
        tabs = tabs,
        pages = pages,
        active = active,
        focus = {},
        edit_mode = false,
        dirty = false,
        i18n = options.i18n,
        widgets = widgets,
        widget_orders = widget_orders,
        layout_trees = layout_trees,
        undo_stack = {},
        redo_stack = {},
        undo_limit = 50,
    }, Workspace)
    for id, tree in pairs(layout_trees) do
        local order = assert(LayoutModel.to_order(tree, tree_options(self, id)))
        self.focus[id] = order[1]
        self.undo_stack[id], self.redo_stack[id] = {}, {}
    end
    return self
end

function Workspace:active_index()
    for index, tab in ipairs(self.tabs) do
        if tab.id == self.active then
            return index
        end
    end
    return 1
end

function Workspace:select(value)
    if type(value) == "number" then
        value = self.tabs[((value - 1) % #self.tabs) + 1].id
    end
    if self.pages[value] then
        self.active = value
        return true
    end
    return false
end

function Workspace:cycle(delta)
    local index = ((self:active_index() - 1 + delta) % #self.tabs) + 1
    return self:select(index)
end

--- Move focus to the next widget, skipping any the responsive solver hid.
-- Without the filter, Tab could land on a widget that is not on screen, which
-- reads as the key doing nothing at all.
function Workspace:focus_cycle(delta, visible)
    local children = assert(LayoutModel.to_order(self.layout_trees[self.active], tree_options(self, self.active)))
    local candidates = children
    if type(visible) == "table" then
        local filtered = {}
        for _, id in ipairs(children) do
            if visible[id] == true then filtered[#filtered + 1] = id end
        end
        -- Falling back to the full order keeps Tab working during the first
        -- frame, before any placement has been solved.
        if #filtered > 0 then candidates = filtered end
    end
    local current = self.focus[self.active]
    local index = 0
    for candidate, id in ipairs(candidates) do
        if id == current then
            index = candidate
            break
        end
    end
    index = ((index - 1 + delta) % #candidates) + 1
    self.focus[self.active] = candidates[index]
    return self.focus[self.active]
end

function Workspace:_set_tree(page_id, tree, record_undo)
    local options = tree_options(self, page_id)
    local validated, validation_error = LayoutModel.clone(tree, options)
    if not validated then return false, validation_error end
    if record_undo ~= false then
        local stack = self.undo_stack[page_id]
        stack[#stack + 1] = assert(LayoutModel.clone(self.layout_trees[page_id], options))
        if #stack > self.undo_limit then table.remove(stack, 1) end
        self.redo_stack[page_id] = {}
    end
    self.layout_trees[page_id] = validated
    self.pages[page_id].layout = page_layout(validated, self.widgets[page_id], page_id,
        self.suppressed, self.widget_orders[page_id])
    self.dirty = true
    return true
end

function Workspace:move_focused_direction(direction)
    local positions = { left = -1, right = 1, above = -1, below = 1 }
    local delta = positions[direction]
    if not delta then return false, "invalid_direction" end
    local page_id = self.active
    local tree = self.layout_trees[page_id]
    local order = assert(LayoutModel.to_order(tree, tree_options(self, page_id)))
    local current, index = self.focus[page_id]
    for candidate, id in ipairs(order) do if id == current then index = candidate; break end end
    if not index then return false, "focused_widget_not_found" end
    local target_index = index + delta
    if target_index < 1 or target_index > #order then return false end
    local updated, update_error = LayoutModel.move(tree, current, order[target_index], {
        position = direction,
        allowed_widgets = self.widget_orders[page_id],
    })
    if not updated then return false, update_error end
    return self:_set_tree(page_id, updated)
end

function Workspace:move_focused(delta)
    return self:move_focused_direction(delta < 0 and "left" or "right")
end

function Workspace:adjust_focused_ratio(delta)
    local page_id = self.active
    local tree = self.layout_trees[page_id]
    local path, path_error = LayoutModel.find_path(tree, self.focus[page_id], tree_options(self, page_id))
    if not path then return false, path_error end
    if #path == 0 then return false, "focused_widget_has_no_split" end
    path[#path] = nil
    local updated, update_error = LayoutModel.adjust_ratio(tree, path, delta, {
        allowed_widgets = self.widget_orders[page_id],
        min_ratio = 0.1,
        max_ratio = 0.9,
    })
    if not updated then return false, update_error end
    return self:_set_tree(page_id, updated)
end

function Workspace:undo()
    local page_id = self.active
    local stack = self.undo_stack[page_id]
    if #stack == 0 then return false end
    local current = assert(LayoutModel.clone(self.layout_trees[page_id], tree_options(self, page_id)))
    local previous = table.remove(stack)
    self.redo_stack[page_id][#self.redo_stack[page_id] + 1] = current
    return self:_set_tree(page_id, previous, false)
end

function Workspace:redo()
    local page_id = self.active
    local stack = self.redo_stack[page_id]
    if #stack == 0 then return false end
    local current = assert(LayoutModel.clone(self.layout_trees[page_id], tree_options(self, page_id)))
    local next_tree = table.remove(stack)
    self.undo_stack[page_id][#self.undo_stack[page_id] + 1] = current
    return self:_set_tree(page_id, next_tree, false)
end

function Workspace:toggle_edit()
    self.edit_mode = not self.edit_mode
    return self.edit_mode
end

function Workspace:render(columns, rows, state)
    state = state or {}
    state.tabs = self.tabs
    state.active_tab = self.active
    state.focus_id = self.focus[self.active]
    if self.edit_mode then
        state.status = {
            message = translated(self.i18n, "layout.edit_message",
                "LAYOUT · Tab select · arrows split/move · [/] resize · u/U undo/redo · e finish"),
            warning = true,
            hints = {
                { key = "Tab", id = "actions.select", fallback = "Select" },
                { key = "Arrows", id = "actions.move", fallback = "Split/move" },
                { key = "[/]", id = "actions.resize", fallback = "Resize" },
                { key = "u/U", id = "actions.undo_redo", fallback = "Undo/redo" },
                { key = "e", id = "actions.done", fallback = "Done" },
                { key = "q", id = "actions.quit", fallback = "Quit" },
            },
        }
    end
    return self.pages[self.active]:render(columns, rows, state)
end

--- Declare which widgets have nothing to show in the current snapshot.
-- Returns true when the set changed, so the caller knows a relayout happened.
function Workspace:set_suppressed(ids)
    local changed = false
    local previous = self.suppressed or {}
    local next_set = {}
    for id, value in pairs(ids or {}) do
        if value == true then next_set[id] = true end
    end
    for id in pairs(next_set) do
        if not previous[id] then changed = true end
    end
    for id in pairs(previous) do
        if not next_set[id] then changed = true end
    end
    if not changed then return false end
    self.suppressed = next_set
    for page_id, tree in pairs(self.layout_trees) do
        self.pages[page_id].layout = page_layout(tree, self.widgets[page_id], page_id,
            next_set, self.widget_orders[page_id])
    end
    -- Focus must not stay on a widget that is no longer in the tree.
    for page_id in pairs(self.pages) do
        if next_set[self.focus[page_id]] then
            local order = assert(LayoutModel.to_order(self.layout_trees[page_id],
                tree_options(self, page_id)))
            for _, id in ipairs(order) do
                if not next_set[id] then
                    self.focus[page_id] = id
                    break
                end
            end
        end
    end
    return true
end

function Workspace:layout(columns, rows)
    local current_page = self.pages[self.active]
    return UI.Layout.solve(current_page.layout, columns, rows, {
        header_height = current_page.header and 1 or 0,
        footer_height = current_page.footer and 1 or 0,
        focus_id = self.focus[self.active],
    })
end

function Workspace:visible_widgets(columns, rows)
    local visible = {}
    for _, placement in ipairs(self:layout(columns, rows).placements) do
        visible[placement.id] = true
    end
    return visible
end

function Workspace:orders()
    local result = {}
    for page_id, tree in pairs(self.layout_trees) do
        result[page_id] = assert(LayoutModel.to_order(tree, tree_options(self, page_id)))
    end
    return result
end

function Workspace:trees()
    local result = {}
    for page_id, tree in pairs(self.layout_trees) do
        result[page_id] = assert(LayoutModel.clone(tree, tree_options(self, page_id)))
    end
    return result
end

function Workspace.default_orders()
    return Workspace.new():orders()
end

Workspace.tabs_definition = TAB_DEFINITIONS

return Workspace
