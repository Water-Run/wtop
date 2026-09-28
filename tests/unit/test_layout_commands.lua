-- Layout export/import: export writes the layout the TUI would load; import
-- validates before installing and keeps the previous file as the .bak backup.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local LayoutCommands = require("wtop.layout_commands")
local LayoutStore = require("wtop.layout_store")
local Workspace = require("wtop.workspace")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

local directory = os.getenv("TMPDIR") or "/tmp"
local base = directory .. "/wtop-layout-cmd-" .. tostring(os.time()) .. "-"
  .. tostring(math.random(1, 1000000))
local export_path = base .. "-export.yml"

-- 1. Export writes schema-v2 YAML that round-trips through the parser. A
-- dedicated (missing) layout path keeps the test independent of whatever
-- layout the developer's home currently holds.
local missing_layout = base .. "-no-such-layout.yml"
local exported, note = LayoutCommands.export(export_path, missing_layout)
assert(exported, "export failed: " .. tostring(note))
assert(tostring(note):find("default layout", 1, true),
  "export of a missing layout reports the default source")
local handle = assert(io.open(export_path, "rb"))
local content = handle:read("*a")
handle:close()
assert(content:find("schema_version: 2", 1, true), "export is not schema v2")
local orders, trees = LayoutStore.parse(content, Workspace.default_orders())
assert(orders and orders.overview[1], "exported layout does not round-trip")

-- 2. A path argument is required.
assert(select(2, LayoutCommands.export("")):find("output path"),
  "export without a path must be rejected")

-- 3. Import validates before installing: garbage never replaces the layout.
local garbage = base .. "-garbage.yml"
local writer = assert(io.open(garbage, "wb"))
writer:write("schema_version: [broken\n")
writer:close()
local imported, error_message = LayoutCommands.import(garbage)
equal(imported, nil, "invalid import is rejected")
assert(tostring(error_message):find("not a valid layout", 1, true),
  "import rejection explains the problem")

-- 4. Importing a valid file installs it at the given target; without native
-- atomic writing the install explains itself instead of half-writing.
local valid = base .. "-valid.yml"
local target = base .. "-installed.yml"
writer = assert(io.open(valid, "wb"))
writer:write(content)
writer:close()
local native = require("wtop.native")
local accepted, accepted_note = LayoutCommands.import(valid, target)
if native.available then
  assert(accepted, "import failed: " .. tostring(accepted_note))
  local reader = assert(io.open(target, "rb"))
  local installed_content = reader:read("*a")
  reader:close()
  assert(installed_content:find("schema_version: 2", 1, true),
    "installed layout lost its schema version")
else
  assert(not accepted and tostring(accepted_note):find("native"),
    "without the native writer the install must decline cleanly")
end

os.remove(export_path)
os.remove(garbage)
os.remove(valid)
os.remove(target)

print("ok: layout export/import commands")
