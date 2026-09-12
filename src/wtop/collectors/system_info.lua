-- Host identity, kernel, firmware, boot, and kernel-wide counters.
--
-- Everything here is cheap and mostly static, so the collector runs on a slow
-- cadence.  The volatile members (uptime, context switches, forks, entropy,
-- open descriptors) are still refreshed every sample because they are the part
-- an operator watches.  Nothing in this file executes an external command.
local Capability = require("wtop.core.capability")
local FS = require("wtop.linux.fs")
local Common = require("wtop.collectors.common")

local SystemInfo = {}
SystemInfo.__index = SystemInfo

local MAX_TEXT = 256
local MAX_SMALL_FILE = 64 * 1024

-- Readable-by-everyone DMI members only.  Serial numbers, asset tags, and the
-- product UUID are deliberately excluded: they are host-identifying, usually
-- root-only, and would leak through --snapshot into logs and bug reports.
local DMI_FIELDS = {
  { key = "system_vendor", file = "sys_vendor" },
  { key = "product_name", file = "product_name" },
  { key = "product_version", file = "product_version" },
  { key = "product_family", file = "product_family" },
  { key = "board_vendor", file = "board_vendor" },
  { key = "board_name", file = "board_name" },
  { key = "board_version", file = "board_version" },
  { key = "bios_vendor", file = "bios_vendor" },
  { key = "bios_version", file = "bios_version" },
  { key = "bios_date", file = "bios_date" },
  { key = "bios_release", file = "bios_release" },
  { key = "chassis_vendor", file = "chassis_vendor" },
  { key = "chassis_type", file = "chassis_type" },
}

-- SMBIOS 3.x chassis types, trimmed to the ones a monitoring tool benefits
-- from naming.  Unknown codes fall back to the raw number.
local CHASSIS_TYPES = {
  [1] = "other", [2] = "unknown", [3] = "desktop", [4] = "low-profile-desktop",
  [5] = "pizza-box", [6] = "mini-tower", [7] = "tower", [8] = "portable",
  [9] = "laptop", [10] = "notebook", [11] = "handheld", [12] = "docking-station",
  [13] = "all-in-one", [14] = "sub-notebook", [15] = "space-saving",
  [16] = "lunch-box", [17] = "main-server-chassis", [18] = "expansion-chassis",
  [23] = "rack-mount-chassis", [24] = "sealed-case-pc", [28] = "blade",
  [29] = "blade-enclosure", [30] = "tablet", [31] = "convertible",
  [32] = "detachable", [33] = "iot-gateway", [34] = "embedded-pc",
  [35] = "mini-pc", [36] = "stick-pc",
}

local VMSTAT_FIELDS = {
  "pgfault", "pgmajfault", "pswpin", "pswpout", "pgscan_direct",
  "pgsteal_direct", "oom_kill", "nr_dirty", "nr_writeback",
}

local KERNEL_LIMITS = {
  { key = "pid_max", file = "/proc/sys/kernel/pid_max" },
  { key = "threads_max", file = "/proc/sys/kernel/threads-max" },
  { key = "max_map_count", file = "/proc/sys/vm/max_map_count" },
  { key = "entropy_available", file = "/proc/sys/kernel/random/entropy_avail" },
}

local function text(value)
  if type(value) ~= "string" then return nil end
  local trimmed = Common.trim(value)
  if trimmed == "" then return nil end
  return Common.safe_text(trimmed, MAX_TEXT)
end

local function number(value)
  local parsed = tonumber(value)
  if type(parsed) ~= "number" or parsed ~= parsed
      or parsed == math.huge or parsed == -math.huge then
    return nil
  end
  return parsed
end

local function read_text(fs, path)
  local content = fs:read(path, MAX_SMALL_FILE)
  return text(content)
end

local function read_number(fs, path)
  return number(read_text(fs, path))
end

-- os-release is a shell-fragment format.  Only simple `KEY=value` and
-- `KEY="value"` forms are honoured; command substitution or continuation lines
-- are ignored rather than interpreted.
local function parse_os_release(content)
  if type(content) ~= "string" then return nil end
  local result = {}
  local count = 0
  for line in content:gmatch("[^\n]+") do
    if count >= 64 then break end
    local key, value = line:match("^%s*([A-Z_][A-Z0-9_]*)%s*=%s*(.-)%s*$")
    if key then
      local unquoted = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
      unquoted = Common.safe_text(unquoted, MAX_TEXT)
      if unquoted and unquoted ~= "" then
        result[key] = unquoted
        count = count + 1
      end
    end
  end
  if count == 0 then return nil end
  return result
end

local function parse_uptime(content)
  if type(content) ~= "string" then return nil end
  local up, idle = content:match("^%s*([%d%.]+)%s+([%d%.]+)")
  up = number(up)
  if not up or up < 0 then return nil end
  return { uptime_seconds = up, idle_seconds = number(idle) }
end

local function parse_swaps(content)
  if type(content) ~= "string" then return nil end
  local devices = {}
  local total_kib, used_kib = 0, 0
  local first = true
  for line in content:gmatch("[^\n]+") do
    if first then
      first = false
    elseif #devices < 32 then
      local name, kind, size, used, priority = line:match(
        "^(%S+)%s+(%S+)%s+(%d+)%s+(%d+)%s+(-?%d+)")
      if name then
        size, used = number(size) or 0, number(used) or 0
        devices[#devices + 1] = {
          name = Common.safe_text(name, MAX_TEXT),
          type = Common.safe_text(kind, 32),
          size_bytes = size * 1024,
          used_bytes = used * 1024,
          priority = number(priority),
        }
        total_kib, used_kib = total_kib + size, used_kib + used
      end
    end
  end
  return {
    devices = devices,
    total_bytes = total_kib * 1024,
    used_bytes = used_kib * 1024,
  }
end

local function parse_vmstat(content)
  if type(content) ~= "string" then return nil end
  local wanted, result = {}, {}
  for _, key in ipairs(VMSTAT_FIELDS) do wanted[key] = true end
  local found = 0
  for line in content:gmatch("[^\n]+") do
    local key, value = line:match("^(%S+)%s+(%d+)$")
    if key and wanted[key] then
      result[key] = number(value)
      found = found + 1
    end
  end
  if found == 0 then return nil end
  return result
end

local function parse_file_nr(content)
  if type(content) ~= "string" then return nil end
  local allocated, free, maximum = content:match("^%s*(%d+)%s+(%d+)%s+(%d+)")
  allocated, free, maximum = number(allocated), number(free), number(maximum)
  if not allocated or not maximum then return nil end
  return {
    -- The middle column is "free allocated" descriptors, so the number of
    -- descriptors actually in use is allocated minus free.
    open = math.max(0, allocated - (free or 0)),
    allocated = allocated,
    maximum = maximum,
  }
end

local function read_dmi(fs, base)
  local dmi, count, denied = {}, 0, 0
  for _, field in ipairs(DMI_FIELDS) do
    local value, err = fs:read(base .. "/" .. field.file, MAX_SMALL_FILE)
    if value then
      local cleaned = text(value)
      -- Firmware routinely ships placeholder strings; showing them is worse
      -- than showing nothing because they read like real hardware names.
      if cleaned and not cleaned:match("^[Tt]o [Bb]e [Ff]illed")
          and not cleaned:match("^[Dd]efault string$")
          and cleaned ~= "None" and cleaned ~= "Not Specified"
          and cleaned ~= "Not Applicable" and cleaned ~= "System manufacturer"
          and cleaned ~= "System Product Name" then
        dmi[field.key] = cleaned
        count = count + 1
      end
    elseif FS.error_status(err) == "denied" then
      denied = denied + 1
    end
  end
  if dmi.chassis_type then
    local code = number(dmi.chassis_type)
    dmi.chassis_type_code = code
    dmi.chassis_type = code and (CHASSIS_TYPES[code] or ("type-" .. tostring(code)))
      or dmi.chassis_type
  end
  if count == 0 then return nil, denied end
  return dmi, denied
end

-- Best-effort virtualization and container detection from files only.  This is
-- deliberately weaker than systemd-detect-virt: it never runs a helper and
-- never reports a guess as certain.
local function detect_virtualization(fs, dmi)
  local result = { virtual = false, container = false }

  local hypervisor = read_text(fs, "/sys/hypervisor/type")
  if hypervisor then
    result.virtual, result.technology = true, hypervisor
  end

  local product = dmi and (dmi.product_name or dmi.system_vendor)
  if product then
    local signatures = {
      ["VMware"] = "vmware", ["VirtualBox"] = "oracle-virtualbox",
      ["KVM"] = "kvm", ["QEMU"] = "qemu", ["Bochs"] = "bochs",
      ["Xen"] = "xen", ["Hyper%-V"] = "microsoft-hyper-v",
      ["Virtual Machine"] = "microsoft-hyper-v", ["Parallels"] = "parallels",
      ["Google"] = "google-compute-engine", ["Amazon EC2"] = "amazon-ec2",
      ["OpenStack"] = "openstack", ["Apple Virtualization"] = "apple-virtualization",
    }
    for pattern, name in pairs(signatures) do
      if product:match(pattern) then
        result.virtual, result.technology = true, result.technology or name
        break
      end
    end
  end

  local osrelease = read_text(fs, "/proc/sys/kernel/osrelease")
  if osrelease and (osrelease:match("[Mm]icrosoft") or osrelease:match("WSL")) then
    result.virtual = true
    result.technology = result.technology or "wsl"
  end

  if fs:exists("/.dockerenv") then
    result.container, result.container_technology = true, "docker"
  elseif fs:exists("/run/.containerenv") then
    result.container, result.container_technology = true, "podman"
  else
    local container_env = read_text(fs, "/run/systemd/container")
    -- systemd classifies WSL as a container.  Reporting it in both fields
    -- reads as two separate findings, so the more specific one wins.
    if container_env and container_env ~= result.technology then
      result.container, result.container_technology = true, container_env
    end
  end

  return result
end

local function read_security(fs)
  local security = {}
  local selinux = read_text(fs, "/sys/fs/selinux/enforce")
  if selinux then
    security.selinux = selinux == "1" and "enforcing" or "permissive"
  end
  local apparmor = read_text(fs, "/sys/module/apparmor/parameters/enabled")
  if apparmor then
    security.apparmor = (apparmor == "Y" or apparmor == "1") and "enabled" or "disabled"
  end
  local lockdown = read_text(fs, "/sys/kernel/security/lockdown")
  if lockdown then
    security.lockdown = lockdown:match("%[(%w+)%]") or lockdown
  end
  return next(security) and security or nil
end

local function read_timezone(fs)
  local zone = read_text(fs, "/etc/timezone")
  if zone then return zone end
  local link = fs:readlink("/etc/localtime")
  if type(link) == "string" then
    return link:match("zoneinfo/(.+)$")
  end
  return nil
end

function SystemInfo.new(options)
  options = options or {}
  if type(options) ~= "table" then error("SystemInfo options must be a table", 2) end
  return setmetatable({
    id = "system_info",
    default_interval_ms = Common.positive_integer("interval_ms", options.interval_ms, 5000),
    fs = options.fs or FS.default,
    proc_path = Common.absolute_path("proc_path", options.proc_path, "/proc"),
    dmi_path = Common.absolute_path("dmi_path", options.dmi_path, "/sys/class/dmi/id"),
    os_release_path = Common.absolute_path("os_release_path", options.os_release_path,
      "/etc/os-release"),
    fallback_os_release_path = Common.absolute_path("fallback_os_release_path",
      options.fallback_os_release_path, "/usr/lib/os-release"),
    native = options.native,
    _method_style = true,
  }, SystemInfo)
end

function SystemInfo:probe(context)
  local fs = Common.fs(context, self.fs)
  local content, err = fs:read(self.proc_path .. "/uptime", MAX_SMALL_FILE)
  if content then
    return Capability.available({ source = self.proc_path })
  end
  local status = FS.error_status(err)
  if status == "denied" then
    return Capability.denied(err.message, { source = self.proc_path })
  end
  return Capability.unavailable(err and err.message or "proc_uptime_unavailable",
    { source = self.proc_path })
end

function SystemInfo:sample(context)
  local started = Common.now_ns(context)
  local fs = Common.fs(context, self.fs)
  local native = self.native or (context and context.native)
  local data = { quality_notes = {} }

  local uptime = parse_uptime(fs:read(self.proc_path .. "/uptime", MAX_SMALL_FILE))
  if not uptime then
    local finished = Common.now_ns(context)
    return Common.result("unavailable", finished, nil, {
      quality = "unavailable",
      reason = "proc_uptime_unreadable",
      duration_ns = Common.elapsed_ns(finished, started) or 0,
      source = self.proc_path,
    })
  end
  data.uptime_seconds = uptime.uptime_seconds
  data.idle_seconds = uptime.idle_seconds

  local uname = type(native) == "table" and type(native.uname) == "function"
    and select(1, pcall(native.uname)) and native.uname() or nil
  data.host = {
    hostname = read_text(fs, self.proc_path .. "/sys/kernel/hostname")
      or (uname and text(uname.nodename)),
    architecture = uname and text(uname.machine),
    domain = read_text(fs, self.proc_path .. "/sys/kernel/domainname"),
  }
  if data.host.domain == "(none)" then data.host.domain = nil end

  data.kernel = {
    type = read_text(fs, self.proc_path .. "/sys/kernel/ostype")
      or (uname and text(uname.sysname)),
    release = read_text(fs, self.proc_path .. "/sys/kernel/osrelease")
      or (uname and text(uname.release)),
    version = read_text(fs, self.proc_path .. "/sys/kernel/version")
      or (uname and text(uname.version)),
    command_line = read_text(fs, self.proc_path .. "/cmdline"),
  }

  -- /etc/os-release is a symlink into /usr/lib on most modern distributions,
  -- and the native reader refuses to follow a final symlink, so both canonical
  -- locations are tried in the order the standard specifies.
  local os_release
  for _, candidate in ipairs({ self.os_release_path, self.fallback_os_release_path }) do
    os_release = os_release or parse_os_release(fs:read(candidate, MAX_SMALL_FILE))
  end
  if os_release then
    data.distribution = {
      name = os_release.NAME,
      pretty_name = os_release.PRETTY_NAME,
      version = os_release.VERSION,
      version_id = os_release.VERSION_ID,
      id = os_release.ID,
      id_like = os_release.ID_LIKE,
      build_id = os_release.BUILD_ID,
      variant = os_release.VARIANT,
    }
  else
    data.quality_notes[#data.quality_notes + 1] = "os_release_unreadable"
  end

  local dmi, dmi_denied = read_dmi(fs, self.dmi_path)
  data.firmware = dmi
  if not dmi then
    data.quality_notes[#data.quality_notes + 1] =
      dmi_denied > 0 and "dmi_denied" or "dmi_unavailable"
  end

  data.virtualization = detect_virtualization(fs, dmi)
  data.security = read_security(fs)
  data.timezone = read_timezone(fs)

  local limits = {}
  for _, limit in ipairs(KERNEL_LIMITS) do
    limits[limit.key] = read_number(fs, limit.file)
  end
  limits.file_descriptors = parse_file_nr(fs:read(self.proc_path .. "/sys/fs/file-nr",
    MAX_SMALL_FILE))
  data.limits = limits

  data.swap = parse_swaps(fs:read(self.proc_path .. "/swaps", MAX_SMALL_FILE))
  data.vmstat = parse_vmstat(fs:read(self.proc_path .. "/vmstat", 1024 * 1024))

  local loadavg = read_text(fs, self.proc_path .. "/loadavg")
  if loadavg then
    local one, five, fifteen, running, total = loadavg:match(
      "^([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s+(%d+)/(%d+)")
    data.load = {
      one = number(one), five = number(five), fifteen = number(fifteen),
      running = number(running), total = number(total),
    }
  end

  -- /proc/stat's non-CPU metadata is boot-time and kernel-wide bookkeeping the
  -- CPU collector parses but never surfaces.
  local stat = fs:read(self.proc_path .. "/stat", 1024 * 1024)
  if type(stat) == "string" then
    local counters = {}
    for _, key in ipairs({ "btime", "ctxt", "processes", "procs_running", "procs_blocked", "intr" }) do
      local value = stat:match("\n" .. key .. "%s+(%d+)") or stat:match("^" .. key .. "%s+(%d+)")
      counters[key == "processes" and "forks" or key] = number(value)
    end
    data.boot_time_unix = counters.btime
    counters.btime = nil
    data.counters = counters
  end

  local finished = Common.now_ns(context)
  local quality = #data.quality_notes > 0 and "partial" or "fresh"
  if #data.quality_notes == 0 then data.quality_notes = nil end
  return Common.result("ok", finished, data, {
    quality = quality,
    duration_ns = Common.elapsed_ns(finished, started) or 0,
    source = self.proc_path,
  })
end

SystemInfo.parse_os_release = parse_os_release
SystemInfo.parse_swaps = parse_swaps
SystemInfo.parse_file_nr = parse_file_nr
SystemInfo.parse_uptime = parse_uptime
SystemInfo.CHASSIS_TYPES = CHASSIS_TYPES

return SystemInfo
