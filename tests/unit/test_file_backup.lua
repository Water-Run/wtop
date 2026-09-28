-- Configuration files keep a one-generation backup. A successful load
-- refreshes it; a main file that cannot be read or parsed recovers from it
-- instead of silently falling back to defaults.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local FileBackup = require("wtop.file_backup")
local Config = require("wtop.config")
local LayoutStore = require("wtop.layout_store")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value",
      tostring(expected), tostring(actual)), 2)
  end
end

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

local function remove_file(path)
  os.remove(path)
end

local directory = os.getenv("TMPDIR") or "/tmp"
local base = directory .. "/wtop-backup-test-" .. tostring(os.time()) .. "-"
  .. tostring(math.random(1, 1000000))
local config_path = base .. "-config.yml"
local layout_path = base .. "-layout.yml"

-- Layout defaults: the store needs the page-to-widget mapping.
local defaults = { overview = { "cpu", "memory", "network" } }

-- 1. A valid main file is loaded and its backup is refreshed to match.
-- Writing the backup needs the native atomic writer, so the refresh itself is
-- only asserted where that module is present; recovery below is read-only.
local native = require("wtop.native")
write_file(config_path, "schema_version: 1\nlocale: \"de-DE\"\n")
local config, config_status = Config.load(config_path)
equal(config_status.state, "loaded", "valid configuration loads")
equal(config.locale, "de-DE", "loaded configuration is applied")
if native.available then
  equal(read_file(FileBackup.backup_path(config_path)),
    "schema_version: 1\nlocale: \"de-DE\"\n",
    "successful load refreshes the backup")
else
  write_file(FileBackup.backup_path(config_path),
    "schema_version: 1\nlocale: \"de-DE\"\n")
end

-- 2. A corrupted main file recovers from the backup.
write_file(config_path, "schema_version: 1\nlocale: [broken\n")
local recovered, recovered_status = Config.load(config_path)
equal(recovered_status.state, "recovered_backup",
  "corrupt configuration recovers from the backup")
equal(recovered.locale, "de-DE", "recovered configuration is applied")
assert(type(recovered_status.reason) == "string" and #recovered_status.reason > 0,
  "recovery reports why the main file was rejected")

-- 3. A corrupt main file with no usable backup stays an error.
remove_file(FileBackup.backup_path(config_path))
local failed, failed_status = Config.load(config_path)
equal(failed_status.state, "error", "corrupt configuration without backup errors")
equal(failed.locale, Config.defaults().locale, "error path falls back to defaults")

-- 4. A backup that is itself corrupt does not win over the error state.
write_file(FileBackup.backup_path(config_path), "not: [valid\n")
local double_failed, double_status = Config.load(config_path)
equal(double_status.state, "error", "corrupt backup does not mask the error")

-- 5. The layout store follows the same contract for parse failures.
write_file(layout_path, "schema_version: [broken\n")
local layout_orders, layout_status = LayoutStore.load(defaults, layout_path)
equal(layout_status.state, "error", "unparseable layout without backup errors")
write_file(FileBackup.backup_path(layout_path),
  "schema_version: 1\npages:\n  overview:\n    - network\n    - cpu\n")
local layout_recovered, layout_recovered_status = LayoutStore.load(defaults, layout_path)
equal(layout_recovered_status.state, "recovered_backup",
  "corrupt layout recovers from the backup")
assert(type(layout_recovered) == "table"
  and layout_recovered.overview[1] == "network",
  "recovered layout keeps its saved page order")

remove_file(config_path)
remove_file(FileBackup.backup_path(config_path))
remove_file(layout_path)
remove_file(FileBackup.backup_path(layout_path))

print("ok: configuration backup and recovery")
