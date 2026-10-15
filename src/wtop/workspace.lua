local UI = require("wtop.ui")
local LayoutModel = require("wtop.model.layout")

local Workspace = {}
Workspace.__index = Workspace

-- Sixteen arrangements is far more than anyone keeps, and the bound stops
-- a generated or hand-edited file from becoming unbounded session state.
local MAX_WORKSPACES = 16

local function clone_trees(trees, orders, seeds)
    local copy = {}
    for page, order in pairs(orders) do
        local tree = trees and trees[page]
        copy[page] = tree and assert(LayoutModel.clone(tree, { allowed_widgets = order }))
            or assert(LayoutModel.from_order(seeds and seeds[page]
                and { seeds[page] } or order, {
                allowed_widgets = order, axis = "horizontal", alternate_axes = true,
            }))
    end
    return copy
end

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
local TAB_BY_ID = {}
for _, definition in ipairs(TAB_DEFINITIONS) do TAB_BY_ID[definition.id] = definition end
local MAX_CUSTOM_PAGES = 8

local function custom_definitions(value)
    local result, seen = {}, {}
    for _, definition in ipairs(type(value) == "table" and value or {}) do
        if type(definition) ~= "table" or type(definition.id) ~= "string"
            or not definition.id:match("^custom[1-8]$") or seen[definition.id]
            or type(definition.name) ~= "string" or definition.name == ""
            or #definition.name > 64 or not utf8.len(definition.name)
            or definition.name:find("[%c]")
            or type(definition.seed_widget) ~= "string" then
            error("invalid custom page definition", 3)
        end
        seen[definition.id] = true
        result[#result + 1] = { id = definition.id, name = definition.name,
            seed_widget = definition.seed_widget }
    end
    if #result > MAX_CUSTOM_PAGES then error("too many custom pages", 3) end
    return result
end

local function default_tab_ids()
    local ids = {}
    for index, definition in ipairs(TAB_DEFINITIONS) do ids[index] = definition.id end
    return ids
end

local function normalized_tab_ids(requested, definitions)
    local available = {}
    for id, definition in pairs(TAB_BY_ID) do available[id] = definition end
    local defaults = default_tab_ids()
    for _, definition in ipairs(definitions) do
        available[definition.id] = { id = definition.id, label = definition.name }
        defaults[#defaults + 1] = definition.id
    end
    if type(requested) ~= "table" or #requested == 0 then return defaults end
    local ids, seen = {}, {}
    for _, id in ipairs(requested) do
        if not available[id] or seen[id] then return defaults end
        seen[id] = true
        ids[#ids + 1] = id
    end
    return ids
end

local function tab(id, definitions)
    local specification = assert(definitions[id])
    return { id = id, label_id = specification.label_id, label = specification.label }
end

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
            widget("thermal_throttle_table", "table",
                t("widgets.thermal_throttle", "Thermal throttling per CPU"),
                68, { width = 60, height = 10 }),
            widget("cpuidle_table", "table", t("widgets.cpuidle", "CPU idle states"),
                67, { width = 62, height = 10 }),
            widget("sensor_table", "table", t("widgets.sensors", "Sensors"),
                65, { width = 56, height = 10 }),
            widget("power_table", "table", t("widgets.power_zones", "Power zones"),
                85, { width = 96, height = 12 }),
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
            widget("numa_table", "table", t("numa.nodes", "NUMA nodes"),
                76, { width = 58, height = 10 }),
            widget("dimm_table", "table", t("memory_hw.title", "Memory devices"),
                75, { width = 64, height = 10 }),
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
            widget("network_softnet", "key_value", t("widgets.network_softnet", "Receive backlog"),
                72, { width = 38, height = 9 }),
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
            widget("system_devices", "table", t("widgets.system_devices", "Hardware devices"),
                60, { width = 72, height = 14 }),
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

local function combined_widgets(pages)
    local widgets, order, origins = {}, {}, {}
    for _, definition in ipairs(TAB_DEFINITIONS) do
        for _, node in ipairs(pages[definition.id].layout.children) do
            if widgets[node.id] then error("duplicate widget id: " .. node.id, 2) end
            widgets[node.id] = node
            origins[node.id] = definition.id
            order[#order + 1] = node.id
        end
    end
    return widgets, order, origins
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
    local custom_pages = custom_definitions(options.custom_pages)
    local definitions, custom_by_id, custom_seeds = {}, {}, {}
    for id, definition in pairs(TAB_BY_ID) do definitions[id] = definition end
    for _, definition in ipairs(custom_pages) do
        definitions[definition.id] = { id = definition.id, label = definition.name }
        custom_by_id[definition.id] = definition
        custom_seeds[definition.id] = definition.seed_widget
    end
    local tabs = {}
    for index, id in ipairs(normalized_tab_ids(options.tab_order, custom_pages)) do
        tabs[index] = tab(id, definitions)
    end
    local pages = build_pages(tabs, options.i18n)
    local all_widgets, all_widget_order, widget_origins = combined_widgets(pages)
    for _, definition in ipairs(custom_pages) do
        local seed = all_widgets[definition.seed_widget]
        if not seed then error("unknown custom page seed widget", 2) end
        pages[definition.id] = page(definition.id, tabs, { seed })
    end
    local widgets, widget_orders, layout_trees = {}, {}, {}
    for page_id, current_page in pairs(pages) do
        local default_order
        if custom_by_id[page_id] then
            widgets[page_id], default_order = all_widgets, all_widget_order
        else
            widgets[page_id], default_order = page_widgets(current_page)
        end
        widget_orders[page_id] = default_order
        local tree = options.layout_trees and options.layout_trees[page_id]
        if tree then
            tree = assert(LayoutModel.clone(tree, { allowed_widgets = default_order }))
        else
            local order = custom_by_id[page_id]
                and (options.orders and options.orders[page_id]
                    or { custom_by_id[page_id].seed_widget })
                or ordered_widgets(default_order, options.orders and options.orders[page_id])
            tree = assert(LayoutModel.from_order(order, {
                allowed_widgets = default_order,
                axis = "horizontal",
                alternate_axes = true,
            }))
        end
        layout_trees[page_id] = tree
        current_page.layout = page_layout(tree, widgets[page_id], page_id, nil, default_order)
    end
    -- A layout file may carry several named workspaces.  The trees the caller
    -- handed over are the live workspace; the rest are kept aside and become
    -- live only when the user switches to them.
    local workspaces = {}
    if type(options.workspaces) == "table" then
        for name, stored in pairs(options.workspaces) do
            if type(name) == "string" and type(stored) == "table" then
                workspaces[name] = clone_trees(stored, widget_orders, custom_seeds)
            end
        end
    end
    local workspace_name = options.workspace
    if type(workspace_name) ~= "string" or not workspaces[workspace_name] then
        local names = {}
        for name in pairs(workspaces) do names[#names + 1] = name end
        table.sort(names)
        workspace_name = names[1]
    end
    if workspace_name then
        -- The store already validated the active workspace, so its trees are
        -- the ones the pages were built from; re-cloning here would be wasted
        -- work and could only disagree with them.
        workspaces[workspace_name] = clone_trees(workspaces[workspace_name],
            widget_orders, custom_seeds)
    end

    local active = tabs[1].id
    for _, entry in ipairs(tabs) do
        if entry.id == options.active_tab then active = entry.id break end
    end
    local self = setmetatable({
        tabs = tabs,
        tab_definitions = definitions,
        custom_pages = custom_pages,
        custom_by_id = custom_by_id,
        custom_seeds = custom_seeds,
        all_widgets = all_widgets,
        all_widget_order = all_widget_order,
        widget_origins = widget_origins,
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
        workspaces = workspaces,
        workspace = workspace_name,
    }, Workspace)
    for id, tree in pairs(layout_trees) do
        local order = assert(LayoutModel.to_order(tree, tree_options(self, id)))
        self.focus[id] = order[1]
        self.undo_stack[id], self.redo_stack[id] = {}, {}
    end
    return self
end

--- The workspaces this session knows about, plus which one is live.
-- A workspace is a name and a complete set of per-page trees.  `layout.yml`
-- may carry several; the live one is what the pages render from, and saving
-- captures the current trees under a name rather than overwriting the only
-- arrangement the user has.
function Workspace:workspace_names()
    local names = {}
    for name in pairs(self.workspaces or {}) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- A workspace name is trimmed and then checked, and the two ways it can fail
-- stay separate: text that is not text, and text that is not a usable name.
-- Saving and renaming go through the same check, because a name the manager
-- would refuse to create must also be one it will not set -- otherwise the
-- refusal would only be discoverable after the rename had half-applied.
--- A workspace name is a label the user types, not an identifier, so the rule
--- is stated as what has to stay out rather than as what has to be in -- and it
--- is stated once, in the layout model, because this module validates a name on
--- the way into a session and the layout store validates the same name on the
--- way back out of a file.  Two copies of that rule would eventually disagree,
--- and the disagreement would cost a user their whole arrangement.  See
--- `LayoutModel.workspace_name_ok` for why a well-formed UTF-8 sequence is a name
--- character and a bare 0x9b is not.
local function checked_workspace_name(name)
    if type(name) ~= "string" then return nil, "workspace_name_must_be_text" end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if #name < 1 or #name > LayoutModel.MAX_WORKSPACE_NAME_BYTES then
        return nil, "workspace_name_length"
    end
    if not LayoutModel.workspace_name_ok(name) then
        return nil, "invalid_workspace_name"
    end
    return name
end

--- Capture the current trees under a name and make that name live.
-- Overwriting an existing name is a rename of that workspace, not a second
-- copy of it: two entries with the same name would make "which one is active"
-- unanswerable.
function Workspace:save_workspace(name)
    local checked, name_error = checked_workspace_name(name)
    if checked == nil then return false, name_error end
    name = checked
    self.workspaces = self.workspaces or {}
    if self.workspaces[name] == nil and self:workspace_count() >= MAX_WORKSPACES then
        return false, "workspace_limit_reached"
    end
    self.workspaces[name] = clone_trees(self.layout_trees, self.widget_orders,
        self.custom_seeds)
    return self:_activate_workspace(name)
end

--- Give a saved workspace a different name.
--
-- A rename moves the stored trees from one key to another and does nothing
-- else: it does not re-save the live trees over the target, and it does not
-- switch to the workspace it renamed.  The layout saved under the old name is
-- the layout the new name now holds, which is the entire point -- and the
-- reason it cannot be expressed as "save under the new name, then delete the
-- old one", since that pair would discard every edit made since the workspace
-- was last saved.
--
-- A name already in use is refused rather than merged.  Two arrangements under
-- one name make "which one is live" unanswerable, and whichever lost would be
-- gone with no way back.
function Workspace:rename_workspace(from, to)
    if not (self.workspaces and self.workspaces[from]) then
        return false, "unknown_workspace"
    end
    local checked, name_error = checked_workspace_name(to)
    if checked == nil then return false, name_error end
    -- Renaming to the name it already carries has nothing to do, and the move
    -- below would write the key and then delete it.  Reported as the success it
    -- is: the workspace the caller asked for does exist under that name.  No
    -- dirty flag, because nothing about the file would differ.
    if checked == from then return true end
    if self.workspaces[checked] ~= nil then return false, "workspace_name_taken" end
    self.workspaces[checked] = self.workspaces[from]
    self.workspaces[from] = nil
    if self.workspace == from then self.workspace = checked end
    self.dirty = true
    return true
end

function Workspace:workspace_count()
    local count = 0
    for _ in pairs(self.workspaces or {}) do count = count + 1 end
    return count
end

--- Make a saved workspace the live one.
-- A workspace that does not exist is not created here: switching is a
-- navigation, and silently inventing a layout under a typed name would make
-- the list grow on every mistyped Enter.
function Workspace:switch_workspace(name)
    local stored = self.workspaces and self.workspaces[name]
    if not stored then return false, "unknown_workspace" end
    return self:_activate_workspace(name)
end

function Workspace:_activate_workspace(name)
    local stored = self.workspaces[name]
    for page, order in pairs(self.widget_orders) do
        local tree = stored[page]
        if tree then
            tree = assert(LayoutModel.clone(tree, { allowed_widgets = order }))
        else
            local initial = self.custom_seeds[page]
                and { self.custom_seeds[page] } or order
            tree = assert(LayoutModel.from_order(initial, {
                allowed_widgets = order, axis = "horizontal", alternate_axes = true,
            }))
        end
        self.layout_trees[page] = tree
        self.pages[page].layout = page_layout(tree, self.widgets[page], page,
            self.suppressed, order)
        -- Focus followed the old tree; the same widget may not exist here.
        local placed = assert(LayoutModel.to_order(tree, tree_options(self, page)))
        local found = false
        for _, id in ipairs(placed) do
            if id == self.focus[page] then found = true break end
        end
        if not found then self.focus[page] = placed[1] end
        -- The undo history describes edits to the tree that was live, so it
        -- would otherwise undo a workspace switch into a layout that is gone.
        self.undo_stack[page], self.redo_stack[page] = {}, {}
    end
    self.workspace = name
    self.dirty = true
    return true
end

--- Remove a saved workspace.  The last one is kept, because a workspace
-- manager with nothing in it cannot show what the file would load as.
function Workspace:delete_workspace(name)
    if not (self.workspaces and self.workspaces[name]) then
        return false, "unknown_workspace"
    end
    if self:workspace_count() <= 1 then return false, "last_workspace" end
    self.workspaces[name] = nil
    if self.workspace == name then
        local replacement = self:workspace_names()[1]
        self:_activate_workspace(replacement)
    end
    self.dirty = true
    return true
end

function Workspace:active_index()
    for index, tab in ipairs(self.tabs) do
        if tab.id == self.active then
            return index
        end
    end
    return 1
end

function Workspace:tab_ids()
    local ids = {}
    for index, entry in ipairs(self.tabs) do ids[index] = entry.id end
    return ids
end

function Workspace:content_page()
    if not self.custom_by_id[self.active] then return self.active end
    return self.widget_origins[self.focus[self.active]] or "overview"
end

function Workspace:custom_tab_order()
    local ids, defaults = self:tab_ids(), default_tab_ids()
    if #ids == #defaults then
        local same = true
        for index, id in ipairs(ids) do if id ~= defaults[index] then same = false break end end
        if same then return nil end
    end
    return ids
end

function Workspace:tab_entries()
    local entries, visible = {}, {}
    for index, entry in ipairs(self.tabs) do
        visible[entry.id] = true
        entries[#entries + 1] = { id = entry.id, label_id = entry.label_id,
            label = entry.label, visible = true, position = index }
    end
    for _, definition in ipairs(TAB_DEFINITIONS) do
        if not visible[definition.id] then
            entries[#entries + 1] = { id = definition.id,
                label_id = definition.label_id, label = definition.label, visible = false }
        end
    end
    for _, definition in ipairs(self.custom_pages) do
        if not visible[definition.id] then
            entries[#entries + 1] = { id = definition.id,
                label = definition.name, visible = false, custom = true }
        end
    end
    for _, entry in ipairs(entries) do
        entry.custom = self.custom_by_id[entry.id] ~= nil
    end
    return entries
end

function Workspace:show_tab(id)
    if not self.tab_definitions[id] then return false, "unknown_tab" end
    for _, entry in ipairs(self.tabs) do
        if entry.id == id then return false, "tab_already_visible" end
    end
    table.insert(self.tabs, self:active_index() + 1,
        tab(id, self.tab_definitions))
    self.dirty = true
    return true
end

function Workspace:custom_page_definitions()
    local result = {}
    for index, definition in ipairs(self.custom_pages) do
        result[index] = { id = definition.id, name = definition.name,
            seed_widget = definition.seed_widget }
    end
    return #result > 0 and result or nil
end

function Workspace:new_custom_page(seed_widget, name)
    if #self.custom_pages >= MAX_CUSTOM_PAGES then return false, "custom_page_limit" end
    seed_widget = seed_widget or self.focus[self.active]
    if not self.all_widgets[seed_widget] then return false, "unknown_widget" end
    local number
    for candidate = 1, MAX_CUSTOM_PAGES do
        if not self.custom_by_id["custom" .. candidate] then number = candidate break end
    end
    local id = "custom" .. number
    name = name or translated(self.i18n, "tabs.custom_name",
        "Custom {index}", { index = tostring(number) })
    if type(name) ~= "string" or name == "" or #name > 64 or not utf8.len(name)
        or name:find("[%c]") then
        return false, "invalid_custom_page_name"
    end
    local definition = { id = id, name = name, seed_widget = seed_widget }
    self.custom_pages[#self.custom_pages + 1] = definition
    self.custom_by_id[id], self.custom_seeds[id] = definition, seed_widget
    self.tab_definitions[id] = { id = id, label = name }
    local tree = assert(LayoutModel.from_order({ seed_widget },
        { allowed_widgets = self.all_widget_order }))
    self.pages[id] = page(id, self.tabs, { self.all_widgets[seed_widget] })
    self.widgets[id], self.widget_orders[id], self.layout_trees[id] =
        self.all_widgets, self.all_widget_order, tree
    self.pages[id].layout = page_layout(tree, self.all_widgets, id,
        self.suppressed, self.all_widget_order)
    self.focus[id], self.undo_stack[id], self.redo_stack[id] = seed_widget, {}, {}
    for _, trees in pairs(self.workspaces) do
        trees[id] = assert(LayoutModel.clone(tree,
            { allowed_widgets = self.all_widget_order }))
    end
    table.insert(self.tabs, self:active_index() + 1,
        tab(id, self.tab_definitions))
    self.active, self.dirty = id, true
    return true, id
end

function Workspace:duplicate_page(source_id)
    local source_tree = self.layout_trees[source_id]
    local source_spec = self.tab_definitions[source_id]
    if not source_tree or not source_spec then return false, "unknown_tab" end
    local source_order = assert(LayoutModel.to_order(source_tree,
        tree_options(self, source_id)))
    local label = translated(self.i18n, source_spec.label_id,
        source_spec.label)
    local name = translated(self.i18n, "tabs.copy_name", "Copy of {name}",
        { name = label })
    if #name > 64 then name = nil end
    local source_focus = self.focus[source_id]
    local created, id_or_reason = self:new_custom_page(source_order[1], name)
    if not created then return false, id_or_reason end
    local id = id_or_reason
    local clone_options = { allowed_widgets = self.all_widget_order }
    self.layout_trees[id] = assert(LayoutModel.clone(source_tree, clone_options))
    self.pages[id].layout = page_layout(self.layout_trees[id], self.all_widgets,
        id, self.suppressed, self.all_widget_order)
    for _, widget_id in ipairs(source_order) do
        if widget_id == source_focus then self.focus[id] = widget_id break end
    end
    for name, trees in pairs(self.workspaces) do
        local source = name == self.workspace and source_tree or trees[source_id]
        if source then trees[id] = assert(LayoutModel.clone(source, clone_options)) end
    end
    return true, id
end

function Workspace:rename_custom_page(id, name)
    local definition = self.custom_by_id[id]
    if not definition then return false, "not_custom_page" end
    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or nil
    if type(name) ~= "string" or name == "" or #name > 64 or not utf8.len(name)
        or name:find("[%c]") then
        return false, "invalid_custom_page_name"
    end
    definition.name = name
    self.tab_definitions[id].label = name
    for _, entry in ipairs(self.tabs) do if entry.id == id then entry.label = name end end
    self.dirty = true
    return true
end

function Workspace:remove_custom_page(id)
    if not self.custom_by_id[id] then return false, "not_custom_page" end
    if #self.tabs == 1 and self.tabs[1].id == id then return false, "last_tab" end
    for index, entry in ipairs(self.tabs) do
        if entry.id == id then
            table.remove(self.tabs, index)
            if self.active == id then
                self.active = self.tabs[math.min(index, #self.tabs)].id
            end
            break
        end
    end
    for index, definition in ipairs(self.custom_pages) do
        if definition.id == id then table.remove(self.custom_pages, index) break end
    end
    self.custom_by_id[id], self.custom_seeds[id], self.tab_definitions[id] = nil, nil, nil
    self.pages[id], self.widgets[id], self.widget_orders[id], self.layout_trees[id] =
        nil, nil, nil, nil
    self.focus[id], self.undo_stack[id], self.redo_stack[id] = nil, nil, nil
    for _, trees in pairs(self.workspaces) do trees[id] = nil end
    self.dirty = true
    return true
end

function Workspace:hide_tab(id)
    if #self.tabs <= 1 then return false, "last_tab" end
    for index, entry in ipairs(self.tabs) do
        if entry.id == id then
            table.remove(self.tabs, index)
            if self.active == id then
                self.active = self.tabs[math.min(index, #self.tabs)].id
            end
            self.dirty = true
            return true
        end
    end
    return false, "tab_hidden"
end

function Workspace:move_tab(id, direction)
    for index, entry in ipairs(self.tabs) do
        if entry.id == id then
            local target = index + (direction < 0 and -1 or 1)
            if target < 1 or target > #self.tabs then return false, "tab_edge" end
            self.tabs[index], self.tabs[target] = self.tabs[target], self.tabs[index]
            self.dirty = true
            return true
        end
    end
    return false, "tab_hidden"
end

function Workspace:select(value)
    if type(value) == "number" then
        value = self.tabs[value] and self.tabs[value].id
    end
    for _, entry in ipairs(self.tabs) do
        if entry.id == value then
            self.active = value
            return true
        end
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
    -- Widgets can enter and leave the tree, so focus can be left pointing at a
    -- widget that is no longer there -- undoing a removal is the obvious way
    -- to get there, and every later edit key would then fail on a widget the
    -- user cannot see.  Re-anchor on the first surviving widget instead.
    local placed = LayoutModel.to_order(validated, options)
    if placed then
        local focused = false
        for _, id in ipairs(placed) do
            if id == self.focus[page_id] then focused = true break end
        end
        if not focused then self.focus[page_id] = placed[1] end
    end
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

--- The widgets a page can still place.
-- Every widget a page defines is placeable and the default layout places all
-- of them, so the palette is the page's own widget list minus what the current
-- tree already holds.  Working from the page palette -- rather than a global
-- widget list -- is what keeps the view model and collector visibility in step
-- with what the page can actually render.
function Workspace:palette()
    local page_id = self.active
    local placed = LayoutModel.to_order(self.layout_trees[page_id], tree_options(self, page_id))
    if not placed then return {} end
    local present = {}
    for _, id in ipairs(placed) do present[id] = true end
    local available = {}
    for _, id in ipairs(self.widget_orders[page_id]) do
        if not present[id] then
            local spec = self.widgets[page_id][id]
            available[#available + 1] = {
                id = id,
                title = (spec and spec.panel_title) or id,
                kind = (spec and spec.kind) or "panel",
            }
        end
    end
    return available
end

-- Layout refusals are collapsed into a small, stable set here.  The model
-- reports codes like "widget_not_found:memory_total" that embed the widget id;
-- those cannot be catalogued per widget, and the interface only ever needs to
-- say why the edit did not happen.
local function layout_refusal(code)
    if type(code) ~= "string" then return "layout_rejected" end
    if code == "cannot_remove_last_widget" then return code end
    if code:match("^focused_widget_not_found")
        or code:match("^widget_not_found")
        or code:match("^invalid_widget_id")
        or code:match("^invalid_target_widget")
    then
        return "widget_not_in_page"
    end
    if code:match("^duplicate_widget") then return "widget_already_placed" end
    if code:match("^unknown_widget") then return "widget_not_in_page" end
    return "layout_rejected"
end

local function focus_index(order, widget_id)
    for index, id in ipairs(order) do
        if id == widget_id then return index end
    end
end

--- Place a palette widget next to the focused one.
-- Position is "after" by default; the caller chooses the side so a picker can
-- offer both without the model inventing a direction.
function Workspace:add_focused_widget(widget_id, position)
    local page_id = self.active
    local updated, update_error = LayoutModel.insert(self.layout_trees[page_id],
        self.focus[page_id], widget_id, {
            position = position == "before" and "before" or "after",
            allowed_widgets = self.widget_orders[page_id],
        })
    if not updated then return false, layout_refusal(update_error) end
    local applied, apply_error = self:_set_tree(page_id, updated)
    if not applied then return false, layout_refusal(apply_error) end
    -- Focus the widget that was just placed, so add-then-resize is one flow
    -- instead of a hunt through the page.
    self.focus[page_id] = widget_id
    return true
end

--- Take the focused widget out of the layout, leaving it in the page palette.
function Workspace:remove_focused_widget()
    local page_id = self.active
    local options = tree_options(self, page_id)
    local order = LayoutModel.to_order(self.layout_trees[page_id], options)
    if not order then return false, "layout_rejected" end
    local focus = self.focus[page_id]
    local index = focus_index(order, focus)
    if not index then return false, "widget_not_in_page" end
    local updated, update_error = LayoutModel.remove(self.layout_trees[page_id], focus, {
        allowed_widgets = self.widget_orders[page_id],
    })
    if not updated then return false, layout_refusal(update_error) end
    local applied, apply_error = self:_set_tree(page_id, updated)
    if not applied then return false, layout_refusal(apply_error) end
    -- Focus follows the neighbour that inherited the removed widget's place.
    local remaining = LayoutModel.to_order(self.layout_trees[page_id], options)
    if remaining then
        self.focus[page_id] = remaining[index] or remaining[index - 1] or remaining[1]
    end
    return true
end

--- Swap the focused widget for a palette widget, keeping its position.
-- Removing first and re-inserting at the old index keeps the replacement in
-- the same visual slot; appending it to the end would silently reorder a page
-- the user just arranged.
function Workspace:replace_focused_widget(widget_id)
    local page_id = self.active
    local options = tree_options(self, page_id)
    local focus = self.focus[page_id]
    if widget_id == focus then return false, "widget_already_placed" end
    local order = LayoutModel.to_order(self.layout_trees[page_id], options)
    if not order then return false, "layout_rejected" end
    local index = focus_index(order, focus)
    if not index then return false, "widget_not_in_page" end
    local reduced, remove_error = LayoutModel.remove(self.layout_trees[page_id], focus, {
        allowed_widgets = self.widget_orders[page_id],
    })
    if not reduced then return false, layout_refusal(remove_error) end
    local reduced_order = LayoutModel.to_order(reduced, options)
    local neighbour = reduced_order and (reduced_order[index] or reduced_order[index - 1])
    if not neighbour then return false, "layout_rejected" end
    local updated, update_error = LayoutModel.insert(reduced, neighbour, widget_id, {
        -- The removed widget's slot collapses into its successor, so the
        -- replacement goes back in front of it to hold the original position.
        position = index > 1 and "before" or "after",
        allowed_widgets = self.widget_orders[page_id],
    })
    if not updated then return false, layout_refusal(update_error) end
    local applied, apply_error = self:_set_tree(page_id, updated)
    if not applied then return false, layout_refusal(apply_error) end
    self.focus[page_id] = widget_id
    return true
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
        -- The edit banner is the footer's resting state, but the banner owns
        -- only that.  A transient message outranks it, because the workspace
        -- manager is reachable *only* in edit mode and used to swallow every
        -- confirmation it produced -- a deleted, switched or renamed workspace
        -- all happened with nothing on screen to say so.  Everything else the
        -- caller put in the status (a persisted-layout error, the privilege
        -- marker, the process filter) is carried through rather than dropped.
        --
        -- The banner returns when a message is no longer set, which is what
        -- happens when edit mode ends: the footer goes back to the page's own
        -- hints and the transient message leaves with it.
        local incoming = state.status or {}
        state.status = {
            message = incoming.message or translated(self.i18n, "layout.edit_message",
                "LAYOUT · b Tabs · Tab select · arrows split/move · [/] resize · u/U undo/redo · e finish"),
            error = incoming.error,
            privilege = incoming.privilege,
            filter = incoming.filter,
            data_age = incoming.data_age,
            -- The banner is styled as a warning because it is a mode, not a
            -- problem; a message that replaced it is neither.
            warning = incoming.message == nil,
            hints = {
                { key = "Tab", id = "actions.select", fallback = "Select" },
                { key = "Arrows", id = "actions.move", fallback = "Split/move" },
                { key = "[/]", id = "actions.resize", fallback = "Resize" },
                { key = "u/U", id = "actions.undo_redo", fallback = "Undo/redo" },
                { key = "b", id = "actions.manage_tabs", fallback = "Tabs" },
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

--- The full workspace set, for persistence.  Exposed as a copy so a caller
-- cannot hand the store a table it will keep mutating.  Not named
-- `workspaces()`: that would be shadowed by the instance field of the same
-- name, which holds the set itself.
function Workspace:saved_workspaces()
    local copy = {}
    for name, trees in pairs(self.workspaces or {}) do
        copy[name] = clone_trees(name == self.workspace and self.layout_trees or trees,
            self.widget_orders, self.custom_seeds)
    end
    return copy
end

--- The widgets a focused widget can be dropped onto.
-- The widget itself is excluded: dropping a widget onto itself is what the
-- model already answers with an unchanged tree, and offering it in a list
-- would spend a row to do nothing.
function Workspace:move_targets()
    local placed = LayoutModel.to_order(self.layout_trees[self.active],
        tree_options(self, self.active))
    if not placed then return {} end
    local targets = {}
    for _, id in ipairs(placed) do
        if id ~= self.focus[self.active] then targets[#targets + 1] = id end
    end
    return targets
end

--- Drop the focused widget onto a target, before or after it.
-- This is the same model call the arrow keys make, with the target and the side
-- chosen instead of implied by the neighbour: the arrows can only step one
-- place, which is not a drop.
function Workspace:move_focused_to(target, position)
    if type(target) ~= "string" or target == "" then
        return false, "invalid_target_widget"
    end
    if position ~= "before" and position ~= "after" then
        return false, "invalid_position"
    end
    local page_id = self.active
    local updated, update_error = LayoutModel.move(
        self.layout_trees[page_id], self.focus[page_id], target, {
            position = position,
            allowed_widgets = self.widget_orders[page_id],
        })
    -- The refusal mapping is not optional here.  `add`, `remove` and `replace`
    -- all pass their inner error through `layout_refusal`, and this one did not:
    -- it returned the layout model's own string.  Measured, that string is
    -- sometimes built by concatenation -- `Layout.move` answers a target that is
    -- not on the page with `"widget_not_found:" .. target_widget` -- and this
    -- method's error is what `tui.lua` formats into the message id
    -- `"reason." .. tostring(move_error)`, so a user who dropped a widget on a
    -- stale target was shown `widget_not_found:not_a_widget_on_this_page` in
    -- their status line, in every language, because no catalogue can hold a key
    -- with a colon in it.  That is what `layout_refusal` exists to prevent: it
    -- collapses `^widget_not_found` and its siblings into `widget_not_in_page`,
    -- and it had been applied to three of the four operations that can produce
    -- one.
    if not updated then return false, layout_refusal(update_error) end
    local applied, apply_error = self:_set_tree(page_id, updated)
    if not applied then return false, layout_refusal(apply_error) end
    -- Focus needs no help here: the widget was moved, not removed, so it is
    -- still in the new order and _set_tree keeps pointing at it.  Following the
    -- drop target instead would silently switch the user to editing a panel
    -- they did not pick up.
    return true
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

function Workspace.default_orders(custom_pages)
    local pages = build_pages({}, nil)
    local result = {}
    for _, definition in ipairs(TAB_DEFINITIONS) do
        local _, order = page_widgets(pages[definition.id])
        result[definition.id] = order
    end
    local all_widgets, all_order = combined_widgets(pages)
    for _, definition in ipairs(custom_definitions(custom_pages)) do
        if not all_widgets[definition.seed_widget] then
            error("unknown custom page seed widget", 2)
        end
        local order = {}
        for index, id in ipairs(all_order) do order[index] = id end
        result[definition.id] = order
    end
    return result
end

Workspace.tabs_definition = TAB_DEFINITIONS
Workspace.default_tab_ids = default_tab_ids

return Workspace
