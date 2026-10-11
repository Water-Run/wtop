package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local FD = require("wtop.linux.process_fds")
local Fixture = require("support.fixture_fs")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")

local stat = "42 (worker name) S 1 1 1 0 -1 0 1 2 3 4 5 6 7 8 9 10 11 1234 4096 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
local base = "/proc/42/fd"
local process = { pid = 42, starttime_ticks = 4096 }
local files = { ["/proc/42/stat"] = stat,
  ["/proc/42/fdinfo/0"] = "pos:\t1000\nflags:\t01002002\nmnt_id:\t21\nino:\t63107\n",
}
local links = {
  [base .. "/0"] = "/dev/null",
  [base .. "/2"] = "socket:[1234]",
  [base .. "/3"] = string.rep("x", 600),
  [base .. "/10"] = "/tmp/a\nname",
}
local fs = Fixture.new({ files = files, links = links })
local original_read = fs.read
function fs:read(path, limit)
  assert(path == "/proc/42/stat", "only process identity may be opened")
  return original_read(self, path, limit)
end
local result = FD.list(fs, process)
assert(result.status == "ok" and result.quality == "partial"
  and #result.entries == 4 and not result.truncated)
assert(result.entries[1].fd == 0 and result.entries[1].target == "/dev/null")
assert(result.entries[2].fd == 2 and result.entries[2].target == "socket:[1234]")
assert(result.entries[3].fd == 3 and result.entries[3].target_truncated
  and #result.entries[3].target <= 512)
assert(result.entries[4].fd == 10
  and not result.entries[4].target:find("\n", 1, true),
  "untrusted filename control characters cannot reach the terminal")
local en = assert(I18n.new({ locale = "en-US" }))
local lines = table.concat(TUI.process_fd_lines(result, en), "\n")
assert(lines:find("Open file descriptors · PID 42", 1, true)
  and lines:find("FD 0", 1, true)
  and lines:find("socket:[1234]", 1, true)
  and lines:find("file contents were not opened", 1, true))
local info = FD.inspect(fs, process, 0)
assert(info.status == "ok" and info.quality == "fresh"
  and info.target == "/dev/null" and info.position == "1000"
  and info.flags == "01002002" and info.mount_id == "21" and info.inode == "63107",
  "fdinfo values keep decimal and octal spellings without precision loss")
local detail_lines = table.concat(TUI.process_fd_detail_lines(info, en), "\n")
assert(detail_lines:find("FD 0 · PID 42", 1, true)
  and detail_lines:find("File offset: 1000", 1, true)
  and detail_lines:find("Flags (octal): 01002002", 1, true)
  and detail_lines:find("target file was not opened", 1, true))
local invalid_info = FD.inspect(Fixture.new({ files = {
  ["/proc/42/stat"] = stat,
  ["/proc/42/fdinfo/0"] = "pos: bad\nflags: 09\nmnt_id: 21\n",
}, links = { [base .. "/0"] = "/dev/null" } }), process, 0)
assert(invalid_info.status == "ok" and invalid_info.quality == "partial"
  and invalid_info.position == nil and invalid_info.flags == nil
  and invalid_info.mount_id == "21")
local info_denied = FD.inspect(Fixture.new({ files = {
  ["/proc/42/stat"] = stat }, links = { [base .. "/0"] = "/dev/null" },
  denied = { ["/proc/42/fdinfo/0"] = true } }), process, 0)
assert(info_denied.status == "denied" and info_denied.target == "/dev/null")
local changing_link = Fixture.new({ files = files, links = links })
local readlink = changing_link.readlink
local link_reads = 0
function changing_link:readlink(path)
  if path == base .. "/0" then
    link_reads = link_reads + 1
    if link_reads == 2 then return "/tmp/reused" end
  end
  return readlink(self, path)
end
local changed_info = FD.inspect(changing_link, process, 0)
assert(link_reads == 2 and changed_info.status == "unavailable"
  and changed_info.reason == "process_fd_changed" and changed_info.target == nil,
  "reused FD numbers must not retain a prior target's metadata")
local changed_detail = table.concat(TUI.process_fd_detail_lines(changed_info, en), "\n")
assert(changed_detail:find("metadata was discarded", 1, true)
  and not changed_detail:find("File offset", 1, true))
assert(FD.inspect(fs, process, 0.5).status == "unavailable")

local capped = FD.list(fs, process, 2)
assert(capped.status == "ok" and capped.truncated
  and #capped.entries == 2 and capped.entries[2].fd == 2)
local numeric = FD.list(Fixture.new({ files = { ["/proc/42/stat"] = stat },
  dirs = { [base] = { "0", "1", "10", "100", "2" } },
  links = { [base .. "/0"] = "zero", [base .. "/1"] = "one",
    [base .. "/2"] = "two", [base .. "/10"] = "ten",
    [base .. "/100"] = "hundred" } }), process, 3)
assert(numeric.truncated and numeric.entries[3].fd == 2,
  "directory truncation before numeric ordering must not hide a low FD")
local missing_link = FD.list(Fixture.new({ files = {
  ["/proc/42/stat"] = stat,
  [base .. "/1"] = "not a link",
} }), process)
assert(missing_link.status == "ok" and missing_link.quality == "partial"
  and missing_link.entries[1].status == "unavailable"
  and missing_link.entries[1].target == nil)
local denied = FD.list(Fixture.new({ files = { ["/proc/42/stat"] = stat },
  denied = { [base] = true } }), process)
assert(denied.status == "denied" and #denied.entries == 0)
local stat_denied = FD.list(Fixture.new({ denied = {
  ["/proc/42/stat"] = true } }), process)
assert(stat_denied.status == "denied"
  and stat_denied.reason == "process_fd_unavailable",
  "permission refusal is not evidence of PID reuse")
local denied_lines = table.concat(TUI.process_fd_lines(stat_denied, en), "\n")
assert(denied_lines:find("File descriptor list is unavailable", 1, true)
  and denied_lines:find("Denied", 1, true)
  and not denied_lines:find("identity changed", 1, true))
assert(FD.list(fs, { pid = 42, starttime_ticks = 999 }).status == "unavailable")

local changing = Fixture.new({ files = files, links = links })
local read = changing.read
local stat_reads = 0
function changing:read(path, limit)
  if path == "/proc/42/stat" then
    stat_reads = stat_reads + 1
    if stat_reads == 2 then
      return (stat:gsub(" 4096 ", " 4097 ", 1))
    end
  end
  return read(self, path, limit)
end
local changed = FD.list(changing, process)
assert(stat_reads == 2 and changed.status == "unavailable"
  and changed.reason == "process_identity_changed" and #changed.entries == 0,
  "a reused PID must not expose the old scan's path targets")
local changed_lines = table.concat(TUI.process_fd_lines(changed, en), "\n")
assert(changed_lines:find("targets were discarded", 1, true)
  and not changed_lines:find("/dev/null", 1, true))
assert(not pcall(FD.list, fs, process, 257))

return true
