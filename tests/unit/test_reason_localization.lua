-- Provider reason codes shown in status lines, table quality columns and
-- inspector overlays must have a translated display form. Snapshot JSON keeps
-- the stable machine spelling; only the presentation layer localizes.
local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local Technical = require("wtop.i18n.technical")

-- Codes emitted by collectors and inspectors that some surface *renders*.  The
-- criterion is rendering, not existing: a code carried by a per-row `reason`
-- field in the snapshot does not qualify just because the field exists, because
-- the export allowlist copies `partial_reason` and `reset_reason` into the agent
-- payload and nothing reads them there.  Internal-only codes that never reach a
-- rendered surface stay untranslated on purpose.
--
-- This sentence used to say "a status line, a partial-row marker, or an inspector
-- overlay", and the middle item was what made the criterion unreadable: read one
-- way it is about what a user sees, read another it is about what the snapshot
-- holds, and the twenty-four codes below are all exported.  The settled reading
-- is the first, and `process_io_unavailable` is what settles it -- the native
-- modules push it into the same `partial_reason` field *and* `tui.lua` falls back
-- to it at line 476 and renders it through `Technical.reason` at line 1023, so
-- the field name cannot be the criterion, only the rendering is.
local interface_reasons = {
  "amdsmi_unavailable",
  "argv_executor_unavailable",
  "cache_value_out_of_range",
  "cancel_callback_failed",
  "cancelled",
  "cannot_remove_last_widget",
  "catalog_exceeds_max_bytes",
  "catalog_rejected",
  "channel_enumeration_truncated",
  "collector_exception",
  "collector_returned_invalid_quality",
  "collector_returned_invalid_result",
  "collector_returned_invalid_status",
  "configuration_limit_reached",
  "cgroup_counter_reset",
  "cgroup_node_partially_read",
  "cgroup_rate_unavailable",
  "connections_partial",
  "content_required",
  "cpu_counter_delta_unavailable",
  "cpu_counters_missing",
  "cpu_info_data_incomplete",
  "cpu_info_value_not_stated",
  "cpufreq_data_incomplete",
  "cpufreq_value_derived",
  "credible_theoretical_limit_required",
  "current_frequency_unavailable",
  "default_routes_incomplete",
  "device_enumeration_truncated",
  "device_inventory_unavailable",
  "disk_data_partial",
  "disk_rate_unavailable",
  "duplicate_locale",
  "estimated_available_out_of_range",
  "event_provider_unavailable",
  "executor_exception",
  "file_content_not_string",
  "filesystem_error",
  "gpu_data_incomplete",
  "gpu_identity_inferred",
  "hwmon_data_partial",
  "hwmon_value_derived",
  "identity_collision",
  "invalid_device_path",
  "invalid_executor_result",
  "invalid_executor_status",
  "invalid_family",
  "invalid_gpu_process_scan_policy",
  "invalid_inspection_depth",
  "invalid_perf_clock",
  "invalid_perf_clock_result",
  "invalid_perf_executable",
  "invalid_perf_reader_result",
  "invalid_perf_reader_status",
  "invalid_perf_runner",
  "invalid_perf_runner_result",
  "invalid_probe_result",
  "invalid_process_system_constants",
  "invalid_result",
  "invalid_runner_options",
  "invalid_runner_policy",
  "invalid_sleep_executable",
  "invalid_smartctl_runner_result",
  "invalid_smartctl_runner_status",
  "invalid_statvfs_provider",
  "invalid_workspace_name",
  "last_workspace",
  "layout_rejected",
  "levelzero_unavailable",
  "loadavg_unavailable",
  "memory_controller_pmu_not_found",
  "memory_counter_read_unverified",
  "memory_event_open_failed",
  "memory_events_not_counted",
  "memory_events_not_supported",
  "native_collection_failed",
  "native_statvfs_unavailable",
  "no_cpufreq_policies",
  "no_device_inventory",
  "no_drm_card_devices",
  "no_hwmon_devices",
  "no_power_supplies",
  "no_powercap_zones",
  "no_pressure_resources_readable",
  "no_readable_powercap_zones",
  "no_socket_tables_available",
  "network_rate_unavailable",
  "not_all_pressure_resources_readable",
  "nvml_unavailable",
  "perf_counter_value_out_of_range",
  "perf_event_permission_denied",
  "perf_executable_not_found",
  "perf_executable_not_runnable",
  "perf_reader_bandwidth_out_of_range",
  "perf_reader_exception",
  "perf_reader_missing_bandwidth",
  "perf_reader_timeout",
  "perf_reader_unavailable",
  "perf_runner_exception",
  "perf_runner_unavailable",
  "poll_failed",
  "perf_stat_cancelled",
  "perf_stat_failed",
  "perf_stat_invalid_counts",
  "perf_stat_missing_counts",
  "perf_stat_output_truncated",
  "perf_stat_timeout",
  "platform_data_partial",
  "platform_rate_unavailable",
  "powercap_data_incomplete",
  "proc_entries_not_table",
  "proc_enumeration_failed",
  "proc_uptime_unreadable",
  "process_data_partial",
  "process_io_unavailable",
  "process_limit_reached",
  "process_rate_unavailable",
  "read_failed",
  "safe_mode",
  "service_not_observed",
  "session_provider_unavailable",
  "sleep_executable_not_found",
  "sleep_executable_not_runnable",
  "sleep_workload_failed",
  "smartctl_cancelled",
  "smartctl_empty_output",
  "smartctl_invalid_json",
  "smartctl_invalid_payload",
  "smartctl_output_truncated",
  "smartctl_not_found",
  "smartctl_permission_denied",
  "smartctl_runner_exception",
  "smartctl_timeout",
  "smartctl_unavailable",
  "socket_data_partial",
  "socket_tables_partial",
  "socket_tables_unavailable",
  "socket_tables_denied",
  "statvfs_failed",
  "statvfs_partial",
  "supported_memory_events_not_found",
  "system_identity_incomplete",
  "systemd_output_too_large",
  "systemd_unavailable_process_fallback",
  "timeout",
  "translator_locale_mismatch",
  "unknown_workspace",
  "unsupported_on_this_platform",
  "waitid_failed",
  "waitpid_failed",
  "widget_already_placed",
  "widget_not_in_page",
  "workspace_limit_reached",
  "workspace_name_length",
  "workspace_name_must_be_text",
  "workspace_name_taken",
}

-- Codes deliberately kept machine-only: admission-budget markers exported in
-- JSON, and input-decoder limits whose events no surface renders.
--
-- **The rule, settled by the table's own precedent rather than by preference.**
-- `calls` and `time` have always been here, and they are the same shape as the
-- twenty-two codes below: `mounts.lua` sets `budget_reason = "calls"` and
-- `"time"` on a per-mount record (lines 302 and 304), `export.lua` line 585
-- copies the field into the agent payload, and no view model and no TUI reads
-- it. So "a per-row marker that reaches only the JSON" has always been
-- `machine_only` here, and the inventory's scope comment is therefore about a
-- marker some surface *displays*, not about a marker that exists in the
-- snapshot. Measured, the twenty-two below are exactly that shape:
-- `partial_reason` listed for processes, mounts and workloads at `export.lua`
-- 356 and 571, `reset_reason` for disks at 234, and grep count for all three in
-- `view_model.lua` and `tui.lua` of zero. `process_io_unavailable` is the
-- control that proves the criterion is presentation and not the field name: the
-- native modules push it into `partial_reason` too, and `tui.lua` *also* falls
-- back to it at line 476 and renders it through `Technical.reason` at line 1023,
-- so it stays above.
--
-- The two input-decoder codes were in **both** lists, which is the defect this
-- increment found and the reason twenty dead translations survived a year of
-- this guard.  Measured, they cannot reach a rendered surface: `input.lua` 119
-- and 141 and `ui/input/decoder.lua` 175, 222 and 226 emit them as
-- `{type = "error", reason = ...}`, `tui.lua` feeds those events to
-- `process_event` at 4597 and 4602, and `process_event` has no branch on
-- `event.type == "error"` -- grep count for `event.reason` in the whole of
-- `tui.lua` is zero, and both of its non-key fall-throughs (line 3395 inside the
-- search editor, line 4177 at top level) `return`.  An error event is therefore
-- dropped, so the code it names is never rendered, so `machine_only` is the side
-- they belong on.  Being listed in `interface_reasons` as well is what kept
-- their catalogues populated: the translation check asks the interface list, and
-- an entry in both lists satisfies both checks at once.
local EXPORT_ONLY = "in the export allowlist; read by no view model or TUI"
local DROPPED_EVENT = "emitted as an error event that `process_event` never renders"
-- `move_focused_to`'s two argument guards.  They *are* part of a vocabulary
-- that reaches the status line through the assembled message id at `tui.lua`
-- 3544, and the entry for that site is the only reason they are named
-- anywhere; the rest of the tree has never heard of them.  Neither can be
-- produced by the caller: it passes `target.id` from the overlay's own list of
-- drop targets, and `selection.position`, whose only writer sets it to
-- `"before"` or `"after"`.  They are the same family as the 263
-- `return ..., "code"` lines increment 64 measured -- argument validation --
-- and a code no caller can reach is not a code a user can be shown.  The claim
-- is falsifiable in the way the rest of this table is: add a second caller that
-- can pass a bad target and it stops being true, which is recorded here rather
-- than assumed away.
local ARGUMENT_GUARD = "an argument guard whose only production caller validates the argument first"

local machine_only = {
  calls = EXPORT_ONLY,
  time = EXPORT_ONLY,
  invalid_position = ARGUMENT_GUARD,
  invalid_target_widget = ARGUMENT_GUARD,
  input_buffer_limit = DROPPED_EVENT,
  input_sequence_limit = DROPPED_EVENT,
  -- Per-row markers, export only.  Written as a shared local because it is one
  -- measurement applied twenty-two times, and a guard that repeats its evidence
  -- twenty-two times is a guard whose evidence can drift apart twenty-two ways.
  status_denied = EXPORT_ONLY,
  status_parse_error = EXPORT_ONLY,
  status_unavailable = EXPORT_ONLY,
  counter_reset = EXPORT_ONLY,
  derived_value_out_of_range = EXPORT_ONLY,
  statvfs_skipped_budget_exhausted = EXPORT_ONLY,
  statvfs_skipped_potentially_blocking_filesystem = EXPORT_ONLY,
  capacity_refresh_pending = EXPORT_ONLY,
  coalition_query_unavailable = EXPORT_ONLY,
  cpu_performance_states_unavailable = EXPORT_ONLY,
  gpu_performance_counters_unavailable = EXPORT_ONLY,
  ioreport_energy_model_unavailable = EXPORT_ONLY,
  memory_unavailable = EXPORT_ONLY,
  no_sensors = EXPORT_ONLY,
  no_thermal_zones = EXPORT_ONLY,
  per_process_gpu_usage_unavailable = EXPORT_ONLY,
  process_identity_changed = EXPORT_ONLY,
  processor_frequency_unavailable = EXPORT_ONLY,
  query_denied = EXPORT_ONLY,
  thermal_zone_counters_unavailable = EXPORT_ONLY,
  times_unavailable = EXPORT_ONLY,
  volume_identity_unavailable = EXPORT_ONLY,
  nvml_library_not_found = "JSON `providers` only; no view model reads it",
  nvml_symbols_missing = "JSON `providers` only; no view model reads it",
  nvml_initialization_failed = "JSON `providers` only; no view model reads it",
  amdsmi_library_not_found = "JSON `providers` only; no view model reads it",
  amdsmi_symbols_missing = "JSON `providers` only; no view model reads it",
  amdsmi_initialization_failed = "JSON `providers` only; no view model reads it",
  levelzero_library_not_found = "JSON `providers` only; no view model reads it",
  levelzero_symbols_missing = "JSON `providers` only; no view model reads it",
  levelzero_initialization_failed = "JSON `providers` only; no view model reads it",
}
-- Every entry carries its evidence.  Four of them used to be a bare `true`,
-- older than the convention and exempt from it; the input-decoder measurement
-- gave those four a reason as well, so nothing is exempt any more and the
-- exemption is gone rather than left as a hole.
for code, why in pairs(machine_only) do
  assert(type(why) == "string" and why ~= "",
    "the machine-only exemption for `" .. code .. "` has no reason, which is a "
      .. "claim without evidence: say how the code was measured not to reach a "
      .. "rendered surface, or move it to `interface_reasons` and translate it")
end

-- **The two lists must be disjoint, and nothing checked that.**  An entry in
-- both is not a harmless duplicate: the translation check asks
-- `interface_reasons` and the spelling check asks the union, so a code listed
-- twice satisfies every clause in this file while the guard is telling two
-- contradictory stories about it -- `input_buffer_limit` and
-- `input_sequence_limit` sat in both for the whole life of this file, and their
-- presence in `interface_reasons` is the only reason ten languages still carry
-- a translation of a code no user can be shown.  The pair is not the hazard;
-- the hazard is that the union built at line ~430 cannot tell a code that is
-- inventoried twice from one that is inventoried once.
local claimed_twice = {}
for _, code in ipairs(interface_reasons) do
  if machine_only[code] then claimed_twice[#claimed_twice + 1] = code end
end
if #claimed_twice > 0 then
  table.sort(claimed_twice)
  error("these codes are in `interface_reasons` *and* in `machine_only`: "
    .. table.concat(claimed_twice, ", ") .. ".  The first says a rendered surface "
    .. "shows them and so they must be translated; the second says none does.  "
    .. "Both clauses then pass, and the disagreement is invisible.  Decide which "
    .. "list the measurement supports and drop the other entry.", 0)
end

-- **And neither list may repeat a code.**  This clause is here because the one
-- above was written in increment 67 and this one was not, and increment 73 then
-- produced exactly the defect it would have caught: `network_rate_unavailable`
-- was added to `interface_reasons` in one increment and again in the next, and
-- every clause in this file passed.  A duplicate is invisible to all of them --
-- the catalogue check asks "does this listed code have a key", which is as true
-- the second time as the first, and the spelling check asks whether a spelled
-- code is inventoried at all.  So the two lists were each checked against the
-- other and neither was checked against itself, which is the one comparison
-- that catches an entry added twice.
--
-- Measured over the shipped list, it happened once and was found by a counting
-- script rather than by this file; that is the argument for the clause rather
-- than against it.  The probe below is what keeps it alive: it hands the check
-- a list with one code in it twice and requires a complaint naming that code.
local function duplicates_in(codes)
  local seen, repeated = {}, {}
  for _, code in ipairs(codes) do
    if seen[code] then repeated[#repeated + 1] = code else seen[code] = true end
  end
  table.sort(repeated)
  return repeated
end
local interface_twice = duplicates_in(interface_reasons)
assert(#interface_twice == 0,
  "`interface_reasons` lists these codes twice: "
    .. table.concat(interface_twice, ", ")
    .. ".  A duplicate passes every other clause -- the catalogue check asks "
    .. "only whether the code has a translation, and the spelling check only "
    .. "whether a spelled code is inventoried -- so two entries for one code "
    .. "read as agreement rather than as the second spelling mistake it is.")
assert(#duplicates_in({ "probe_a", "probe_b", "probe_a" }) == 1
    and duplicates_in({ "probe_a", "probe_b" })[1] == nil,
  "the duplicate check must report a repeated code and leave a distinct list "
    .. "alone, or it cannot be trusted to have found the one")

local locales = { "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR",
  "es-ES", "fr-FR", "de-DE", "pt-BR", "ru-RU" }

-- The `reason.*` keys in every catalogue are in ascending order, and that is
-- asserted rather than assumed.  Nothing in YAML cares, so nothing was failing:
-- measured before this clause, **six keys in each of the ten files** were out of
-- order, identically in all ten, left by increments 67 to 73.  The order is what
-- a reader relies on to notice a key that is *missing*, and this project has now
-- put a new key in the wrong slot three times while inserting one -- `disk_*`
-- after `duplicate_locale`, `process_data_partial` after `process_io_unavailable`,
-- and the first draft of the Capability insert -- so the cost of the convention
-- being only a convention is three near-misses in eight increments.
--
-- The block is also *contiguous* now, which it was not: eleven `sampling.*` keys sat
-- in the middle of the `reason.*` run, so a first draft that rewrote the block as
-- one range dropped them and then re-appended them and produced a file with 308
-- reason keys instead of 156.  Both properties are one function so the two
-- cannot be checked differently.
local function reason_block_state(text)
  local keys, in_block, interrupted, broken = {}, false, false, 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local key = line:match('^  (reason%.[%w_]+):%s+"')
    if key then
      -- Interruption is judged on *re-entry*: a reason key that follows a sibling
      -- group means the run was broken.  The first draft tested "any sibling key
      -- once a reason key has been seen", which flags every key after the block
      -- -- in every catalogue a different group -- so it could never be
      -- satisfied, and the second tested `interrupted` instead of setting it,
      -- which is why the probe for a split run caught that one.
      if not in_block and #keys > 0 then interrupted = true end
      if in_block and key < keys[#keys] then broken = broken + 1 end
      keys[#keys + 1] = key
      in_block = true
    elseif in_block and line:match("^  [%w_]+[%w_.]*:%s+") then
      in_block = false
    end
  end
  return keys, not interrupted, broken
end
for _, locale in ipairs(locales) do
  local path = "locales/" .. locale .. ".yml"
  local handle = assert(io.open(path))
  local text = handle:read("*a")
  handle:close()
  local keys, contiguous, broken = reason_block_state(text)
  assert(#keys > 100,
    path .. " yielded " .. #keys .. " `reason.*` keys, so the order clause "
      .. "below is not running: every catalogue carries more than a hundred")
  assert(broken == 0,
    path .. " has " .. broken .. " `reason.*` key(s) out of alphabetical "
      .. "order -- " .. keys[#keys] .. " follows a key that sorts after it.  "
      .. "YAML does not care, so nothing else will fail; the order is what a "
      .. "reader relies on to see a key that is missing.")
  assert(contiguous,
    path .. " has a non-`reason.` group interleaved with its `reason.*` block, "
      .. "so the keys are not one run.  A rewrite that treats the block as a "
      .. "range will drop what is in between.")
end
-- Probed, because a rule that matches nothing is satisfied by an empty file.
do
  local flat = '  reason.b: "b"\n  reason.a: "a"\n'
  local keys, _, broken = reason_block_state(flat)
  assert(#keys == 2 and broken == 1, "a descending pair must be counted")
  local ok = '  reason.a: "a"\n  reason.b: "b"\n'
  local ok_keys, _, ok_broken = reason_block_state(ok)
  assert(#ok_keys == 2 and ok_broken == 0, "an ascending pair must not be counted")
  local split = '  reason.a: "a"\n  other.b: "b"\n  reason.c: "c"\n'
  local _, split_contiguous = reason_block_state(split)
  assert(split_contiguous == false, "a sibling group breaks contiguity")
  local _, single_contiguous = reason_block_state('  reason.a: "a"\n  other.b: "b"\n')
  assert(single_contiguous == true,
    "a sibling group *after* the last reason key is not inside the block")
end

-- Every `reason.*` key in every catalogue is decided by one function, so the
-- clauses and the self-tests below them cannot be built differently.
--
-- **The machine-only case used to be a silent *allow*.**  The rule was
-- `not known[code] and not machine_only[code]`, which passes when a
-- machine-only code *does* carry a key -- so a catalogue key for a code nothing
-- renders was not an error, it was a reason to leave the key alone, and
-- twenty-four of them (twenty-two export-only codes, two dropped input events)
-- had been sitting in all ten languages since before this rule existed.  Being
-- permissive there is not neutral: a translation nothing can display is the
-- cheapest kind of code to add and the most expensive to notice, because
-- nothing about it is ever wrong at runtime.  So the answer is the other
-- direction -- machine-only means *untranslated*, stated as a clause that fires.
local function classify(code)
  for _, listed in ipairs(interface_reasons) do
    if listed == code then return "interface" end
  end
  if machine_only[code] then return "machine_only" end
  return "unlisted"
end

-- Returns every way a catalogue is inconsistent with the two lists; empty means
-- consistent.  Sorted so a failure lists the same problems in the same order on
-- every run.
local function catalogue_problems(label, messages)
  local problems, present = {}, {}
  for key in pairs(messages) do
    local code = key:match("^reason%.([a-z][a-z0-9_]*)$")
    if code then present[code] = true end
  end
  for _, code in ipairs(interface_reasons) do
    if not present[code] then
      problems[#problems + 1] = label .. " lacks reason." .. code
        .. ", and a rendered surface can show it"
    end
  end
  for code in pairs(present) do
    local where = classify(code)
    if where == "unlisted" then
      problems[#problems + 1] = label .. " carries reason." .. code
        .. " which is absent from both the interface inventory and `machine_only`"
    elseif where == "machine_only" then
      problems[#problems + 1] = label .. " carries reason." .. code
        .. " for a code no rendered surface shows, so it is a translation that "
        .. "cannot be displayed: " .. machine_only[code]
    end
  end
  table.sort(problems)
  return problems
end

-- The rule is tested on its own terms, on a real catalogue rather than on a
-- synthetic one, because each case is a single deletion or insertion away from
-- the shipped files and a fixture that only resembles them proves less.  Three
-- failures, one per direction, each named after the key it moves.
local reference = assert((function()
  local ok, module = pcall(require, "wtop.generated.locales.en-US")
  return ok and module or nil
end)())
local function with_reference(mutate)
  local copy = {}
  for key, value in pairs(reference.messages) do copy[key] = value end
  mutate(copy)
  return catalogue_problems("probe", copy)
end
local function must_complain(label, expected, mutate)
  local problems = with_reference(mutate)
  local found = false
  for _, problem in ipairs(problems) do
    if problem:find(expected, 1, true) then found = true end
  end
  if not found then
    error("the catalogue rule did not object to " .. label .. "; it reported "
      .. (#problems == 0 and "no problem at all"
        or table.concat(problems, " / ")), 0)
  end
end
must_complain("an interface code losing its translation",
  "lacks reason." .. interface_reasons[1],
  function(copy) copy["reason." .. interface_reasons[1]] = nil end)
must_complain("a machine-only code being translated",
  "reason.calls", function(copy) copy["reason.calls"] = "translated anyway" end)
must_complain("a code on neither list",
  "reason.probe_on_neither_list",
  function(copy) copy["reason.probe_on_neither_list"] = "stray" end)
-- And the reference itself, so the three probes cannot pass against a
-- catalogue that was already inconsistent in the same way.
assert(#catalogue_problems("en-US", reference.messages) == 0,
  "the shipped en-US catalogue is inconsistent with the two lists, so the three "
    .. "probes above proved nothing: "
    .. table.concat(catalogue_problems("en-US", reference.messages), " / "))

for _, locale in ipairs(locales) do
  local ok, module = pcall(require, "wtop.generated.locales." .. locale)
  assert(ok and type(module.messages) == "table",
    "generated catalog for " .. locale .. " must be loadable")
  local problems = catalogue_problems(locale, module.messages)
  assert(#problems == 0,
    "these catalogues disagree with the two lists, in both directions:\n  "
      .. table.concat(problems, "\n  "))
end

-- **The sixth shape: a message id assembled at runtime.**  Every rule in this
-- file so far reads a *literal*.  `tui.lua` also builds one out of a value --
-- `translated(translator, "reason." .. tostring(apply_error), ...)` -- so the
-- code reaches the interface without ever appearing as a code-shaped literal
-- anywhere a scan can see, and the vocabulary is whatever the callee returns.
--
-- A scan cannot follow that far, so this table *declares* the vocabulary per
-- site and the guard checks three things about it: that the product's set of
-- assembly sites equals this table's keys, that every declared code is
-- inventoried, and that the rule which finds a site can still find one.  The
-- declaration is the honest form of an interprocedural analysis this file
-- cannot perform -- and it is a declaration in the same sense `machine_only` is:
-- a claim with a reason attached, which the next two clauses can contradict.
--
-- Measured, this is not a hypothetical shape.  There are six sites, they all
-- live in `tui.lua`, and their vocabularies close -- except for the one that
-- found the bug, recorded on `move_error` below.
--
-- The table is a map keyed by variable rather than by site because two sites
-- share a variable with nothing in common between them: `switch_error` is
-- assigned by `switch_workspace` at one site and by `save_workspace` at the
-- other, and a site whose variable has already been assigned by *both* calls
-- before it is formatted carries the union of the two vocabularies.  The
-- strictness is not in the table but in `covers`, which insists that every
-- callee the text shows for a site is one this table names for that variable --
-- so a new call assigned to an existing variable name cannot hide behind an
-- entry written for the old one, and the union is always a superset, which is
-- the safe direction for a rule about what a user can be shown.
local ASSEMBLED = {
  apply_error = {
    callees = { "replace_focused_widget", "add_focused_widget" },
    -- Both map every inner error through `layout_refusal`.
    codes = { "cannot_remove_last_widget", "layout_rejected",
      "widget_already_placed", "widget_not_in_page" } },
  move_error = {
    callees = { "move_focused_to" },
    -- `move_focused_to`'s own two argument guards, plus `layout_refusal`'s
    -- four.  Until this increment it returned the layout model's string
    -- unfiltered, and `Layout.move` answers a target that is not on the page
    -- with `"widget_not_found:" .. target_widget` -- measured on this host as
    -- `widget_not_found:not_a_widget_on_this_page`, assembled into the message
    -- id `reason.widget_not_found:not_a_widget_on_this_page`, which no
    -- catalogue can hold, so the status line fell back to the raw spelling in
    -- every language.  Its two own codes are argument validation the only
    -- production caller cannot reach: `tui.lua` passes `target.id` from the
    -- overlay's own target list, and `selection.position`, which its only
    -- writer sets to `"before"` or `"after"`.
    codes = { "cannot_remove_last_widget", "invalid_position",
      "invalid_target_widget", "layout_rejected", "widget_already_placed",
      "widget_not_in_page" } },
  remove_error = {
    callees = { "delete_workspace", "remove_focused_widget" },
    codes = { "cannot_remove_last_widget", "last_workspace",
      "layout_rejected", "unknown_workspace", "widget_already_placed",
      "widget_not_in_page" } },
  rename_error = {
    callees = { "rename_workspace" },
    -- The name vocabulary of `checked_workspace_name`, plus its own two.
    codes = { "invalid_workspace_name", "unknown_workspace",
      "workspace_name_length", "workspace_name_must_be_text",
      "workspace_name_taken" } },
  switch_error = {
    callees = { "switch_workspace", "save_workspace" },
    -- `_activate_workspace`, which both reach, returns only `true` or asserts,
    -- so it contributes no code.
    codes = { "invalid_workspace_name", "unknown_workspace",
      "workspace_limit_reached", "workspace_name_length",
      "workspace_name_must_be_text" } },
}

-- Comments are stripped first, and that is not tidiness.  The fix for the bug
-- this table was written for sits directly above the `layout_refusal` call and
-- quotes the very expression it removes, so a scan that read raw lines would
-- report a seventh site in `workspace.lua` that does not exist and the
-- two-way check would fail on the fix itself.
local function assembly_site(line)
  local code = line:gsub("%-%-.*$", "")
  return code:match('"reason%.%s*"%s*%.%.%s*tostring%s*%(%s*([%w_]+)%s*%)')
end
-- The scan reads every file under `src/wtop`, not just the one the sites happen
-- to be in today, and it resolves each site's variable back to the call that
-- assigned it.  Resolving the callee is the part that earns the table its keep:
-- without it a *new* site reusing a known variable name -- `apply_error =
-- some_other_call(...)` -- would be declared correct by the old entry and its
-- codes would be unchecked.  Assignment can be many lines above the site (16 for
-- `move_error`), so the state is per file and ordered.
local function assembly_sites()
  local sites = {}
  local listing = assert(io.popen("ls src/wtop/*.lua src/wtop/*/*.lua "
    .. "src/wtop/*/*/*.lua 2>/dev/null"))
  local paths = {}
  for path in listing:lines() do paths[#paths + 1] = path end
  listing:close()
  for _, path in ipairs(paths) do
    local handle = assert(io.open(path))
    local assigned, number = {}, 0
    for line in handle:lines() do
      number = number + 1
      for variable, method in
          line:gmatch("([%w_]+)%s*=%s*[%w_.]+:([%w_]+)%s*%(") do
        assigned[variable] = assigned[variable] or {}
        assigned[variable][method] = true
      end
      local variable = assembly_site(line)
      if variable then
        -- A copy, not the map itself.  `assigned[variable]` keeps growing as
        -- the scan walks the file, and a site fifteen hundred lines above its
        -- callee's second use would be checked against that later use too --
        -- which is exactly what happened the first time this ran, and it
        -- reported `remove_focused_widget` against the `delete_workspace` site.
        local callees = {}
        for method in pairs(assigned[variable] or {}) do callees[method] = true end
        sites[#sites + 1] = { variable = variable, path = path,
          line = number, callees = callees }
      end
    end
    handle:close()
  end
  return sites
end
local function names_of(set)
  local names = {}
  for name in pairs(set) do names[#names + 1] = name end
  table.sort(names)
  return names
end
local function covers(entry, site)
  if not entry then return false end
  -- An empty callee set is a subset of everything, so without this a site
  -- whose variable is never assigned *in this file* would be accepted by the
  -- entry for its variable and its vocabulary would go unchecked -- which is
  -- what happened when comment stripping was removed and `workspace.lua`'s
  -- quoted expression was read as a site: `move_error` has no assignment there,
  -- so the set is empty, and the first version of this function said yes.
  if next(site.callees) == nil then return false end
  for method in pairs(site.callees) do
    local listed = false
    for _, name in ipairs(entry.callees) do
      if name == method then listed = true end
    end
    if not listed then return false end
  end
  return true
end
local used, produced = {}, 0
for _, site in ipairs(assembly_sites()) do
  produced = produced + 1
  local entry = ASSEMBLED[site.variable]
  local covered = covers(entry, site)
  if covered then used[entry] = true end
  assert(covered,
    "an assembled message id is undeclared: `" .. site.path .. "` line "
      .. site.line .. " formats `" .. site.variable .. "` into `reason.`, and "
      .. (entry == nil
        and "no entry in the table above names that variable, so the codes it "
          .. "can carry are not checked at all"
        or next(site.callees) == nil
          and "nothing in this file assigns it, so the codes it can carry are "
            .. "not knowable from the text"
          or "the calls that assign it -- " .. table.concat(names_of(site.callees),
            ", ") .. " -- are not among this table's callees for it ("
          .. table.concat(entry.callees, ", ") .. ")")
      .. ".  Add the variable with its measured vocabulary.")
end
for variable, entry in pairs(ASSEMBLED) do
  assert(used[entry],
    "the table declares `" .. variable .. "` reached from "
      .. table.concat(entry.callees, ", ")
      .. ", but no site in `src/wtop` assembles a `reason.` id from it that "
      .. "way any more: the shape moved, and a stale entry is worse than none "
      .. "because it is checked")
  for _, code in ipairs(entry.codes) do
    assert(classify(code) ~= "unlisted",
      "the assembled message id for `" .. variable .. "` can carry `"
        .. code .. "`, and that code is in neither the interface inventory nor "
        .. "`machine_only`, so a user who hits it sees the raw code")
  end
end
assert(produced > 0,
  "the assembled-message-id rule matched no site in `src/wtop`, so it is not "
    .. "running: `tui.lua` formats six of them, and a rule that reads none of "
    .. "them is the same as no rule")

-- The declaration is checked in both directions, because the two ways it goes
-- wrong look nothing like each other.  The loop above catches a code declared
-- in neither list.  This one catches the opposite: an `interface_reasons` code
-- -- which is the guard's own claim that the code reaches a *localised*
-- -- interface -- spelled in one of the two modules that hold the assembled
-- sites' callees, and absent from every entry.  That combination is a user who
-- renames a workspace, hits the refusal, and is shown the raw code in every
-- language, because `translated` falls back to the argument when the message id
-- is not in the catalogue.
--
-- The scope is the two modules and not every returned code literal in them,
-- because that broader rule was measured first and it does not work: those two
-- modules return **52** code-shaped literals and the table declares **13**, and
-- most of the other 39 are argument validation that no production caller can
-- reach -- `invalid_position`, `invalid_max_depth`, `invalid_widget_id` and
-- thirty-six more.  A rule over all of them would fire on all of them, and a
-- guard that fires on correct code stops being read.  This direction has no
-- such cost: measured, all eleven interface codes spelled in these two modules
-- are declared, so the clause is satisfiable today and only a future omission
-- can trip it.
local function undeclared_in_modules(codes, declared, text)
  local missing = {}
  for _, code in ipairs(codes) do
    if not declared[code] and text:find('"' .. code .. '"', 1, true) then
      missing[#missing + 1] = code
    end
  end
  table.sort(missing)
  return missing
end
local declared_codes = {}
for _, entry in pairs(ASSEMBLED) do
  for _, code in ipairs(entry.codes) do declared_codes[code] = true end
end
local module_text = ""
for _, path in ipairs({ "src/wtop/workspace.lua", "src/wtop/model/layout.lua" }) do
  local handle = assert(io.open(path))
  module_text = module_text .. handle:read("*a") .. "\n"
  handle:close()
end
-- The clause above is satisfiable by an empty `module_text`, and deleting the
-- read that fills it is the cheapest way to turn it off without touching the
-- assert.  That is not hypothetical: M209 did exactly this and passed, which is
-- the same failure as the `produced > 0` check above and the per-shape count
-- this file already learned to distrust.  The figure is measured, not guessed:
-- eleven `interface_reasons` codes are spelled in these two modules today, and
-- a count that fell to zero would mean the modules moved rather than that the
-- clause became correct.
local spelled_here = 0
for _, code in ipairs(interface_reasons) do
  if module_text:find('"' .. code .. '"', 1, true) then spelled_here = spelled_here + 1 end
end
assert(spelled_here > 0,
  "no `interface_reasons` code is spelled in `src/wtop/workspace.lua` or "
    .. "`src/wtop/model/layout.lua`, so the assembled-declaration clause below "
    .. "is not running: it reads those two files and matches nothing, which is "
    .. "indistinguishable from a clause that is satisfied")
local undeclared_here = undeclared_in_modules(interface_reasons, declared_codes, module_text)
assert(#undeclared_here == 0,
  "these codes are in `interface_reasons`, so the guard claims they reach a "
    .. "localised interface, and they are spelled in the modules whose returns "
    .. "are formatted into `reason.` message ids -- but no entry of the "
    .. "assembled table declares them: "
    .. table.concat(undeclared_here, ", ")
    .. ".  `translated` falls back to the raw code for a message id no catalogue "
    .. "holds, so a user who hits one of these sees it in English snake_case in "
    .. "every language.  Add the code to the entry for the variable it can "
    .. "reach.")

-- The clause is tested on its own terms, because a rule that matches nothing is
-- satisfiable by an empty table.  Two probes: one that must fire, and the
-- exact tree this file is about, which must not.
assert(#undeclared_in_modules({ "widget_not_in_page" }, {},
  'return false, "widget_not_in_page"') == 1,
  "an interface code spelled in a callee's return and declared nowhere must be caught")
assert(#undeclared_in_modules({ "widget_not_in_page" }, { widget_not_in_page = true },
  'return false, "widget_not_in_page"') == 0,
  "the same code with its declaration present must not be caught")
assert(#undeclared_in_modules({ "workspace_limit_reached" }, {},
  'return false, "unknown_workspace"') == 0,
  "a code that is spelled nowhere in the modules is not this clause's business")

-- The rule is tested on its own terms, because the third clause above is
-- satisfiable by a rule that matches nothing.
assert(assembly_site('reason = translated(t, "reason." .. tostring(move_error),')
  == "move_error", "the assembly rule must read a `tostring(<name>)` operand")
assert(assembly_site('  -- quoting "reason." .. tostring(move_error) in a comment')
  == nil, "a commented-out site is not a site, and this line is in the product")
assert(assembly_site('    local reason = "a_real_code"') == nil,
  "a literal reason is not an assembled one; the two shapes are different rules")

-- And the inventory is not just a list somebody maintains: every reason the
-- product spells as a literal has to be in it, or in `machine_only`.
--
-- This rule has been widened four times, and each widening found real codes that
-- were reaching a localised interface as an English token, so the sequence is
-- worth keeping.  First it matched only `reason = "code"` and found two gaps.
-- Then: **the shape the product uses most is `reason = <fallback> or "code"`**,
-- and a function's return value is a third, `return nil, ... or "code"` --
-- seventeen codes were written in those two and none was translated.  Third:
-- `reason = quality and "measured" or "estimated"`, a conditional value, which
-- the second pattern could not see because its literal is followed by more
-- tokens than punctuation.  Fourth, and this is the one that matters, **the
-- rule is now about the position of a literal inside a value expression rather
-- than a list of shapes**, because a list of shapes is what produced the first
-- three misses.  A code-shaped literal is a reason when it opens the value or
-- follows a bare `and`, `or` or `..`; a literal after `==`, `~=`, `<`, `>`,
-- `<=` or `>=` is a comparison operand and not a code, which is what
-- `type(x) == "table"` is.  That last distinction is why the exemption list this
-- rule used to carry is gone: the old rule could not tell a comparison from a
-- value and exempted the literals a comparison might introduce, while the
-- positional rule decides by position, and measured over the tree it matches no
-- comparison operand at all.
--
-- What the rule still cannot see, stated rather than hidden.  It reads the line
-- that holds `reason =`, so a literal written on a continuation line is
-- invisible, and most reason fields in the tree carry no literal on their own
-- line at all -- pass-throughs such as `capability.reason`, values from a parse
-- function, and error messages that are sentences rather than codes.  Counted on
-- 2026-10-02 by `reason%s*=` minus `local reason =` over `src/wtop`, which is the
-- guard's own position rule and not the guard's shape rule: 260 reason fields,
-- 97 of them with a string literal on the same line and 163 without.  The count
-- is a measurement of that stated method rather than something this file
-- enforces, so it drifts as collectors are added; what it sizes is the blind
-- spot, not a threshold.
--
-- The two-step measurement over the same file (a literal assigned to a local,
-- that local used directly as a `reason =` value) found exactly one non-code
-- among them: `missing CPU counters`, returned by `cpu_data` in the macOS/Windows
-- collector and reaching the reason field on that path, which is English prose in
-- a field the presentation layer localises and which no catalog can carry.  **It
-- was fixed rather than recorded, and the reason it had been parked was wrong**:
-- the note said the path could not be exercised on this host, but the real
-- macOS and Windows native modules are unreachable while `portable.lua` itself is
-- driven by a fake native module on every host, so the branch was one line of
-- fixture away.  `cpu_data` now returns nothing for either value and the caller
-- publishes `cpu_counters_missing`, translated in all ten languages; the story is
-- in `docs/PLAN.md`.  It is repeated here because this paragraph is the one a
-- reader consults about the rule's blind spot, and leaving a fixed defect
-- described as open is the same defect the file exists to catch.
--
-- Two narrower measurements, both negative and both kept because a rule that
-- looks tighter than it is is the thing this file exists to prevent.  A wider
-- declaration test was tried for `local a, b, reason = "x"`, and there are no
-- multi-name declarations carrying a string literal anywhere in `src/wtop`; and
-- a `^%s*local` anchor cannot work at all here, because `grep -rn` prefixes
-- every line with `path:lineno:`, so the declaration test reads the text before
-- the token instead of the start of the line.
--
-- Returns the literals on a line, tagged with the shape they came from, so the
-- caller can insist that *each* shape is still being matched.  A single count
-- cannot do that: the shapes are what the rule is made of, and a rule that
-- quietly stopped matching one of them would look identical to a rule that
-- stopped matching none.
local function reason_literals(line)
  local found = {}
  -- Shape 1: a literal in value position inside a `reason =` field.
  local from = 1
  while true do
    local at = line:find("reason%s*=", from)
    if not at then break end
    local before = at > 1 and line:sub(at - 1, at - 1) or ""
    -- `local reason = ...` is a variable, not a field.  The token before the
    -- name is the test: `grep -rn` puts `path:lineno:` in front, so anchoring
    -- at the start of the line would never match anything.
    local is_local = line:sub(math.max(1, at - 6), at - 1):match("%f[%w_]local%s+$") ~= nil
    if not before:match("[%w_]") and not is_local then
      local eq = line:find("=", at, true)
      local value = eq and line:sub(eq + 1) or ""
      local cursor = 1
      while true do
        local open_at = value:find('"', cursor, true)
        if not open_at then break end
        local close_at = value:find('"', open_at + 1, true)
        if not close_at then break end
        local head = value:sub(1, open_at - 1)
        local literal = value:sub(open_at + 1, close_at - 1)
        -- Position, not shape, is what makes a literal the value.  `and`, `or`
        -- and `..` are the operators that can precede a value; `==`, `~=`, `<`,
        -- `>`, `<=`, `>=` and `#` introduce a comparison operand, and an operand
        -- is never preceded by whitespace, `and`, `or` or `..`, so testing for
        -- those four is enough and testing for the operators too would be a
        -- clause that cannot fire: measured over the 157 literals in this
        -- tree's reason values, none is both, and the seven comparison operands
        -- present are already rejected here.
        local opens_value = head:match("^%s*$") ~= nil
          or head:match("[%s]and[%s]+$") ~= nil
          or head:match("[%s]or[%s]+$") ~= nil
          or head:match("%.%.%s*$") ~= nil
        if opens_value and literal:match("^[a-z][a-z0-9_]*$") then
          found[#found + 1] = { code = literal, shape = "value" }
        end
        cursor = close_at + 1
      end
    end
    from = at + 1
  end
  -- Shape 2: a return whose last literal is the fallback of a `reason` variable.
  if line:find("return") and line:find("reason") then
    local literal = line:match('or "([a-z][a-z0-9_]*)"%)?%s*$')
      or line:match('or "([a-z][a-z0-9_]*)"%)?%s*,%s*$')
    if literal then found[#found + 1] = { code = literal, shape = "return" } end
  end
  return found
end

-- The rule is tested on its own terms before it is pointed at the product.
-- Counting what the scan finds in `src/wtop` is not enough: measured over the
-- tree, the value-position literals break down as 86 at the start of a value,
-- 14 after `and`, 24 after `or` and none at all after `..`, and a guard that
-- only insisted "some literal matched" still passed with the `and` clause
-- deleted -- fourteen codes quietly outside the rule, and the number that grows
-- next time someone writes `reason = flag and "new_code" or nil`.  So each
-- position the rule claims to read gets a line that must produce its code, and
-- each position it claims to skip gets a line that must produce nothing.
local function yields(line)
  local codes = {}
  for _, hit in ipairs(reason_literals(line)) do codes[hit.code] = hit.shape end
  return codes
end
local function must_yield(line, code, shape)
  local codes = yields(line)
  if codes[code] ~= shape then
    error("the reason rule does not read `" .. code .. "` as a `" .. shape
      .. "` in " .. line .. "; got "
      .. (codes[code] and ("`" .. code .. "` as `" .. codes[code] .. "`")
        or "no code at all"), 0)
  end
end
local function must_not_yield(line, code, why)
  if yields(line)[code] ~= nil then
    error("the reason rule reads `" .. code .. "` out of " .. line
      .. " but that literal is " .. why, 0)
  end
end
must_yield('    reason = "probe_plain",', "probe_plain", "value")
must_yield('    reason = fallback or "probe_or",', "probe_or", "value")
must_yield('    reason = truncated and "probe_and" or nil,', "probe_and", "value")
must_yield('    reason = prefix .. "probe_concat",', "probe_concat", "value")
must_yield('    return nil, type(reason) == "string" and reason or "probe_return"',
  "probe_return", "return")
must_not_yield('    reason = type(x) == "probe_operand"',
  "probe_operand", "a comparison operand and not a value")
must_not_yield('  local reason = "probe_local"',
  "probe_local", "a local variable and not a field")
must_not_yield('    budget_reason = "probe_prefix"',
  "probe_prefix", "a different field whose name ends in `reason`")

local scan = assert(io.popen("grep -rnE 'reason[ \\t]*=|return .*reason' src/wtop"))
-- One set, built by a function next to the two lists it is built from and used
-- by both scans, so that the two cannot be built differently.  It was two loops
-- filling a table literal a hundred lines above where it is read, and the
-- version that could not see `machine_only` produced a failure whose mechanism
-- I did not establish -- a diagnostic inserted *inside* the loop showed every
-- key being set, and the same lookup twenty lines later came back nil.  The
-- honest record is that the mechanism is unexplained and the restructure is
-- what the code now has; the measurement that prompted it is not a claim about
-- Lua, it is a claim that a lookup used by two scans at two distant points
-- should not be assembled at the first of them.
local function inventoried_codes()
  local set = {}
  for _, code in ipairs(interface_reasons) do set[code] = true end
  for code in pairs(machine_only) do set[code] = true end
  return set
end
local inventoried = inventoried_codes()
local scanned, shapes = 0, { value = 0, ["return"] = 0 }
for line in scan:lines() do
  for _, hit in ipairs(reason_literals(line)) do
    scanned = scanned + 1
    shapes[hit.shape] = shapes[hit.shape] + 1
    assert(inventoried[hit.code],
      "src/ spells `" .. hit.code .. "` as a reason, and it is in neither the "
        .. "interface inventory nor `machine_only`, so a user who hits it sees "
        .. "the raw code.  Add it to one or the other: the second is an explicit "
        .. "statement that it never reaches the interface.")
  end
end
scan:close()
for _, shape in ipairs({ "value", "return" }) do  assert(shapes[shape] > 0,
    "the source scan matched no `" .. shape .. "` reason literals, so half the "
      .. "rule is not running: a literal in value position in a `reason =` field "
      .. "and a `return nil, ... or \"code\"` fallback are the two places this "
      .. "product spells a reason, and the codes written in the first were "
      .. "invisible while the rule matched only a trailing literal.  Either the "
      .. "pattern stopped matching or the shape was renamed.")
end

-- The same rule, pointed at the other half of the product.  The scan above
-- reads `src/wtop`, and a reason is not only written in Lua: `wtop_native.c`
-- assigns the executor's own failure codes to a local and pushes it straight
-- into the result's `reason` field, and the three vendor modules each assign
-- three codes to a provider struct the Lua collector copies through.  Measured,
-- that is **five untranslated codes reaching the interface** -- `cancelled`,
-- `cancel_callback_failed`, `poll_failed`, `waitid_failed`, `waitpid_failed` --
-- which the Lua scan could not see in principle, and nine more that reach only
-- the JSON export.  A scan that reads one language and is described as reading
-- the product is a scan with a hole in the other direction, and this is the
-- closure of it.
--
-- Two shapes, both measured: an assignment to something whose name ends in
-- `reason`, and a literal pushed on the line before `lua_setfield(L, -2,
-- "reason")`.  The second is why one line of context is read: the literal and
-- the field it becomes are on separate lines, so a strictly per-line rule sees
-- the push and not the field.  A variable pushed as the value -- `internal_reason`
-- -- is resolved through the first shape, which is where it is assigned.
local function c_reason_codes()
  local assigned_by_variable, from_assignment, from_push = {}, {}, {}
  local listing = assert(io.popen("ls native/*.c"))
  for path in listing:lines() do
    local handle = assert(io.open(path))
    local lines = {}
    for line in handle:lines() do lines[#lines + 1] = line end
    handle:close()
    for index, line in ipairs(lines) do
      for variable, code in
          line:gmatch('([%w_%.]*[Rr]eason)%s*=%s*"([a-z][a-z0-9_]*)"') do
        assigned_by_variable[variable] = code
        from_assignment[#from_assignment + 1] = { code = code, shape = "assign" }
      end
      if line:find('lua_setfield%s*%(L,%s*%-2,%s*"reason"%)') and index > 1 then
        local previous = lines[index - 1]
        local code = previous:match('lua_pushliteral%s*%(L,%s*"([a-z][a-z0-9_]*)"%)')
          or previous:match('lua_pushstring%s*%(L,%s*([%w_]+)%)')
        if code and assigned_by_variable[code] then
          from_push[#from_push + 1] = {
            code = assigned_by_variable[code], shape = "push" }
        end
      end
    end
  end
  listing:close()
  local found = {}
  for _, hit in ipairs(from_assignment) do found[#found + 1] = hit end
  for _, hit in ipairs(from_push) do found[#found + 1] = hit end
  return found
end

-- The C rule is tested on its own terms for the same reason the Lua one is: a
-- count of "some literal matched" cannot tell a rule that lost a shape from a
-- rule that lost all of them.
local function c_yields_assignment(line)
  -- Two captures: the lvalue, then the literal.  A generic-for with one loop
  -- variable takes the *first* capture, which is the lvalue -- so the first
  -- version of this helper returned `amdsmi.reason` and failed on the shape it
  -- was written to accept.
  for _, code in line:gmatch('([%w_%.]*[Rr]eason)%s*=%s*"([a-z][a-z0-9_]*)"') do
    return code
  end
  return nil
end
local function c_must_yield(line, expected, why)
  local got = c_yields_assignment(line)
  if got ~= expected then
    error("the native reason rule read " .. tostring(got) .. " where "
      .. tostring(expected) .. " was expected in " .. line .. " -- " .. why, 0)
  end
end
c_must_yield('        amdsmi.reason = "amdsmi_library_not_found";',
  "amdsmi_library_not_found", "an assignment to a `*.reason` field is a reason")
c_must_yield('        internal_reason = "waitpid_failed";',
  "waitpid_failed", "an assignment to a local whose name ends in `reason` is one too")
c_must_yield('        lua_pushliteral(L, "reason");', nil,
  "a push of the field name itself is a name, not a code")

local c_found = c_reason_codes()
local c_shapes = { assign = 0, push = 0 }
for _, hit in ipairs(c_found) do
  c_shapes[hit.shape] = c_shapes[hit.shape] + 1
  assert(inventoried[hit.code],
    "native/ spells `" .. hit.code .. "` as a reason, and it is in neither the "
      .. "interface inventory nor `machine_only`, so a user who hits it sees the "
      .. "raw code.  This is a code the Lua scan cannot see in principle, which "
      .. "is why the scan reads the native sources too.")
end
for _, shape in ipairs({ "assign", "push" }) do assert(c_shapes[shape] > 0,
    "the native scan matched no `" .. shape .. "` reason literals, so part of "
      .. "the rule is not running: the executor sets its `reason` field from a "
      .. "push on a separate line, and the vendor modules assign to a provider "
      .. "field, and either half can stop matching without the other noticing.")
end

-- The third direction, which is the one that was missing: not "every code the
-- product spells is inventoried" and not "every inventoried code is
-- translated", but **"every inventoried code is one the product can still
-- produce"**.  Measured, that question had never been asked, and it is the only
-- one of the three that catches a code nobody emits any more -- a rename, a
-- deleted branch, a vendor library dropped -- which leaves ten languages of
-- strings and a list entry asserting a code that does not exist.
--
-- The test is spelling, not reachability, and deliberately so: "spelled
-- somewhere in `src/` or `native/`" is checkable, while "reaches a reason field
-- some presentation surface renders" needs a question this file cannot ask.
-- The gap between the two is not hidden: it is measured and classified in
-- `docs/PLAN.md`, and the four groups it found each have a different reason
-- for being satisfied -- a pairing assertion that names the code, the
-- assembled-message-id table, the native scans, and one code that is
-- classified but still unguarded.  Thirty-three of the 153 are spelled
-- somewhere this rule's positional test cannot see, and none of them is a dead
-- translation, which is the measurement that closed it.
local spelled = {}
local spelling = assert(io.popen("grep -rhoE '\"[a-z][a-z0-9_]*\"' src native"))
for word in spelling:lines() do
  local code = word:match('^"([a-z][a-z0-9_]*)"$')
  if code then spelled[code] = true end
end
spelling:close()
local unspellable = {}
for _, code in ipairs(interface_reasons) do
  if not spelled[code] then unspellable[#unspellable + 1] = code end
end
for code in pairs(machine_only) do
  if not spelled[code] then unspellable[#unspellable + 1] = code end
end
if #unspellable > 0 then
  table.sort(unspellable)
  error("these codes are inventoried and translated, and the product does not "
    .. "spell any of them in `src/` or `native/`: " .. table.concat(unspellable, ", ")
    .. ".  Either the code was renamed and the inventory was not, or a branch was "
    .. "deleted and the translation is now ten languages of a string no user can "
    .. "be shown.  Remove it from both lists, or restore what spells it.", 0)
end

-- The presentation layer must return the translated form, not the code, and
-- must keep unknown codes readable instead of inventing a translation.
local I18n = require("wtop.i18n")
local chinese = assert(I18n.new({ locale = "zh-CN" }))
-- A code that is in the inventory, and said to be one.  This used to be
-- `query_denied`, which is now `machine_only` because the Windows native module
-- is the only thing that spells it and no presentation surface reads it -- so
-- removing its translation, which is what a machine-only code is for, broke this
-- assertion.  That is the honest shape of the mistake: the key was not reachable
-- from the product and was being kept alive by a test that used it as a fixture.
local shown = Technical.reason(chinese, "device_enumeration_truncated")
assert(type(shown) == "string" and shown ~= "device_enumeration_truncated" and #shown > 0,
  "device_enumeration_truncated must have a Chinese display form")
assert(Technical.state(chinese, "partial") == "部分可用",
  "state codes keep their localized display form")
assert(Technical.reason(chinese, "not_a_real_reason") == "not_a_real_reason",
  "unknown codes fall back to the raw spelling")
assert(Technical.reason(chinese, 123) == 123,
  "non-string values pass through unchanged")

-- A fifth scan family, for the one shape the positional rule cannot see and the
-- assembled-message-id table does not cover: a `Capability` constructor's first
-- *positional argument*.  `Capability.unavailable(reason, options)` and its
-- siblings put that argument into `capability.reason`, which
-- `view_model.lua:1558` and `:1588` copy into the Collectors and Inspectors
-- tables, and both tables render it through `Technical.reason` (`view_model.lua`
-- 2445 and 2461).  So a code-shaped literal in that position reaches a
-- localised interface exactly as a `reason =` literal does, and nothing
-- checked it.
--
-- **It found three on the first run, and the finding is the argument for the
-- family.** `socket_tables_partial` has a translation in all ten languages;
-- `socket_tables_denied` and `socket_tables_unavailable`, spelled eleven lines
-- away in the same function and meaning the same thing to a user, have none --
-- because the first is written at a `reason =` field and the other two are
-- written as call arguments.  `smartctl_not_found` is the same shape.  A user
-- on a host with no `smartctl`, or without permission to read the socket
-- tables, was shown `smartctl_not_found` in English snake_case in every
-- language, through a `Technical.reason` lookup that found nothing and fell
-- back to its argument.  All three are inventoried and translated now.
--
-- The scope is deliberate and was measured before the rule was written.  There
-- are eleven `Capability` sites whose first argument is a code-shaped literal
-- and sixty-eight whose first argument is not: `err.message` and
-- `list_error.message` mostly, which are strings the *system* produced and which
-- this project's boundary leaves untranslated on purpose.  The family therefore
-- matches literals only, and a site whose argument spans a line is reported
-- rather than skipped -- one exists today (`inventory.lua`, where the literal
-- sits on the following line) and its code is already inventoried, so the
-- report is a statement about the scan, not a defect.
-- `Capability.new` is excluded, and the exclusion is the whole subtlety here.
-- It is the low-level constructor the three named helpers wrap, and its first
-- argument is a *state* from a five-member list -- `available`, `unavailable`,
-- `denied`, `degraded`, `error` -- while theirs is a reason.  Matching the
-- constructor reported all five state names as unlisted codes, which is a
-- guard firing on correct code, and a guard that does that stops being read.
local CAPABILITY_REASON_FNS = {
  available = true, degraded = true, denied = true, error = true, unavailable = true,
}
local function capability_constructor(text)
  local name = text:match("Capability%.([%a]+)%s*%(")
  if name == nil or name == "new" then return nil end
  if not CAPABILITY_REASON_FNS[name] then return nil end
  return name
end
local function capability_literal(line)
  local code = line:gsub("%-%-.*$", "")
  if not capability_constructor(code) then return nil end
  -- The parenthesised match returns the *second* capture, which is the code.
  return (code:match("Capability%.%a+%s*%(%s*\"([%w_]+)\""))
end
local capability_sites, capability_unreadable, capability_read = {}, {}, 0
-- A long-bracket string, not a quoted one: `\.` is not a legal escape in a Lua
-- double-quoted string, and the alternative -- doubling every backslash -- is
-- how a scan pattern ends up quietly wrong.
local capability_pipe = assert(io.popen([[grep -rn 'Capability\.[a-z]*(' src/wtop]]))
for row in capability_pipe:lines() do
  capability_read = capability_read + 1
  local path, number, text = row:match("^([^:]+):(%d+):(.*)$")
  if capability_constructor(text) then
    local code = capability_literal(text)
    if code then
      capability_sites[#capability_sites + 1] =
        { code = code, site = path .. ":" .. number }
    elseif text:match("Capability%.%a+%s*%(%s*$")
        or not text:match('Capability%.%a+%s*%(%s*[^%s]') then
      capability_unreadable[#capability_unreadable + 1] = path .. ":" .. number
    end
  end
end
capability_pipe:close()
assert(capability_read > 0,
  "the Capability scan read no line at all, so it is not running")
-- Counting the *lines read* was not enough, and M214 is the proof: the grep
-- still returns every call site when the loop body that collects them is
-- disabled, so `capability_read` stayed positive, `capability_sites` went
-- empty, and the clause below was satisfied while watching nothing.  The
-- figure that matters is how many sites carry a code-shaped literal --
-- measured at eleven -- and it is the one asserted.
assert(#capability_sites >= 11,
  "the Capability scan collected " .. #capability_sites
    .. " site(s) whose first argument is a code-shaped literal, so it is "
    .. "reading less than it did: eleven are spelled in the product today, and "
    .. "a lower number means a constructor name stopped matching rather than "
    .. "that the tree got smaller")
local unlisted_capability = {}
for _, site in ipairs(capability_sites) do
  if classify(site.code) == "unlisted" then
    unlisted_capability[#unlisted_capability + 1] =
      site.code .. " at " .. site.site
  end
end
table.sort(unlisted_capability)
assert(#unlisted_capability == 0,
  "these codes are passed as the first argument of a Capability constructor, "
    .. "which becomes `capability.reason` and is rendered through "
    .. "`Technical.reason` in the Collectors and Inspectors tables, and they "
    .. "are in neither list: " .. table.concat(unlisted_capability, "; ")
    .. ".  A user who hits one is shown the raw code in every language, because "
    .. "`Technical.reason` falls back to its argument for a key no catalogue "
    .. "holds.  Add it to `interface_reasons` with ten translations, or to "
    .. "`machine_only` with the measurement that nothing renders it.")

-- Probes, for the same reason the clauses above carry them: a family that
-- matches nothing is satisfiable by an empty tree.
assert(capability_literal('  return Capability.unavailable("device_inventory_unavailable",')
  == "device_inventory_unavailable", "the family must read a positional literal")
assert(capability_literal('  return Capability.denied(last_error.message, { source = self.executable })')
  == nil, "a system's own string is not a code, and this line is in the product")
assert(capability_literal('  -- return Capability.unavailable("probe_commented",')
  == nil, "a commented-out call is not a call site")
assert(capability_literal('  local reason = "probe_not_a_capability"') == nil,
  "an ordinary string is not a Capability call site")

print("ok: reason localization (" .. #interface_reasons .. " interface codes, "
  .. #locales .. " catalogs)")
