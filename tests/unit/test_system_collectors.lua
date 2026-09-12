package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local FS = require("wtop.linux.fs")
local PowerSupply = require("wtop.collectors.power_supply")
local SystemInfo = require("wtop.collectors.system_info")
local Users = require("wtop.linux.users")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "values differ",
      tostring(expected), tostring(actual)), 2)
  end
end

--- A filesystem backed by a plain path->content table.
local function fake_fs(files, directories, denied)
  return FS.new({
    root = "/",
    read_file = function(path)
      if denied and denied[path] then
        return nil, { kind = "denied", message = "permission denied" }
      end
      local content = files[path]
      if content == nil then
        return nil, { kind = "missing", message = "no such file" }
      end
      return content
    end,
    list_dir = function(path)
      local entries = directories and directories[path]
      if not entries then
        return nil, { kind = "missing", message = "no such directory" }
      end
      return entries, nil, false
    end,
    readlink = function() return nil, { kind = "missing" } end,
    path_type = function() return "file" end,
  })
end

-- ---------------------------------------------------------------------------
-- Parsers
-- ---------------------------------------------------------------------------

local os_release = SystemInfo.parse_os_release([[
NAME="Ubuntu"
VERSION="24.04.4 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.4 LTS"
VERSION_ID="24.04"
# a comment and a blank line follow

HOME_URL="https://www.ubuntu.com/"
]])
equal(os_release.NAME, "Ubuntu", "unquoted-through-quotes value")
equal(os_release.PRETTY_NAME, "Ubuntu 24.04.4 LTS", "quoted value")
equal(os_release.ID, "ubuntu", "bare value")
equal(SystemInfo.parse_os_release("no keys here"), nil, "a file with no keys yields nothing")
equal(SystemInfo.parse_os_release(nil), nil, "non-string input is rejected")

local uptime = SystemInfo.parse_uptime("144348.75 285123.09\n")
equal(uptime.uptime_seconds, 144348.75, "uptime seconds")
equal(uptime.idle_seconds, 285123.09, "idle seconds")
equal(SystemInfo.parse_uptime("garbage"), nil, "malformed uptime is rejected")

local swaps = SystemInfo.parse_swaps(
  "Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n" ..
  "/dev/sdc                                partition\t2097152\t\t1024\t\t-2\n")
equal(#swaps.devices, 1, "one swap device")
equal(swaps.devices[1].name, "/dev/sdc", "device name")
equal(swaps.total_bytes, 2097152 * 1024, "total is scaled from KiB")
equal(swaps.used_bytes, 1024 * 1024, "used is scaled from KiB")
equal(swaps.devices[1].priority, -2, "negative priority parses")

-- The middle column of file-nr counts *free allocated* descriptors, so the
-- number actually in use is allocated minus free.  Reading it as "in use"
-- overstates the figure on every host.
local descriptors = SystemInfo.parse_file_nr("2336\t0\t9223372036854775807\n")
equal(descriptors.open, 2336, "open descriptors")
equal(descriptors.allocated, 2336, "allocated descriptors")
local with_free = SystemInfo.parse_file_nr("1000 250 4096")
equal(with_free.open, 750, "free allocated descriptors are not counted as in use")

-- ---------------------------------------------------------------------------
-- SystemInfo sampling
-- ---------------------------------------------------------------------------

local files = {
  ["/proc/uptime"] = "1000.5 500.25\n",
  ["/proc/sys/kernel/hostname"] = "testhost\n",
  ["/proc/sys/kernel/ostype"] = "Linux\n",
  ["/proc/sys/kernel/osrelease"] = "6.8.0-test\n",
  ["/proc/sys/kernel/version"] = "#1 SMP Test\n",
  ["/proc/sys/kernel/domainname"] = "(none)\n",
  ["/proc/cmdline"] = "BOOT_IMAGE=/vmlinuz ro quiet\n",
  ["/proc/sys/fs/file-nr"] = "1024 0 65536\n",
  ["/proc/sys/kernel/pid_max"] = "4194304\n",
  ["/proc/sys/kernel/threads-max"] = "31262\n",
  ["/proc/sys/vm/max_map_count"] = "65530\n",
  ["/proc/sys/kernel/random/entropy_avail"] = "256\n",
  ["/proc/loadavg"] = "0.50 0.25 0.10 2/300 12345\n",
  ["/proc/stat"] = "cpu  1 2 3 4\nbtime 1700000000\nctxt 999\nprocesses 42\n"
    .. "procs_running 2\nprocs_blocked 1\nintr 777\n",
  ["/proc/vmstat"] = "pgfault 100\npgmajfault 7\noom_kill 0\n",
  ["/proc/swaps"] = "Filename Type Size Used Priority\n/swap file 1024 512 -2\n",
  ["/usr/lib/os-release"] = 'PRETTY_NAME="Test Linux 1.0"\nID=testlinux\n',
  ["/sys/class/dmi/id/sys_vendor"] = "Test Systems\n",
  ["/sys/class/dmi/id/product_name"] = "To Be Filled By O.E.M.\n",
  ["/sys/class/dmi/id/board_name"] = "Mainboard X\n",
  ["/sys/class/dmi/id/chassis_type"] = "9\n",
  ["/sys/class/dmi/id/bios_version"] = "1.2.3\n",
}
local collector = SystemInfo.new({ fs = fake_fs(files) })
local sample = collector:sample({})
equal(sample.status, "ok", "sample succeeds")
local data = sample.data
equal(data.host.hostname, "testhost", "hostname")
equal(data.host.domain, nil, "the literal (none) domain is not a domain")
equal(data.kernel.release, "6.8.0-test", "kernel release")
equal(data.distribution.pretty_name, "Test Linux 1.0",
  "os-release is read from /usr/lib when /etc is a symlink")
equal(data.uptime_seconds, 1000.5, "uptime")
equal(data.boot_time_unix, 1700000000, "boot time comes from /proc/stat btime")
equal(data.counters.ctxt, 999, "context switches")
equal(data.counters.forks, 42, "the processes counter is a fork count")
equal(data.counters.intr, 777, "interrupts")
equal(data.limits.file_descriptors.open, 1024, "descriptor count")
equal(data.limits.entropy_available, 256, "entropy")
equal(data.swap.total_bytes, 1024 * 1024, "swap total")
equal(data.vmstat.pgmajfault, 7, "vmstat field")
equal(data.load.one, 0.50, "load average")

-- Firmware placeholders are worse than nothing: they read like real hardware.
equal(data.firmware.product_name, nil, "an O.E.M. placeholder is discarded")
equal(data.firmware.system_vendor, "Test Systems", "a real vendor survives")
equal(data.firmware.board_name, "Mainboard X", "board name")
equal(data.firmware.chassis_type, "laptop", "chassis code 9 is a laptop")
equal(data.firmware.chassis_type_code, 9, "the raw chassis code is kept")

-- Denied DMI must be reported as denied, not silently as absent.
local denied_collector = SystemInfo.new({
  fs = fake_fs(files, nil, {
    ["/sys/class/dmi/id/sys_vendor"] = true,
    ["/sys/class/dmi/id/product_name"] = true,
    ["/sys/class/dmi/id/board_name"] = true,
    ["/sys/class/dmi/id/chassis_type"] = true,
    ["/sys/class/dmi/id/bios_version"] = true,
  }),
})
local denied_data = denied_collector:sample({}).data
equal(denied_data.firmware, nil, "no readable DMI fields")
local notes = table.concat(denied_data.quality_notes or {}, ",")
assert(notes:find("dmi_denied", 1, true), "denial is distinguished from absence")

-- Without /proc/uptime there is nothing to report at all.
local empty = SystemInfo.new({ fs = fake_fs({}) }):sample({})
equal(empty.status, "unavailable", "a missing /proc/uptime makes the sample unavailable")

-- ---------------------------------------------------------------------------
-- Power supplies
-- ---------------------------------------------------------------------------

local battery_files = {
  ["/sys/class/power_supply/BAT0/type"] = "Battery\n",
  ["/sys/class/power_supply/BAT0/present"] = "1\n",
  ["/sys/class/power_supply/BAT0/status"] = "Discharging\n",
  ["/sys/class/power_supply/BAT0/capacity"] = "62\n",
  ["/sys/class/power_supply/BAT0/energy_now"] = "31000000\n",
  ["/sys/class/power_supply/BAT0/energy_full"] = "50000000\n",
  ["/sys/class/power_supply/BAT0/energy_full_design"] = "60000000\n",
  ["/sys/class/power_supply/BAT0/power_now"] = "10000000\n",
  ["/sys/class/power_supply/BAT0/cycle_count"] = "144\n",
  ["/sys/class/power_supply/AC/type"] = "Mains\n",
  ["/sys/class/power_supply/AC/online"] = "0\n",
}
local supplies = PowerSupply.new({
  fs = fake_fs(battery_files, { ["/sys/class/power_supply"] = { "BAT0", "AC" } }),
}):sample({})
equal(supplies.status, "ok", "power supply sample succeeds")
equal(#supplies.data.batteries, 1, "one battery")
equal(#supplies.data.supplies, 1, "one mains adapter")
local battery = supplies.data.batteries[1]
equal(battery.capacity_percent, 62, "the driver's own capacity wins")
equal(battery.energy_watt_hours, 31.0, "energy is scaled out of micro-units")
-- Health is full-charge against design capacity, which is what tells a user
-- their battery has aged.
assert(math.abs(battery.health_percent - (50 / 60 * 100)) < 0.001, "battery health")
assert(math.abs(battery.time_remaining_seconds - (31 / 10 * 3600)) < 0.001,
  "runtime is only computed while discharging")
equal(supplies.data.summary.state, "discharging", "summary state")
equal(supplies.data.on_ac_power, false, "offline mains means no AC power")

-- Absence must be reported the same way every other collector reports it, so
-- the UI can distinguish "nothing to read" from "read successfully, empty".
local none = PowerSupply.new({
  fs = fake_fs({}, { ["/sys/class/power_supply"] = {} }),
}):sample({})
equal(none.status, "unavailable", "a host with no power supplies reports unavailable")
equal(none.quality, "unavailable", "and its quality matches")
equal(none.reason, "no_power_supplies", "with a reason the Insights page can show")
equal(none.data, nil, "an unavailable sample carries no payload")

-- ---------------------------------------------------------------------------
-- User name resolution
-- ---------------------------------------------------------------------------

local passwd = "root:x:0:0:root:/root:/bin/bash\n"
  .. "daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n"
  .. "# comment line\n"
  .. "waterrun:x:1000:1000:,,,:/home/waterrun:/bin/bash\n"
local group = "root:x:0:\nsudo:x:27:waterrun\n"
local resolver = Users.new({
  fs = fake_fs({ ["/etc/passwd"] = passwd, ["/etc/group"] = group }),
})
equal(resolver:user(0, 0), "root", "root resolves")
equal(resolver:user(1000, 0), "waterrun", "a regular user resolves")
equal(resolver:user(4242, 0), nil, "an unknown uid resolves to nothing")
equal(resolver:user_label(4242, 0), "4242", "an unknown uid keeps its number")
equal(resolver:group(27, 0), "sudo", "group resolution")
equal(resolver:user("nope", 0), nil, "a non-numeric uid is rejected")
local users_count, groups_count = resolver:count(0)
equal(users_count, 3, "comment lines are not users")
equal(groups_count, 2, "group count")

return true
