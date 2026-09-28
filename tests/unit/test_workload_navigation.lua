-- Workload-page navigation: collapsed subtrees hide their rows, the cursor
-- indexes the visible set, and the detail panel follows the selection.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

local function workload(id, parent_id, depth, name)
  return {
    id = id, parent_id = parent_id, depth = depth, name = name or id,
    path = "/sys/fs/cgroup" .. id,
    cpu = { utilization_percent = depth * 10 },
    memory = { current_bytes = depth * 1024 },
    io = { totals = { rates = { rbytes_per_second = 10, wbytes_per_second = 20 } } },
    pressure = { cpu = { some = { avg10 = 0.5 } } },
    processes = { count = depth },
    quality = "fresh",
  }
end

local snapshot = {
  cpu = {}, memory = {}, pressure = {}, disks = {}, network = {}, processes = {},
  cpu_frequency = {}, mounts = {}, connections = {}, quality = {}, sensors = {},
  gpus = {},
  workloads = {
    kind = "cgroup2",
    workloads = {
      workload("/", nil, 0, "root"),
      workload("/system", "/", 1),
      workload("/system/slice-a", "/system", 2),
      workload("/system/slice-a/deep", "/system/slice-a", 3),
      workload("/user", "/", 1),
    },
    summary = { root = { cpu_utilization_percent = 12 } },
  },
}
local engine = { history_values = function() return {} end }
local translator = assert(I18n.new({ locale = "en-US" }))

local function build(options)
  return ViewModel.build(engine, snapshot, translator, {}, "workloads",
    nil, nil, options)
end

-- 1. Plain rows: every node visible, children carry the expanded marker.
local plain = build({})
equal(#plain.workload_table.rows, 5, "all workload rows visible by default")
assert(plain.workload_table.rows[2].workload:find("▾", 1, true),
  "a node with children shows the expanded marker")
assert(plain.workload_table.rows[5].workload:find("·", 1, true),
  "a leaf shows the leaf marker")

-- 2. Collapsing a node hides its whole subtree, not just direct children.
local collapsed = build({ workload_collapsed = { ["/system"] = true } })
equal(#collapsed.workload_table.rows, 3, "the subtree is hidden entirely")
assert(collapsed.workload_table.rows[2].workload:find("▸", 1, true),
  "a collapsed node shows the collapsed marker")
equal(collapsed.workload_table.ids[3], "/user",
  "the visible id list skips the hidden subtree")

-- 3. The selection indexes the visible rows only.
local selected = build({ workload_collapsed = { ["/system"] = true },
  workload_selected = "/user" })
equal(selected.workload_table.selected, 3, "the cursor points at the visible row")

-- 4. The detail panel follows the selection instead of the root summary.
local detail = selected.workload_detail.entries
local labels = {}
for _, entry in ipairs(detail) do labels[#labels + 1] = tostring(entry.label) end
assert(#detail > 0 and detail[1].section == "Selection",
  "detail starts with a selection section")
local found_path = false
for _, entry in ipairs(detail) do
  if entry.value == "/sys/fs/cgroup/user" then found_path = true end
end
assert(found_path, "the detail panel shows the selected workload's path")

-- 5. Without a selection the root summary stays, as before.
local root_detail = build({}).workload_detail.entries
assert(#root_detail > 0, "root summary detail still renders without a selection")

print("ok: workload collapse and selection navigation")
