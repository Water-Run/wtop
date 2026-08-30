package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local JSON = require("wtop.core.json")
local Runner = require("wtop.core.runner")
local Registry = require("wtop.inspectors.registry")
local Smart = require("wtop.inspectors.smart")
local Bandwidth = require("wtop.inspectors.ram_bandwidth")
local Service = require("wtop.inspectors.service")
local SSHD = require("wtop.inspectors.sshd")

local function fixture(path)
  local file = assert(io.open("tests/fixtures/" .. path, "rb"))
  local content = assert(file:read("*a"))
  file:close()
  return content
end

local function fake_fs(files, directories)
  files, directories = files or {}, directories or {}
  local fs = {}
  function fs:read(path)
    if files[path] == nil then
      return nil, { kind = "missing", message = "fixture_missing", path = path }
    end
    return tostring(files[path])
  end
  function fs:read_number(path)
    local value, err = self:read(path)
    if not value then return nil, err end
    return tonumber(value:match("^%s*([^%s]+)"))
  end
  function fs:list(path, limit)
    local values = directories[path]
    if not values then return nil, { kind = "missing", message = "directory_missing", path = path } end
    local result = {}
    local maximum = math.min(#values, limit or #values)
    for index = 1, maximum do result[index] = values[index] end
    return result, nil, limit ~= nil and #values > limit
  end
  function fs:exists(path)
    return files[path] ~= nil
  end
  function fs:readlink(path)
    return nil, { kind = "missing", message = "link_missing", path = path }
  end
  return fs
end

local function section(result, id)
  for _, value in ipairs(result.sections or {}) do
    if value.id == id then return value end
  end
end

local now = 1000000000
local clock = { now_ns = function() return now end }
local calls = 0
local observed_argv
local smart_runner = Runner.new({
  execute = function(argv, policy)
    calls = calls + 1
    observed_argv = argv
    assert(policy.timeout_ms == 2000)
    assert(policy.env.LC_ALL == "C")
    return {
      status = "ok",
      exit_code = 8,
      stdout = fixture("inspectors/smart-nvme.json"),
      stderr = "",
    }
  end,
})
local smart = Smart.new({ runner = smart_runner, clock = clock })
assert(smart:probe({ smartctl_available = true }).available)
local smart_result = smart:inspect({}, { id = "/dev/nvme0", path = "/dev/nvme0" }, "full")
assert(smart_result.status == "ok")
assert(observed_argv[1] == "/usr/sbin/smartctl" and observed_argv[#observed_argv] == "/dev/nvme0")
assert(section(smart_result, "identity").fields.kind.value == "nvme")
assert(section(smart_result, "identity").fields.serial.value:sub(-4) == "7890")
assert(not section(smart_result, "identity").fields.serial.value:find("WRNVME", 1, true))
assert(section(smart_result, "nvme_health").fields.percentage_used.value == 3)
assert(smart_result.entity.evidence.exit_code == 8, "smartctl health bit exits must retain parsed data")
local cached = smart:inspect({}, { id = "/dev/nvme0", path = "/dev/nvme0" }, "full")
assert(cached.cached and calls == 1)
smart:invalidate({ path = "/dev/nvme0" })
smart:inspect({}, { id = "/dev/nvme0", path = "/dev/nvme0" }, "full")
assert(calls == 2)
assert(Smart.safe_device_path("/dev/sda"))
assert(not Smart.safe_device_path("/tmp/disk"))

local block_path = "/sys/class/block"
local bounded_smart = Smart.new({
  fs = fake_fs({}, { [block_path] = { "sda", "sdb" } }),
  block_path = block_path,
  max_devices = 1,
})
local bounded_devices = assert(bounded_smart:enumerate({ fs = bounded_smart.fs }))
assert(#bounded_devices == 1 and bounded_devices[1].name == "sda")
assert(bounded_devices.truncated == true)

local hybrid = assert(JSON.decode(fixture("inspectors/smart-sshd.json")))
assert(Smart.explicit_device_kind(hybrid) == "sshd")
assert(Smart.explicit_device_kind({ rotation_rate = 7200, model_name = "ordinary disk" }) == "hdd")
assert(Smart.explicit_device_kind({ model_name = "unknown cache disk" }) == "unknown")

local pmu_base = "/sys/bus/event_source/devices"
local bandwidth_fs = fake_fs({
  [pmu_base .. "/uncore_imc_0/type"] = "12\n",
  [pmu_base .. "/uncore_imc_0/cpumask"] = "0,4\n",
  [pmu_base .. "/uncore_imc_0/events/cas_count_read"] = "event=0x04,umask=0x03\n",
  [pmu_base .. "/uncore_imc_0/events/cas_count_write"] = "event=0x04,umask=0x0c\n",
  ["/proc/sys/kernel/perf_event_paranoid"] = "2\n",
}, {
  [pmu_base] = { "cpu", "uncore_imc_0" },
  [pmu_base .. "/uncore_imc_0/events"] = { "cas_count_read", "cas_count_write" },
})
local bandwidth = Bandwidth.new({ fs = bandwidth_fs, clock = clock })
local bandwidth_capability = bandwidth:probe({ fs = bandwidth_fs, perf_reader = function() end })
assert(bandwidth_capability.available)
local pmus = assert(bandwidth:enumerate({ fs = bandwidth_fs }))
assert(#pmus == 1 and pmus[1].type == 12 and pmus[1].cpus[2] == 4)
assert(pmus[1].events.cas_count_read.event == 4)
local theoretical = assert(Bandwidth.theoretical_bytes_per_second(3200, 2, 64))
assert(theoretical == 51200000000)
local bandwidth_result = bandwidth:inspect({
  fs = bandwidth_fs,
  perf_reader = function(request)
    assert(#request.pmus == 1)
    return {
      status = "ok",
      read_bytes = 1000000000,
      write_bytes = 500000000,
      duration_ns = 1000000000,
      formula_version = "intel-fixture-v1",
    }
  end,
}, {
  id = "system-memory",
  data_rate_mt_s = 3200,
  channels = 2,
  bus_width_bits = 64,
  topology_source = "fixture-dmi",
})
assert(bandwidth_result.status == "ok" and bandwidth_result.quality == "fresh")
local bandwidth_fields = section(bandwidth_result, "bandwidth").fields
assert(bandwidth_fields.read_bandwidth.value == 1000000000)
assert(bandwidth_fields.total_bandwidth.value == 1500000000)
assert(bandwidth_fields.theoretical_bandwidth.quality == "estimated")
assert(bandwidth_fields.utilization.value > 2.9 and bandwidth_fields.utilization.value < 3.0)

local service_fs = fake_fs({
  ["/proc/net/tcp"] = fixture("inspectors/proc-net-tcp"),
})
local sshd = SSHD.new({ fs = service_fs, clock = clock })
local show = Service.parse_systemctl_show(fixture("inspectors/systemctl-sshd.show"))
assert(show.ActiveState == "active" and show.MainPID == 4242)
assert(show.Environment == nil, "systemd fields must be whitelisted")
local parsed_sockets = Service.parse_proc_net(fixture("inspectors/proc-net-tcp"), "ipv4")
assert(#parsed_sockets == 2 and parsed_sockets[1].port == 22 and parsed_sockets[1].inode == 12345)
local service_result = sshd:inspect({
  fs = service_fs,
  systemd_show = fixture("inspectors/systemctl-sshd.show"),
  processes = { list = {
    { id = "4242:10", pid = 4242, name = "sshd", state = "S", resident_bytes = 4096000 },
    { id = "5000:11", pid = 5000, name = "unrelated", state = "S" },
  } },
  effective_config = "Port 22\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nUnsafeSecret ignored\n",
  config_source = "sshd -T fixture",
  sessions = {
    { user = "alice", tty = "pts/1", remote = "203.0.113.45", idle_seconds = 10, pid = 4300 },
  },
  sessions_source = "fixture-session-provider",
  recent_events = { { severity = "warning", code = "auth_failed" } },
  events_source = "fixture-journal-provider",
})
assert(service_result.status == "ok")
assert(section(service_result, "service").fields.active_state.value == "active")
local listeners = section(service_result, "listeners").fields.listeners.value
assert(#listeners == 1 and listeners[1].port == 22, "host-wide unrelated sockets must be filtered")
assert(section(service_result, "sessions").fields.active_sessions.value[1].remote == "203.0.x.x")
local config = section(service_result, "configuration").fields.effective.value
assert(config.port == "22" and config.unsafesecret == nil)

local registry = Registry.new()
assert(registry:register(smart))
assert(registry:register(bandwidth))
assert(registry:register(sshd))
assert(#registry:list() == 3 and #registry:list("storage") == 1)
assert(not registry:register(smart))
assert(registry:get("service.sshd") == sshd)

return true
