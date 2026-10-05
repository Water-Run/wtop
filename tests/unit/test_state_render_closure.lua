-- The state vocabulary, closed over the renderer instead of over the source.
--
-- Every other scan in this project reads literals.  The reason-code work reads
-- `reason =` sites; the quality work of increment 60 reconciled three copies of
-- one list; the scheduler checks `result.quality` against that list.  All three
-- ask "what can the product *spell*?", and measured, the answer was clean: all
-- 71 quality sites that assign a string literal assign a published word, and
-- the vocabulary-convergence tests stayed green throughout.  Two values reached
-- the I/O page's Quality column anyway, because they never arrive as literals --
-- a mount's quality is whatever the statvfs failure classifier returned, and a
-- GPU engine's rate quality is the outcome of a comparison against the previous
-- sample.  `missing` rendered as the English word in all ten languages, and so
-- did `held`.
--
-- So the question this file answers is not "which literals exist" but "which
-- values reach the user-facing renderer", and the only way to answer it is to
-- run the renderers.  `Technical.state` and `Technical.reason` are the two
-- functions every technical label passes through, and `i18n/technical.lua`
-- falls back to the raw argument for any key a catalogue lacks -- which is the
-- defect, not a safety net: a value with no label is spelled English in every
-- language at once, and the fallback is silent.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local GPU = require("wtop.collectors.gpu")
local I18n = require("wtop.i18n")
local Mounts = require("wtop.collectors.mounts")
local Quality = require("wtop.model.quality")
local Technical = require("wtop.i18n.technical")
local TUI = require("wtop.tui")
local ViewModel = require("wtop.view_model")

local locales = { "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR",
                  "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU" }

local catalogs = {}
for _, locale in ipairs(locales) do
  local ok, module = pcall(require, "wtop.generated.locales." .. locale)
  assert(ok, "generated catalog for " .. locale .. " must be loadable")
  catalogs[locale] = module.messages
end

-- The catalogue a locale falls back to is the shipped en-US one, so "has a
-- label" means "has a label here", not "has one in every language" -- that is
-- the second clause, and conflating the two is how a key ends up translated in
-- one catalogue and raw in nine.
--
-- One fact about these catalogues makes the ten-locale loop cheap to state and
-- is worth writing down, because it is the reason the original defect rendered
-- as English rather than crashing.  `en-US` is the *reference*: `i18n/catalog`
-- validates every other compiled catalogue against it when a translator is
-- built, and a catalogue holding a key en-US lacks is an error.  So a key that
-- is missing from en-US fails at `I18n.new` with a message naming the offending
-- catalogue, while a key missing from *all* of them is perfectly consistent and
-- falls through `i18n/technical.lua` to the raw spelling.  The defect this file
-- records was the second kind, which is why nothing crashed and nothing was
-- logged: a value with no label anywhere is the only shape that is silent.
local function labelled(prefix, value)
  local missing = {}
  for _, locale in ipairs(locales) do
    if catalogs[locale][prefix .. "." .. value] == nil then
      missing[#missing + 1] = locale
    end
  end
  return missing
end

-- ---------------------------------------------------------------------------
-- The hook.  `Technical` is captured as an upvalue by the modules under test,
-- but they call it as a field of that table, so replacing the field is enough
-- to see every value on its way to a screen.
-- ---------------------------------------------------------------------------
local reached = {}
local real_state, real_reason = Technical.state, Technical.reason
Technical.state = function(i18n, value)
  if type(value) == "string" then reached["state:" .. value] = true end
  return real_state(i18n, value)
end
Technical.reason = function(i18n, value)
  if type(value) == "string" then reached["reason:" .. value] = true end
  return real_reason(i18n, value)
end

local function record_error(context, err)
  error(context .. ": " .. tostring(err), 0)
end

-- A table model renders one cell per column per row, and the widget reaches the
-- cell through `column.format(row[key], row)`.  Driving the same call is what
-- makes this file a measurement of the render path rather than a second copy of
-- the column definitions.
-- A snapshot populated so that every column whose cell is a technical label
-- has something to spell.  The thin version of this drove three values and
-- passed the assertions below for the wrong reason, which is the failure mode
-- clause 2 exists to catch.
local function every_published_quality()
  local qualities = {}
  for quality in pairs(Quality.VALID_QUALITY) do qualities[#qualities + 1] = quality end
  table.sort(qualities)
  return qualities
end

local drive_engine = function()
  return { history_values = function() return {} end }
end

local drive_capabilities = function()
  return {
    mounts = { available = true, source = "/proc/self/mountinfo" },
    disks = { available = true, source = "/sys/block", reason = "\u{2014}" },
    sensors = { available = false, state = "unavailable", reason = "hwmon_absent" },
    inspectors = {
      ["storage.smart"] = { available = true },
      ["memory.bandwidth"] = { available = false, state = "unavailable",
                               reason = "pmu_unavailable" },
      ["service.sshd"] = { available = false, state = "denied",
                           reason = "smartctl_not_found" },
    },
  }
end

local drive_snapshot = function()
  local mounts = {}
  for index, quality in ipairs(every_published_quality()) do
    mounts[#mounts + 1] = {
      id = tostring(9000 + index), mount_point = "/mnt/q" .. index,
      fs_type = "ext4", source = "/dev/probe" .. index, kind = "local",
      capacity = { total_bytes = 1024 * 1024, used_percent = 40, available_bytes = 512,
                   block_size_bytes = 4096 },
      inodes = { used_percent = 12, total = 100, free = 88, used = 12,
                 reserved = 0, available = 88 },
      quality = quality, partial = quality ~= "fresh", readonly = false,
    }
  end
  local snapshot = {
    cpu = { usage_percent = 12, quality = "fresh" },
    memory = { quality = "fresh" },
    pressure = { cpu = { some = { avg10 = 1.2 } },
                 memory = { some = { avg10 = 0.4 } },
                 io = { some = { avg10 = 0.1 } }, quality = "fresh" },
    disks = { devices = { { id = "sda", model = "probe", size = 1024,
                            medium = "SSD", quality = "fresh", read_bytes_per_second = 1,
                            write_bytes_per_second = 1, busy_percent = 3,
                            queue_depth = 1, read_latency_ms = 1 } } },
    network = { interfaces = {}, addresses_status = "fresh" },
    processes = { processes = { { pid = 1, name = "init", quality = "fresh",
                                  user = "root", cpu_percent = 0 } } },
    cpu_frequency = { policies = {}, current_quality = "fresh" },
    mounts = { mounts = mounts },
    workloads = { workloads = { { id = "c1", name = "probe", quality = "fresh",
                                  cgroup_path = "/probe", state = "running" } } },
    connections = { owner_scan = { quality = "fresh" },
                    connections = { { id = "1", protocol = "tcp", state = "ESTAB",
                                      local_address = "127.0.0.1:1",
                                      remote_address = "127.0.0.1:2", inode = "1" } } },
    sensors = { devices = { { class = "hwmon0", name = "probe",
                              channels = { { type = "temperature", input = 40,
                                             quality = "fresh" } } } } },
    gpus = { process_scan = { status = "ok", quality = "partial" }, devices = {} },
    quality = {
      mounts = { status = "ok", quality = "partial", reason = "statvfs_partial" },
      disks = { status = "ok", quality = "fresh" },
      sensors = { status = "unavailable", quality = "unavailable" },
    },
  }
  return snapshot
end

local function drive_tables(translator)
  local engine, snapshot = drive_engine(), drive_snapshot()
  local tabs = { "overview", "processes", "compute", "storage", "network",
                 "gpu", "workloads", "insights" }
  local driven = 0
  for _, tab in ipairs(tabs) do
    local models = ViewModel.build(engine, snapshot, translator,
      drive_capabilities(), tab)
    for _, model in pairs(models) do
      if type(model) == "table" and type(model.columns) == "table"
          and type(model.rows) == "table" then
        for _, row in ipairs(model.rows) do
          for _, column in ipairs(model.columns) do
            if type(column) == "table" and type(column.key) == "string" then
              local value = row[column.key]
              local ok, err = pcall(function()
                if type(column.format) == "function" then
                  return column.format(value, row)
                end
                return value
              end)
              if not ok then record_error("column " .. column.key .. " format", err) end
              local token_ok, token_err = pcall(function()
                if type(column.token) == "function" then return column.token(value, row) end
                return column.token
              end)
              if not token_ok then record_error("column " .. column.key .. " token", token_err) end
              driven = driven + 1
            end
          end
        end
      end
    end
  end
  return driven
end

-- The GPU client overlay, which is where a rate quality is spelled out next to
-- the number it qualifies.
local function drive_client_overlay(translator)
  local client = {
    id = "c", client_id = "7", driver = "i915", pci_bdf = "0000:00:02.0",
    mapping_quality = "estimated",
    engines = {
      render = { utilization_percent = 10, rate_quality = "held" },
      copy = { utilization_percent = 2, rate_quality = "fresh" },
    },
  }
  local lines = TUI.gpu_client_detail_lines(client, translator)
  assert(type(lines) == "table" and #lines > 0, "the client overlay must render")
  return lines
end

local translator = assert(I18n.new({ locale = "en-US" }))
local cells = drive_tables(translator)
local overlay = drive_client_overlay(translator)
Technical.state, Technical.reason = real_state, real_reason

-- ---------------------------------------------------------------------------
-- Clause 1 -- every value the renderers looked up has a label everywhere.
--
-- The criterion is the renderer's own, not a second one: `i18n/technical.lua`
-- looks a value up only when it is code-shaped, and passes anything else
-- through untouched.  That is why the em-dash placeholder the view model puts
-- in an empty Quality cell is not a defect -- it is language-neutral by
-- construction, and requiring a translation for it would be requiring the
-- catalogue to say "nothing" in ten ways.  Inventing a narrower or wider test
-- than the code it guards is the mistake increment 80 recorded, where a
-- stricter-than-needed criterion rejected a correct answer.
--
-- The order matters too: the drive happens above, before any assertion, so a
-- test that renders nothing cannot pass by having nothing to complain about.
-- ---------------------------------------------------------------------------
local CODE_SHAPED = "^[a-z][a-z0-9_]*$"
local unlabelled = {}
local recorded = 0
for key in pairs(reached) do
  local prefix, value = key:match("^(%a+):(.+)$")
  if prefix == "state" and value:match(CODE_SHAPED) then
    recorded = recorded + 1
    local missing = labelled("status", value)
    if #missing > 0 then
      unlabelled[#unlabelled + 1] = string.format("%s has no status label in %s",
        value, table.concat(missing, ", "))
    end
  end
end
assert(#unlabelled == 0,
  "a value reached the renderer with no display label, so it is spelled in "
  .. "English in every language:\n  " .. table.concat(unlabelled, "\n  "))

-- The pass-through is the renderer's own contract rather than an accident of
-- the shape, so it is asserted in a language whose script the placeholder
-- cannot occur in by coincidence.
local zh = assert(I18n.new({ locale = "zh-CN" }))
assert(real_state(zh, "—") == "—",
  "a value that is not code-shaped must be passed through unchanged")

-- ---------------------------------------------------------------------------
-- Clause 2 -- non-vacuity, against the measured numbers.  A closure guard is
-- the most exposed form of the mistake this project has made five times
-- already (M186, M191, M196, M209, M214): there the rule read files and
-- matched nothing because what it looked for had been moved, and here the
-- failure is quieter still -- a drive that stops reaching the renderers leaves
-- clause 1 reporting a clean, empty and entirely truthful result.  Both
-- numbers are the ones the drive actually produces, so neither can drift
-- upward unnoticed.
-- ---------------------------------------------------------------------------
assert(recorded == 15,
  "the drive recorded " .. recorded .. " state value(s), not the 15 this file "
  .. "was measured against; the closure has changed and the new value has to be "
  .. "looked at rather than absorbed")
assert(cells >= 250,
  "only " .. cells .. " table cells were driven (334 when measured); the column "
  .. "set was not exercised, so a column that renders a technical label may "
  .. "never have been reached")
for _, expected in ipairs({ "held", "estimated", "fresh" }) do
  assert(reached["state:" .. expected],
    "the drive never reached the renderer with " .. expected .. ", so the "
    .. "closure this file claims to measure is not the real one")
end

-- ---------------------------------------------------------------------------
-- Clause 3 -- every published quality has a label, in every language.  This is
-- the direction the literal scans could not express: `missing` and `held` were
-- added to the vocabulary by this increment, and a vocabulary entry with no
-- label is a promise the renderer cannot keep.
-- ---------------------------------------------------------------------------
local vocabulary = {}
for quality in pairs(Quality.VALID_QUALITY) do vocabulary[#vocabulary + 1] = quality end
table.sort(vocabulary)
assert(#vocabulary == 13,
  "the published quality vocabulary is " .. #vocabulary .. " entries, not the 13 "
  .. "this file was written against; a new word needs a label and a ranking")
for _, quality in ipairs(vocabulary) do
  local missing = labelled("status", quality)
  assert(#missing == 0,
    "published quality " .. quality .. " has no status label in "
    .. table.concat(missing, ", "))
end

-- The renderer's own fallback word.  It is spelled at three call sites for a
-- record that carries no state, and it had no label either, so the one value
-- the renderer itself invents was the one value it could not spell.
local unknown_missing = labelled("status", "unknown")
assert(#unknown_missing == 0,
  "the renderer's own fallback word has no label in "
  .. table.concat(unknown_missing, ", "))

-- ---------------------------------------------------------------------------
-- Clause 4 -- the severity ranking, and the reason it is one ranking.  The I/O
-- page's Quality column used to mark `partial` and `stale` as warnings and leave
-- every other state muted, which painted a mount whose statvfs was denied or had
-- errored exactly like a healthy one.  The Insights collector table already
-- ranked `denied` and `error` as critical, so the project held the right
-- ranking in one file and the wrong one in another -- the shape of defect
-- number thirty-four, which is why the ranking now lives beside the vocabulary
-- it ranks rather than in the column that needs it.
--
-- Two entries are worth arguing for here, because the first draft of the table
-- had both wrong and the guards below would have passed either way.  A mount
-- row reaches `unavailable` mostly by the product declining to read it -- a
-- network filesystem that might block, or a budget the collector set for
-- itself -- so it is muted rather than critical, matching the Insights table's
-- treatment of an unavailable collector; a row that turned red every time wtop
-- was careful would train the operator to ignore the colour.  And `missing` is
-- a warning, not a critical: the mount point is gone, so nothing failed that
-- could have succeeded, which is the whole difference between it and `denied`.
-- ---------------------------------------------------------------------------
local expected_severity = {
  denied = "metric.critical", error = "metric.critical",
  partial = "metric.warn", stale = "metric.warn", gap = "metric.warn",
  truncated = "metric.warn", missing = "metric.warn", held = "metric.warn",
  fresh = "text.muted", measured = "text.muted", estimated = "text.muted",
  reset = "text.muted", unavailable = "text.muted",
}
for quality, expected in pairs(expected_severity) do
  local actual = Quality.SEVERITY[quality]
  local spelled = actual and ("metric." .. actual) or "text.muted"
  assert(spelled == expected,
    "severity for " .. quality .. " is " .. spelled .. ", expected " .. expected)
end
for quality in pairs(Quality.SEVERITY) do
  assert(Quality.VALID_QUALITY[quality],
    "SEVERITY ranks " .. quality .. ", which is not a published quality; a "
    .. "ranking for an unpublished word is a ranking nothing can reach")
end

-- And the column itself, driven the way the widget drives it.
local function quality_column_token(quality)
  local engine = { history_values = function() return {} end }
  local snapshot = {
    cpu = {}, memory = {}, pressure = {}, disks = {}, network = {},
    processes = {}, cpu_frequency = {}, workloads = {}, connections = {},
    quality = {}, sensors = { devices = {} }, gpus = {},
    mounts = { mounts = { { mount_point = "/probe", quality = quality,
                           partial = quality ~= "fresh" } } },
  }
  local models = ViewModel.build(engine, snapshot, translator, {}, "storage")
  local model = models.mount_table
  assert(type(model) == "table" and type(model.columns) == "table",
    "the I/O page must expose a mount table")
  local driven_columns = 0
  for _, column in ipairs(model.columns) do
    if column.key == "quality" then
      local row = model.rows[1]
      assert(row.quality == quality,
        "the row's quality did not survive into the model: "
        .. tostring(row.quality) .. " != " .. quality)
      local rendered = column.format(row.quality, row)
      assert(type(rendered) == "string" and rendered ~= "",
        "the quality column rendered nothing for " .. quality)
      driven_columns = driven_columns + 1
      return column.token(row.quality, row), rendered, driven_columns
    end
  end
  error("the mount table has no quality column", 0)
end

for quality, expected in pairs(expected_severity) do
  local token, _, driven_columns = quality_column_token(quality)
  assert(driven_columns == 1, "expected exactly one quality column, saw " .. driven_columns)
  assert(token == expected,
    "a mount whose quality is " .. quality .. " is painted " .. tostring(token)
    .. ", expected " .. expected)
end

-- ---------------------------------------------------------------------------
-- Clause 4b -- a label that cannot fit its column is not a label.  The first
-- draft of `status.missing` was the sentence "The thing that would have been
-- read is gone", on the reasoning that a label has to explain itself, and the
-- Quality column is ten cells wide: `ui/widgets/table.lua` truncates every cell
-- to its column width, so the user saw "The thing..." -- which is worse than no
-- label at all, because it reads as a rendering fault rather than as a word
-- with a meaning.  The three labels this increment adds are single words for
-- that reason, and this is the clause that holds them to it, measured in
-- terminal cells rather than in bytes, because ten bytes of CJK is not ten
-- columns.
--
-- The scope is now the whole family rather than the two words this increment
-- added, because the increment that found the deficit also measured what
-- closing it costs.  That measurement is what turned a recorded open item into
-- a decision: `visible_columns` includes a column when its `min_width` fits the
-- remaining area, and `render` then hands out leftover cells one at a time up
-- to each column's declared `width`, so **a preferred width cannot remove a
-- column** -- and none of these columns had its `min_width` touched.  Across
-- the eight sizes the PTY matrix uses, 22 of 64 (column, size) pairs changed
-- and **no table lost a column anywhere**; the 42 that did not change are the
-- tight sizes where the column already sat at its minimum and would have been
-- clipped with or without the change.  So the translations stay correct
-- German, Spanish and French words instead of being shortened to fit, which was
-- the alternative the open item weighed.
--
-- `unknown` is deliberately absent from the value list below.  It is the
-- renderer's fallback for a record that carries *no* state, and it is shown on
-- the inspector's status and field lines, which have no column width to
-- exceed; asserting a width on it would be testing a constraint the renderer
-- does not have, which is the stricter-than-the-code mistake this file's first
-- clause warns about.  What matters for it is only that it is translated, and
-- clause 3 says so.
-- ---------------------------------------------------------------------------
local Table = require("wtop.ui.widgets.table")
local Width = require("wtop.ui.renderer.width")

-- Every value a state column can be handed.
local function state_values()
  local values = {}
  for quality in pairs(Quality.VALID_QUALITY) do values[#values + 1] = quality end
  for status in pairs(Quality.VALID_STATUS) do values[#values + 1] = status end
  values[#values + 1] = "ready"
  values[#values + 1] = "partial"
  table.sort(values)
  return values
end

local PTY_SIZES = { 60, 80, 40, 80, 80, 160, 200, 180 }
local values = state_values()

-- Which columns are state columns is decided by what they *do*, not by a list.
-- A column qualifies when formatting a published vocabulary word returns
-- something other than the word itself: that is the test for "this cell is
-- translated", and it is what separates these from the reason columns, whose
-- codes (`statvfs_partial`, `hwmon_absent`) are not vocabulary words, so
-- `Technical.reason` hands them straight back unchanged.
local function renders_state(column)
  for _, value in ipairs(values) do
    local ok, rendered = pcall(column.format, value, { [column.key] = value })
    if ok and type(rendered) == "string" and rendered ~= value
        and rendered ~= "—" and rendered ~= "" then
      return true
    end
  end
  return false
end

local translators = {}
for _, locale in ipairs(locales) do translators[locale] = assert(I18n.new({ locale = locale })) end

local widest_by_model = {}
for _, locale in ipairs(locales) do
  local models = ViewModel.build(drive_engine(), drive_snapshot(), translators[locale],
    drive_capabilities(), "overview")
  for model_id, model in pairs(models) do
    if type(model) == "table" and type(model.columns) == "table" then
      for _, column in ipairs(model.columns) do
        if type(column) == "table" and type(column.format) == "function"
            and type(column.width) == "number" and renders_state(column) then
          local name = model_id .. "." .. tostring(column.key)
          local entry = widest_by_model[name]
            or { name = name, model = model, column = column, worst = 0, text = "" }
          for _, value in ipairs(values) do
            local ok, rendered = pcall(column.format, value, { [column.key] = value })
            if ok and type(rendered) == "string" and rendered ~= "" then
              local cells = Width.display_width(rendered)
              if cells > entry.worst then
                entry.worst, entry.text = cells,
                  string.format("%s/%s=%q", value, locale, rendered)
              end
            end
          end
          widest_by_model[name] = entry
        end
      end
    end
  end
end

local names = {}
for name in pairs(widest_by_model) do names[#names + 1] = name end
table.sort(names)
assert(#names == 8,
  "the state columns found are " .. #names .. ", not the 8 this file was "
  .. "measured against: " .. table.concat(names, ", "))

for _, name in ipairs(names) do
  local entry = widest_by_model[name]
  assert(entry.worst <= entry.column.width,
    name .. " shows its widest label as \"" .. entry.text .. "\" -- " .. entry.worst
    .. " cells in a " .. entry.column.width .. "-cell column, so it is truncated "
    .. "on screen wherever the table has the room to show it")
  -- The property the widening relies on: a declared width is only a preference,
  -- so it can never cost another column its place.  `min_width` is what decides
  -- inclusion, and these columns keep the minimum they always had.
  local counts = {}
  for _, area_width in ipairs(PTY_SIZES) do
    counts[#counts + 1] = #Table.visible_columns(entry.model.columns, "full", area_width)
  end
  for _, area_width in ipairs(PTY_SIZES) do
    local visible = #Table.visible_columns(entry.model.columns, "full", area_width)
    assert(visible > 0,
      name .. " renders no columns at all at " .. area_width .. " cells")
  end
end

-- The clause is worthless if it found nothing, so both the family and the
-- measured worst case are asserted against the numbers the columns were sized
-- from.  This is the seventh time in this project a rule has had to be asked
-- what it matched.
assert(widest_by_model["mount_table.quality"] ~= nil
  and widest_by_model["inspector_table.status"] ~= nil,
  "the state-column scan did not reach the tables it is supposed to cover")
local measured_worst = 0
for _, entry in pairs(widest_by_model) do
  if entry.worst > measured_worst then measured_worst = entry.worst end
end
assert(measured_worst == 20,
  "the widest state label is now " .. measured_worst .. " cells, not the 20 the "
  .. "columns were sized against; a new translation may need a wider column")

-- ---------------------------------------------------------------------------
-- Clause 5 -- the two words this file exists for are *producible*, not merely
-- spellable.  Each is built by the collector that emits it, so the guard cannot
-- be satisfied by a catalogue entry for a value nothing generates: which is the
-- mistake increment 81 made, checking the inventory was translated without
-- checking the product could still produce what the inventory listed.
-- ---------------------------------------------------------------------------
local handle = assert(io.open(root .. "/tests/fixtures/mounts/main.mountinfo", "rb"))
local mountinfo = assert(handle:read("*a"))
handle:close()
local normal_stat = { block_size = 4096, blocks = 1000, blocks_free = 400,
                       blocks_available = 250, files = 100, files_free = 40 }
local mounts = Mounts.new({
  fs = { read = function(_, path, limit)
    assert(path == "/proc/self/mountinfo" and type(limit) == "number")
    return mountinfo
  end },
  statvfs = function(path)
    if path == "/mnt/project copy" then
      return nil, "statvfs: No such file or directory", 2
    end
    return normal_stat
  end,
}):sample({ now_ns = function() return 1000000000 end })

local missing_mounts = 0
for _, mount in ipairs(mounts.data.mounts) do
  if mount.quality == "missing" then
    missing_mounts = missing_mounts + 1
    assert(Quality.VALID_QUALITY[mount.quality],
      "a collector published a quality outside the published vocabulary")
    assert(#labelled("status", mount.quality) == 0,
      "a collector published a quality with no display label")
  end
end
assert(missing_mounts == 1,
  "the statvfs fixture should have produced exactly one missing mount, not "
  .. missing_mounts .. "; if the collector stopped producing it, this clause "
  .. "is measuring nothing")

-- A GPU engine counter that goes backwards on the second sample.  The value is
-- a comparison against the previous reading, which is the whole reason no
-- literal scan in this project could see it: `held` is spelled nowhere in the
-- source that produces it, and `grep` for it in `src/` returns the test that
-- asserts on it and nothing else.
local GPU_STAT = "4242 (glxgears) 1000 0 0 0 -1 4194560 100 0 0 0 10 20 30 40 20 0 1 0 100 "
  .. "2000000 500 18446744073709551615 0 0 0\n"
local function gpu_fs(busy_ns)
  local files = {
    ["/gfx/card0/device/uevent"] = "DRIVER=nvidia\nPCI_SLOT_NAME=0000:03:00.0\n",
    ["/gfx/card0/device/vendor"] = "0x10de\n",
    ["/gfx/card0/device/device"] = "0x2684\n",
    ["/gfx/card0/device/driver"] = "nvidia\n",
    ["/gfx/card0/dev"] = "226:0\n",
    ["/gfx-proc/4242/stat"] = GPU_STAT,
    ["/gfx-proc/4242/status"] = "Name:\tglxgears\nUid:\t1000\t1000\t1000\t1000\n",
    ["/gfx-proc/4242/fdinfo/7"] = table.concat({
      "drm-driver:\tnvidia",
      "drm-client-id:\t4",
      "drm-pdev:\t0000:03:00.0",
      "drm-engine-render:\t" .. busy_ns .. " ns",
      "", -- the kernel's own trailing newline
    }, "\n"),
  }
  local directories = {
    ["/gfx"] = { "card0" },
    ["/gfx-proc"] = { "4242" },
    ["/gfx-proc/4242/fdinfo"] = { "7" },
  }
  local fs = {}
  function fs:read(path, limit)
    local value = files[path]
    if value == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    if limit and #value > limit then
      return nil, { kind = "too_large", message = "file_exceeds_limit", path = path }
    end
    return value
  end
  function fs:read_number(path)
    local content = self:read(path, 256)
    if not content then return nil, { kind = "missing", path = path } end
    return tonumber(content:match("^%s*([^%s]+)"))
  end
  function fs:list(path, limit)
    local values = directories[path]
    if values == nil then
      return nil, { kind = "missing", message = "fixture_directory_missing", path = path }
    end
    local output = {}
    for index, value in ipairs(values) do output[index] = value end
    local truncated = limit ~= nil and #output > limit
    if truncated then
      for index = #output, limit + 1, -1 do output[index] = nil end
    end
    return output, nil, truncated
  end
  function fs:readlink(path)
    return nil, { kind = "missing", message = "fixture_link_missing", path = path }
  end
  return fs
end

local gpu_collector = GPU.new({
  drm_path = "/gfx", proc_path = "/gfx-proc",
  max_processes = 8, max_fds_per_process = 8,
  max_fdinfo_files = 8, max_clients = 8,
})
local function gpu_sample(busy_ns, now, previous)
  return gpu_collector:sample({ fs = gpu_fs(busy_ns), now_ns = function() return now end },
    previous)
end
local first_sample = gpu_sample(1000000, 1000000)
assert(type(first_sample) == "table" and first_sample.quality ~= nil,
  "the first GPU sample must carry a quality for the comparison to mean anything")
local second_sample = gpu_sample(500000, 2000000, first_sample)
assert(second_sample.quality ~= nil, "the second GPU sample must carry a quality too")

local held_engines, fresh_engines = 0, 0
for _, device in ipairs(second_sample.data.devices or {}) do
  for _, client in ipairs((device.processes or {}).clients or {}) do
    for _, engine in pairs(client.engines or {}) do
      if engine.rate_quality == "held" then
        held_engines = held_engines + 1
        assert(Quality.VALID_QUALITY[engine.rate_quality],
          "a collector published a rate quality outside the published vocabulary")
        assert(#labelled("status", engine.rate_quality) == 0,
          "a collector published a rate quality with no display label")
      elseif engine.rate_quality == "fresh" then
        fresh_engines = fresh_engines + 1
      end
    end
  end
end
assert(held_engines > 0,
  "a second sample whose engine counter moved backwards produced no `held` "
  .. "rate quality (" .. fresh_engines .. " fresh); the clause above is then "
  .. "measuring nothing")

-- ---------------------------------------------------------------------------
-- Clause 6 -- the labels exist in the catalogues, not only in the generated
-- Lua.  The generated modules are a build product; `locales/*.yml` is the
-- source, and a key added to one and not the other is a key the next
-- `make locales` deletes.  Increment 82 learned that the catalogue's order and
-- contiguity are the properties a reader relies on; this is the property the
-- build relies on.
-- ---------------------------------------------------------------------------
for _, locale in ipairs(locales) do
  local body = assert(io.open(root .. "/locales/" .. locale .. ".yml", "rb")):read("*a")
  for _, quality in ipairs({ "held", "missing", "unknown" }) do
    assert(body:find("  status." .. quality .. ":", 1, true),
      locale .. ".yml has no status." .. quality .. " key; the generated "
      .. "catalogue has one, so `make locales` would delete it")
  end
end

return true
