package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Mounts = require("wtop.collectors.mounts")
local MountInfo = require("wtop.linux.mountinfo")

local function fixture(name)
  local file = assert(io.open("tests/fixtures/mounts/" .. name, "rb"))
  local content = assert(file:read("*a"))
  file:close()
  return content
end

local function fake_fs(content, failure)
  return {
    read = function(_, path, limit)
      assert(path == "/proc/self/mountinfo")
      assert(type(limit) == "number" and limit > 0)
      if failure then return nil, failure end
      return content
    end,
  }
end

local main = fixture("main.mountinfo")
local parsed = assert(MountInfo.parse(main))
assert(MountInfo.parse(main, "invalid") == nil)
assert(MountInfo.parse(main, { max_bytes = MountInfo.HARD_MAX_BYTES + 1 }) == nil)
assert(#parsed == 7)
assert(parsed[1].mount_id == 101 and parsed[1].parent_id == 1)
assert(parsed[1].major == 8 and parsed[1].minor == 1 and parsed[1].device_id == "8:1")
assert(parsed[1].root == "/" and parsed[1].mount_point == "/")
assert(parsed[1].mount_options[1] == "rw" and parsed[1].mount_option_set.relatime)
assert(parsed[1].optional_fields[1] == "shared:7")
assert(parsed[1].optional[1].tag == "shared" and parsed[1].optional[1].value == "7")
assert(parsed[1].optional_by_tag.shared[1] == "7")
assert(parsed[1].fs_type == "ext4" and parsed[1].source == "/dev/vda1")
assert(parsed[1].super_option_set["errors=remount-ro"])
assert(not parsed[1].readonly and not parsed[1].pseudo and not parsed[1].network)

local escaped = parsed[2]
assert(escaped.mount_point == "/mnt/escaped space\ttab\nline\\slash")
assert(escaped.source == "/dev/disk/by-label/data disk")
assert(assert(MountInfo.decode([[a\040b\011c\012d\134e]])) == "a b\tc\nd\\e")
local unsupported_escape, unsupported_error = MountInfo.decode([[bad\057escape]])
assert(unsupported_escape == nil and unsupported_error == "invalid_escape")

local tmpfs = parsed[3]
assert(tmpfs.pseudo and not tmpfs.network and tmpfs.kind == "pseudo")
local readonly = parsed[4]
assert(readonly.readonly and readonly.kind == "local")
local bind = parsed[5]
assert(bind.root == "/srv/project" and bind.mount_point == "/mnt/project copy")
assert(bind.source == parsed[1].source and bind.id ~= parsed[1].id)
assert(bind.optional_by_tag.master[1] == "7")
assert(bind.optional_by_tag.propagate_from[1] == "9")
local network = parsed[6]
assert(network.network and not network.pseudo and network.kind == "network")
assert(Mounts.potentially_blocking_filesystem(network))
assert(not Mounts.potentially_blocking_filesystem(parsed[1]))
assert(Mounts.potentially_blocking_filesystem({ fs_type = "fuse.example" }))
assert(Mounts.potentially_blocking_filesystem({ fs_type = "fuseblk" }))
assert(Mounts.potentially_blocking_filesystem({ fs_type = "virtiofs" }))
assert(not Mounts.potentially_blocking_filesystem({ fs_type = "fusectl" }))
local overlay = parsed[7]
assert(overlay.pseudo and overlay.kind == "pseudo")

local special_root = assert(MountInfo.parse(fixture("special-root.mountinfo")))[1]
assert(special_root.root == "net:[4026533566]")
assert(special_root.mount_point == "/run/docker/netns/example" and special_root.pseudo)

local invalid, invalid_error = MountInfo.parse(fixture("invalid.mountinfo"))
assert(invalid == nil and invalid_error:find("mountinfo_line_2:", 1, true))
local limited, limit_error = MountInfo.parse(fixture("limit.mountinfo"), { max_entries = 2 })
assert(limited == nil and limit_error == "mountinfo_entry_limit_exceeded")
local path_limited, path_limit_error = MountInfo.parse(main, { max_path_bytes = 8 })
assert(path_limited == nil and path_limit_error:find("path_too_long", 1, true))
local byte_limited, byte_limit_error = MountInfo.parse(main, { max_bytes = #main - 1 })
assert(byte_limited == nil and byte_limit_error == "mountinfo_content_limit_exceeded")
local line_limited, line_limit_error = MountInfo.parse(main, { max_line_bytes = 20 })
assert(line_limited == nil and line_limit_error:find("line_too_long", 1, true))

local normal_stat = {
  block_size = 4096,
  blocks = 1000,
  blocks_free = 400,
  blocks_available = 250,
  files = 100,
  files_free = 40,
}
local escaped_path = escaped.mount_point
local calls = {}
local function statvfs(path)
  calls[path] = (calls[path] or 0) + 1
  if path == "/mnt/readonly" then
    return nil, { kind = "denied", message = "fixture_permission_denied" }
  elseif path == "/mnt/ssh" then
    return nil, "statvfs: Stale file handle", 116
  elseif path == escaped_path then
    return nil, "statvfs: No such file or directory", 2
  elseif path == "/" then
    local root_stat = {}
    for key, value in pairs(normal_stat) do root_stat[key] = value end
    root_stat.files_available = 35
    return root_stat
  end
  return normal_stat
end

local now = 1000000000
local collector = Mounts.new({ fs = fake_fs(main), statvfs = statvfs })
assert(not pcall(Mounts.new, "invalid"))
assert(not pcall(Mounts.new, { statvfs_budget_ms = math.huge }))
assert(not pcall(Mounts.new, { max_statvfs_calls = 65537 }))
local capability = collector:probe({ now_ns = function() return now end })
assert(capability.available and capability.details.mounts == 7)
local result = collector:sample({ now_ns = function() now = now + 10; return now end })
assert(result.status == "ok" and result.quality == "partial")
assert(result.reason == "statvfs_partial" and result.data.partial)
assert(result.data.count == 7 and result.data.complete == 4 and result.data.failed == 3)
assert(#result.data.mounts == 7 and #result.data.errors == 3)
assert(result.data.mounts[1].mount_point == "/")
for index = 2, #result.data.mounts do
  local before = result.data.mounts[index - 1]
  local current = result.data.mounts[index]
  assert(before.mount_point < current.mount_point
    or (before.mount_point == current.mount_point and before.mount_id < current.mount_id))
end

local root = assert(result.data.by_id["101"])
assert(root.quality == "fresh" and not root.partial)
assert(root.capacity.block_size_bytes == 4096)
assert(root.capacity.total_bytes == 4096000)
assert(root.capacity.free_bytes == 1638400)
assert(root.capacity.available_bytes == 1024000) -- f_bavail, not f_bfree
assert(root.capacity.used_bytes == 2457600)
assert(root.capacity.reserved_bytes == 614400)
assert(root.inodes.total == 100 and root.inodes.free == 40)
assert(root.inodes.available == 35 and root.inodes.used == 60 and root.inodes.reserved == 5)
assert(not root.inodes.available_estimated)

local bind_result = assert(result.data.by_id["102"])
assert(bind_result.source == root.source and bind_result.capacity.total_bytes == root.capacity.total_bytes)
assert(bind_result.inodes.available == 40 and bind_result.inodes.available_estimated)
local denied = assert(result.data.by_id["105"])
assert(denied.partial and denied.quality == "denied")
assert(denied.partial_reason == "statvfs_denied" and denied.capacity == nil)
local stale = assert(result.data.by_id["106"])
assert(stale.partial and stale.quality == "stale" and stale.statvfs_error.errno == 116)
local missing = assert(result.data.by_id["107"])
assert(missing.partial and missing.quality == "missing" and missing.statvfs_error.errno == 2)
assert(calls[escaped_path] == 1)

local complete_collector = Mounts.new({ fs = fake_fs(main), statvfs = function() return normal_stat end })
local complete = complete_collector:sample({ now_ns = function() return now end })
assert(complete.status == "ok" and complete.quality == "fresh")
assert(not complete.data.partial and complete.data.failed == 0 and complete.data.complete == 7)

-- An explicitly configured synchronous-work budget remains testable with an
-- injected provider. Calls already in progress cannot be interrupted, but no
-- further mount is entered after the budget is consumed.
local budget_now = 0
local budget_calls = 0
local budget_collector = Mounts.new({
  fs = fake_fs(main),
  statvfs_budget_ms = 10,
  statvfs = function()
    budget_calls = budget_calls + 1
    budget_now = budget_now + 6000000
    return normal_stat
  end,
})
local budgeted = budget_collector:sample({ now_ns = function() return budget_now end })
assert(budgeted.status == "ok" and budgeted.quality == "partial")
assert(budget_calls == 2 and budgeted.data.complete == 2)
assert(budgeted.data.skipped == 5 and budgeted.data.failed == 0 and budgeted.data.partial)
assert(budgeted.data.budget_exhausted and budgeted.data.statvfs_budget_ms == 10)
assert(budgeted.data.budget_reason == "time" and budgeted.data.statvfs_attempted == 2)
assert(budgeted.data.max_statvfs_calls == nil)
for _, mount in ipairs(budgeted.data.mounts) do
  if mount.partial then
    assert(mount.skipped and mount.partial_reason == "statvfs_skipped_budget_exhausted")
    assert(mount.statvfs_error.reason == "statvfs_skipped_budget_exhausted")
  end
end

-- Injected providers are unbudgeted by default, keeping deterministic fixture
-- providers authoritative even when their fake clock advances aggressively.
local injected_now = 0
local injected_calls = 0
local injected_default = Mounts.new({
  fs = fake_fs(main),
  statvfs = function()
    injected_calls = injected_calls + 1
    injected_now = injected_now + 1000000000
    return normal_stat
  end,
})
local injected_complete = injected_default:sample({ now_ns = function() return injected_now end })
assert(injected_calls == 7 and injected_complete.data.complete == 7)
assert(not injected_complete.data.partial)
assert(not injected_complete.data.budget_exhausted and injected_complete.data.statvfs_budget_ms == nil)
assert(injected_complete.data.max_statvfs_calls == nil)

-- A deterministic call budget also bounds very high-cardinality mount tables
-- when each individual statvfs is fast enough to stay inside the time budget.
local call_budget_calls = 0
local call_budget_collector = Mounts.new({
  fs = fake_fs(main),
  max_statvfs_calls = 3,
  statvfs = function()
    call_budget_calls = call_budget_calls + 1
    return normal_stat
  end,
})
local call_budgeted = call_budget_collector:sample({ now_ns = function() return now end })
assert(call_budget_calls == 3 and call_budgeted.data.statvfs_attempted == 3)
assert(call_budgeted.data.complete == 3 and call_budgeted.data.skipped == 4)
assert(call_budgeted.data.partial and call_budgeted.data.budget_exhausted)
assert(call_budgeted.data.budget_reason == "calls")
assert(call_budgeted.data.max_statvfs_calls == 3 and call_budgeted.data.statvfs_budget_ms == nil)

local thrown_collector = Mounts.new({
  fs = fake_fs(main),
  statvfs = function(path)
    if path == "/containers" then error("fixture provider crashed") end
    return normal_stat
  end,
})
local thrown = thrown_collector:sample({ now_ns = function() return now end })
assert(thrown.status == "ok" and thrown.quality == "partial")
assert(thrown.data.by_id["104"].quality == "error")

local denied_collector = Mounts.new({
  fs = fake_fs(nil, { kind = "denied", message = "fixture_denied" }),
  statvfs = statvfs,
})
assert(denied_collector:probe({}).state == "denied")
local denied_sample = denied_collector:sample({ now_ns = function() return now end })
assert(denied_sample.status == "denied" and denied_sample.data == nil)

local invalid_collector = Mounts.new({ fs = fake_fs(fixture("invalid.mountinfo")), statvfs = statvfs })
local invalid_sample = invalid_collector:sample({ now_ns = function() return now end })
assert(invalid_sample.status == "error" and invalid_sample.reason:find("mountinfo_line_2:", 1, true))

return true
