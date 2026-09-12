package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

-- Two paths that a development machine never reaches.
--
-- Scale: this project's own host runs about sixty processes, so the 8192-PID
-- collection cap, the 2048-row model cap and the truncation reporting between
-- them have never actually engaged.  A synthetic /proc exercises them.
--
-- Privilege: a sudo session must ignore file configuration, user locale
-- catalogs and the persisted layout, because those files belong to the
-- invoking user and are being read by a root process.  That policy is stated
-- in the README and enforced in three separate places, none of which runs
-- unless someone actually uses `--sudo`.

local Fixture = require("support.fixture_fs")
local Config = require("wtop.config")
local Privilege = require("wtop.privilege")
local Process = require("wtop.collectors.process")
local ProcessTable = require("wtop.model.process_table")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "values differ",
      tostring(expected), tostring(actual)), 2)
  end
end

-- ---------------------------------------------------------------------------
-- A synthetic /proc with far more processes than the collector will accept.
-- ---------------------------------------------------------------------------

local function synthetic_proc(count, proc_base)
  proc_base = proc_base or "/proc"
  local files, entries = {}, {}
  for index = 1, count do
    local pid = 1000 + index
    entries[#entries + 1] = tostring(pid)
    local name = "worker" .. index
    files[string.format("%s/%d/stat", proc_base, pid)] = string.format(
      "%d (%s) S 1 %d %d 0 -1 4194304 500 0 0 0 %d %d 0 0 20 0 1 0 %d "
        .. "10485760 512 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n",
      pid, name, pid, pid, index, index // 2, 900 + index)
    files[string.format("%s/%d/status", proc_base, pid)] = string.format(
      "Name:\t%s\nUid:\t1000\t1000\t1000\t1000\nGid:\t1000\t1000\t1000\t1000\n"
        .. "VmRSS:\t%d kB\nThreads:\t1\nvoluntary_ctxt_switches:\t10\n"
        .. "nonvoluntary_ctxt_switches:\t2\n",
      name, 2048 + index)
    files[string.format("%s/%d/cmdline", proc_base, pid)] =
      "/usr/bin/" .. name .. "\0--worker\0"
  end
  -- Non-PID entries the enumerator must skip without spending its budget.
  files[proc_base .. "/uptime"] = "1000.0 500.0\n"
  files[proc_base .. "/stat"] = "cpu 1 2 3 4\n"
  files[proc_base .. "/self/stat"] = "1 (self) S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 1 0 0\n"
  entries[#entries + 1] = "uptime"
  entries[#entries + 1] = "stat"
  entries[#entries + 1] = "self"
  return { files = files, dirs = { [proc_base] = entries } }
end

local LIMIT = 256
local POPULATION = 900

local crowded = Process.new({
  fs = Fixture.new(synthetic_proc(POPULATION)),
  max_processes = LIMIT,
  read_cmdline = true,
  read_status = true,
})
local sample = crowded:sample({})
equal(sample.status, "ok", "a crowded host still produces a sample")

-- The cap must bound the work, and the result must say so rather than letting
-- the caller believe the machine only has `LIMIT` processes.
assert(#sample.data.list <= LIMIT,
  string.format("collection must respect its limit: %d > %d", #sample.data.list, LIMIT))
equal(sample.data.truncated, true, "a capped scan must be reported as truncated")
equal(sample.data.process_limit, LIMIT, "the limit itself is reported")
assert((sample.data.process_candidates or 0) > #sample.data.list,
  "the candidate count must exceed what was kept, so the gap is visible")

-- Every surviving row must still be complete: truncation may drop rows, never
-- corrupt the ones it keeps.
for _, entry in ipairs(sample.data.list) do
  assert(type(entry.pid) == "number" and entry.pid > 0, "each row keeps its PID")
  assert(type(entry.starttime_ticks) == "number", "each row keeps its identity")
  assert(entry.name ~= nil and entry.name ~= "", "each row keeps a name")
end

-- The view model caps rows independently of the collector.  Its own limit must
-- not be mistaken for the collector's, and neither may fabricate quality.
local controller = ProcessTable.new({ max_rows = 64 })
controller:update(sample.data.list)
local status = controller:status()
assert(#controller:rows() <= 64, "the model applies its own row cap")
equal(status.truncated, true, "the model reports its own truncation")
assert(status.total >= #controller:rows(), "the total counts what the model received")

-- Sorting and searching must stay correct at the cap rather than silently
-- operating on the visible window only.
controller:set_sort("memory", true)
local rows = controller:rows()
for index = 2, #rows do
  local previous = rows[index - 1].resident_bytes or 0
  local current = rows[index].resident_bytes or 0
  assert(previous >= current, "a capped table must still be sorted across the whole set")
end
-- `worker5` sorts near the bottom by memory, so it lives outside the 64 rows
-- the model is showing.  Finding it proves the query runs over everything the
-- model holds rather than over the visible window.
controller:set_query("worker5")
local found = controller:rows()
assert(#found >= 1, "search must reach a process outside the first page of the cap")
for _, row in ipairs(found) do
  assert(tostring(row.name):find("worker5", 1, true),
    "every surviving row must actually match the query")
end

-- ---------------------------------------------------------------------------
-- A sudo session must not read the invoking user's files.
-- ---------------------------------------------------------------------------

local function identity(uid, environment)
  return Privilege.identity({
    native = { uid = function() return uid, uid end },
    getenv = function(name) return (environment or {})[name] end,
  })
end

local plain_root = identity(0, {})
equal(plain_root.root, true, "uid 0 is root")
equal(plain_root.via_sudo, false, "root without SUDO_UID did not arrive through sudo")

local sudo_session = identity(0, { SUDO_UID = "1000", SUDO_USER = "someone" })
equal(sudo_session.root, true, "a sudo session is root")
equal(sudo_session.via_sudo, true, "and it knows it came through sudo")
equal(sudo_session.original_uid, 1000, "the invoking user is recorded")

-- An unprivileged process must never believe an inherited SUDO_UID: anyone can
-- set that variable, and trusting it would let a normal user claim to be root.
local spoofed = identity(1000, { SUDO_UID = "0" })
equal(spoofed.root, false, "uid 1000 is not root whatever the environment says")
equal(spoofed.via_sudo, false, "and it did not arrive through sudo")
equal(spoofed.original_uid, nil, "a spoofed original uid is discarded")

-- The policy the README states, expressed once so the five sites that enforce
-- it (configuration, layout load, layout save, locale report, catalog reload)
-- cannot drift apart.
equal(Privilege.restricts_user_files(sudo_session), true,
  "a sudo session must not touch the invoking user's files")
equal(Privilege.restricts_user_files(plain_root), false,
  "a real root login owns its own files and may read them")
equal(Privilege.restricts_user_files(spoofed), false,
  "an ordinary user is not restricted by an environment variable")
equal(Privilege.restricts_user_files(nil), false,
  "an absent identity must not silently restrict a normal session")
equal(Privilege.restricts_user_files({ via_sudo = "yes" }), false,
  "only a real boolean counts, so a stray string cannot flip the policy")

-- Each enforcement site must actually call the predicate; a site that drifts
-- back to an inline `via_sudo` check is the exact regression this guards.
local sources = { "src/wtop/application.lua", "src/wtop/tui.lua" }
local enforcement_sites = 0
for _, path in ipairs(sources) do
  local handle = assert(io.open(path, "rb"), "cannot read " .. path)
  local text = handle:read("a")
  handle:close()
  for _ in text:gmatch("restricts_user_files") do
    enforcement_sites = enforcement_sites + 1
  end
  assert(not text:match("privilege%.via_sudo"),
    path .. " must consult Privilege.restricts_user_files, not via_sudo directly")
end
-- Five call sites plus the `local Privilege` import lines are not counted here;
-- the import does not contain the name.
equal(enforcement_sites, 5, "every documented enforcement site consults the predicate")

local Application = require("wtop.application")
assert(type(Application) == "table", "the application module loads")

local defaults = Config.defaults()
assert(type(defaults) == "table" and defaults.interval_ms ~= nil,
  "defaults must be self-contained, since a sudo session gets nothing else")

-- Config.resolve must not let a file override an explicit command-line choice,
-- which is what makes the sudo fallback safe to apply unconditionally.
local resolved = Config.resolve(
  { interval_ms = 300, explicit = { interval_ms = true } },
  { interval_ms = 5000, theme = "water-dark" })
equal(resolved.interval_ms, 300, "an explicit flag wins over file configuration")
equal(resolved.theme, "water-dark", "a value not given on the command line comes from the file")

return true
