local UI = require("wtop.ui")
local LayoutModel = require("wtop.model.layout")

local Workspace = {}
Workspace.__index = Workspace

local function translated(i18n, id, fallback, variables)
    local value = i18n and i18n:t(id, variables)
    return value and value ~= id and value or fallback
end

local TAB_DEFINITIONS = {
    { id = "overview", label_id = "tabs.overview", label = "Overview" },
    { id = "processes", label_id = "tabs.processes", label = "Processes" },
    { id = "compute", label_id = "tabs.compute", label = "Compute" },
    { id = "storage", label_id = "tabs.storage", label = "Storage & I/O" },
    { id = "network", label_id = "tabs.network", label = "Network" },
    { id = "gpu", label_id = "tabs.gpu", label = "GPU" },
    { id = "workloads", label_id = "tabs.workloads", label = "Workloads" },
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
    local value_width = dimensions.value_width or (kind == "table" and 32 or 18)
    local value_height = dimensions.value_height
        or (kind == "table" and (bordered and 7 or 5) or (bordered and 4 or 2))
    return UI.Layout.widget({
        id = id,
        kind = kind,
        priority = priority or 0,
        min_width = dimensions.width or (kind == "table" and 48 or 26),
        min_height = dimensions.height or (kind == "table" and 10 or 6),
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
    return {
        overview = page("overview", tabs, {
            widget("cpu_overview", "metric", translated(i18n, "metrics.cpu", "CPU"), 100),
            widget("memory_overview", "metric", translated(i18n, "metrics.memory", "Memory"), 95),
            widget("pressure_overview", "metric", translated(i18n, "metrics.pressure", "PSI"), 80),
            widget("disk_overview", "metric", translated(i18n, "metrics.disk_io", "Disk I/O"), 75),
            widget("network_overview", "metric", translated(i18n, "metrics.network", "Network"), 70),
            widget("gpu_overview", "metric", translated(i18n, "metrics.gpu", "GPU"), 65),
            widget("frequency_overview", "metric", translated(i18n, "metrics.frequency", "Frequency"), 62),
            widget("temperature_overview", "metric", translated(i18n, "metrics.temperature", "Temperature"), 60),
            widget("power_overview", "metric", translated(i18n, "metrics.power", "Power"), 58),
        }),
        processes = page("processes", tabs, {
            widget("process_table", "table", translated(i18n, "widgets.processes_cpu", "Processes - CPU descending"),
                100, { width = 56, height = 12 }),
        }),
        compute = page("compute", tabs, {
            widget("cpu_total", "metric", translated(i18n, "widgets.cpu_utilization", "CPU utilization"), 100),
            widget("cpu_identity", "text", translated(i18n, "widgets.cpu_identity", "CPU identity"),
                96, { width = 42, height = 9 }),
            widget("load_summary", "text", translated(i18n, "widgets.load_average", "Load average"),
                80, { width = 22, height = 6 }),
            widget("memory_detail", "text", translated(i18n, "widgets.memory_detail", "Memory detail"),
                75, { width = 28, height = 7 }),
            widget("core_table", "table", translated(i18n, "widgets.logical_cpus", "Logical CPUs"),
                90, { width = 52, height = 12 }),
            widget("cpufreq_table", "table", translated(i18n, "widgets.frequency_policies", "Frequency policies"),
                70, { width = 58, height = 10 }),
            widget("sensor_table", "table", translated(i18n, "widgets.sensors", "Sensors"),
                65, { width = 56, height = 10 }),
            widget("power_table", "table", translated(i18n, "widgets.power_zones", "Power zones"),
                64, { width = 62, height = 10 }),
        }),
        storage = page("storage", tabs, {
            widget("storage_summary", "metric", translated(i18n, "widgets.storage_throughput", "Storage throughput"), 100),
            widget("disk_table", "table", translated(i18n, "widgets.block_devices", "Block devices"),
                95, { width = 56, height = 12 }),
            widget("smart_hint", "text", translated(i18n, "widgets.deep_health", "Deep health"),
                50, { width = 34, height = 6 }),
            widget("mount_table", "table", translated(i18n, "widgets.filesystems", "Filesystems & mounts"),
                85, { width = 62, height = 12 }),
        }),
        network = page("network", tabs, {
            widget("network_summary", "metric", translated(i18n, "widgets.network_throughput", "Network throughput"), 100),
            widget("network_table", "table", translated(i18n, "widgets.interfaces", "Interfaces"),
                95, { width = 54, height = 12 }),
            widget("connection_table", "table", translated(i18n, "widgets.connections", "Sockets & connections"),
                85, { width = 72, height = 14 }),
        }),
        gpu = page("gpu", tabs, {
            widget("gpu_summary", "metric", translated(i18n, "widgets.gpu_utilization", "GPU utilization"), 100),
            widget("gpu_table", "table", translated(i18n, "widgets.gpu_devices", "Graphics devices"),
                95, { width = 58, height = 12 }),
            widget("gpu_process_table", "table", translated(i18n, "widgets.gpu_processes", "GPU processes"),
                90, { width = 68, height = 14 }),
        }),
        workloads = page("workloads", tabs, {
            widget("workload_summary", "metric", translated(i18n, "widgets.workload_summary", "Workload pressure"),
                100),
            widget("workload_table", "table", translated(i18n, "widgets.cgroups", "cgroup v2 workloads"),
                95, { width = 66, height = 14 }),
            widget("workload_detail", "text", translated(i18n, "widgets.workload_detail", "Workload details"),
                70, { width = 38, height = 8 }),
        }),
        insights = page("insights", tabs, {
            widget("insight_summary", "text", translated(i18n, "widgets.capabilities", "Capabilities & inspectors"),
                100, { width = 42, height = 14 }),
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

local function ui_tree(tree, widgets, path, depth, branch)
    path = path or "root"
    depth = depth or 0
    branch = branch or ""
    if tree.type == "leaf" then return assert(widgets[tree.widget_id]) end
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
    return UI.Layout.split(
        tree.axis == "horizontal" and "row" or "column",
        tree.ratio,
        ui_tree(tree.children[1], widgets, path .. ".1", depth + 1, branch .. "1"),
        ui_tree(tree.children[2], widgets, path .. ".2", depth + 1, branch .. "2"),
        { id = "layout:" .. path, gap = tree.gap, reflow = true, axes = axes }
    )
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
        current_page.layout = ui_tree(tree, widgets[page_id], page_id)
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

function Workspace:focus_cycle(delta)
    local children = assert(LayoutModel.to_order(self.layout_trees[self.active], tree_options(self, self.active)))
    local current = self.focus[self.active]
    local index = 1
    for candidate, id in ipairs(children) do
        if id == current then
            index = candidate
            break
        end
    end
    index = ((index - 1 + delta) % #children) + 1
    self.focus[self.active] = children[index]
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
    self.pages[page_id].layout = ui_tree(validated, self.widgets[page_id], page_id)
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
