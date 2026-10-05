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

-- 5. Migration: a v1 file is rewritten in the current form, keeping the old
-- bytes as the one-generation backup. The v1 body uses real widget ids so the
-- upgrade is of a file the product itself could have written.
local function write_file(path, content)
  local handle = assert(io.open(path, "wb"))
  assert(handle:write(content))
  assert(handle:close())
end
local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local content = handle:read("*a")
  handle:close()
  return content
end
local v1_path = base .. "-v1.yml"
local v1_body = [[schema_version: 1
pages:
  compute:
    - core_bars
    - cpu_total
]]
write_file(v1_path, v1_body)
local native = require("wtop.native")
local migrated, migrate_note = LayoutCommands.migrate(v1_path)
if native.available then
  assert(migrated, "migration failed: " .. tostring(migrate_note))
  assert(tostring(migrate_note):find("migrated", 1, true),
    "migration of an old file reports what it did: " .. tostring(migrate_note))
  assert(tostring(migrate_note):find(".bak", 1, true),
    "migration says where the previous file went: " .. tostring(migrate_note))
  local upgraded = read_file(v1_path)
  assert(upgraded:find("schema_version: 2", 1, true),
    "migrated file is not in the current form")
  assert(read_file(v1_path .. ".bak") == v1_body,
    "the v1 body did not land in the backup generation")
  -- What the migration wrote must itself load.
  local orders_again, status_again = LayoutStore.load(Workspace.default_orders(), v1_path)
  assert(status_again.state == "loaded" and orders_again.compute[1] == "core_bars",
    "the migrated file does not load back to the same arrangement")
else
  assert(not migrated and tostring(migrate_note):find("native"),
    "without the atomic writer migration must decline cleanly")
end

-- 6. A file already in the current form is left alone: the message says so
-- and neither the file nor the backup generation is churned.
if native.available then
  local current_path = base .. "-current.yml"
  local current_body = LayoutStore.encode(Workspace.default_orders(), {})
  write_file(current_path, current_body)
  local noop, noop_note = LayoutCommands.migrate(current_path)
  assert(noop, "no-op migration failed: " .. tostring(noop_note))
  assert(tostring(noop_note):find("already in the current form", 1, true),
    "a current file must be reported as current: " .. tostring(noop_note))
  assert(read_file(current_path) == current_body,
    "a no-op migration rewrote the file anyway")
  -- A successful load refreshes the backup to match the main file; that is
  -- the store's own behavior on every load, not something migration added.
  -- What a no-op must not do is leave the backup holding anything else.
  assert(read_file(current_path .. ".bak") == current_body,
    "a no-op migration left the backup different from the file")
  os.remove(current_path)
end

-- 7. A missing file is not an error, and creates nothing.
local absent_path = base .. "-absent.yml"
local nothing, nothing_note = LayoutCommands.migrate(absent_path)
assert(nothing, "migrating a missing layout failed: " .. tostring(nothing_note))
assert(tostring(nothing_note):find("nothing to migrate", 1, true),
  "a missing layout is reported as such: " .. tostring(nothing_note))
assert(read_file(absent_path) == nil and read_file(absent_path .. ".bak") == nil,
  "migrating a missing layout created files")

-- 8. A broken file without a backup is refused, byte-for-byte untouched.
local broken_path = base .. "-broken.yml"
local broken_body = "schema_version: [broken\n"
write_file(broken_path, broken_body)
local refused, refusal = LayoutCommands.migrate(broken_path)
equal(refused, nil, "a broken layout without a backup cannot be migrated")
assert(tostring(refusal):find("cannot migrate", 1, true),
  "the refusal names the operation: " .. tostring(refusal))
assert(read_file(broken_path) == broken_body,
  "a refused migration touched the broken file")

-- 9. A broken file with a usable backup is recovered onto disk: that is the
-- load path's own decision, and migration is what writes it down.
if native.available then
  local recoverable_path = base .. "-recoverable.yml"
  local good_body = LayoutStore.encode(Workspace.default_orders(), {})
  write_file(recoverable_path, good_body)
  assert(LayoutStore.load(Workspace.default_orders(), recoverable_path))
  write_file(recoverable_path, broken_body)
  local recovered, recovered_note = LayoutCommands.migrate(recoverable_path)
  assert(recovered, "recovery migration failed: " .. tostring(recovered_note))
  assert(tostring(recovered_note):find("recovered", 1, true),
    "a recovery migration says it recovered: " .. tostring(recovered_note))
  assert(read_file(recoverable_path):find("schema_version: 2", 1, true),
    "the recovered file was not installed")
  os.remove(recoverable_path)
  os.remove(recoverable_path .. ".bak")
end

os.remove(v1_path)
os.remove(v1_path .. ".bak")
os.remove(broken_path)
os.remove(absent_path)
