-- What a disk's temperature figure actually is, and which disk a sensor
-- device belongs to.  The join keys on the basename of the sensor device's
-- `device_target`, because disks publish no `class` the way amdgpu does: the
-- target's basename is the honest key that is left, and the nvme
-- controller-to-namespace rule is the one piece of kernel naming it encodes.
-- The hottest channel is the figure -- it is the one that throttles -- and
-- the mount join carries the topology the rest of the way, so a claim in the
-- sensor overlay names a model and a mount point rather than a bare nvme0.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local ViewModel = require("wtop.view_model")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      message, tostring(expected), tostring(actual)), 0)
  end
end

local function channel(kind, index, input, label)
  return { type = kind, index = index, input = input, label = label }
end

local function sensor(name, target, channels)
  return { name = name, device_target = target,
    channels = channels, quality = "fresh",
    source = "/sys/class/hwmon/hwmon9/" .. name }
end

local function disk(name, model, extra)
  local value = { name = name, id = name, is_partition = false,
    identity = { model = model, rotational = 0,
      size_bytes = 1024 * 1024 * 1024 * 512 },
    read_bytes_per_second = 0, write_bytes_per_second = 0,
    busy_percent = 0 }
  for key, item in pairs(extra or {}) do value[key] = item end
  return value
end

local function snapshot(disks, sensors, mounts)
  return {
    disks = { devices = disks },
    sensors = { devices = sensors },
    mounts = { mounts = mounts or {} },
  }
end

local translator = assert(I18n.new({ locale = "en-US" }))
local engine = { history_values = function() return {} end }
local function disk_table(state)
  return ViewModel.build(engine, state, translator, {}, "storage").disk_table
end

-- 1. An nvme controller's sensor device belongs to its namespace: the
-- composite temperature reaches the table, and the channel is named.
local nvme = snapshot(
  { disk("nvme0n1", "WD PC SN740"), disk("nvme0n1p3", nil, { is_partition = true }) },
  { sensor("nvme", "../../nvme0", {
      channel("temperature", 1, 42, "Composite"),
      channel("temperature", 2, 51, "Sensor 1"),
    }) },
  { { mount_point = "/", source = "/dev/nvme0n1p3", kind = "local" },
    { mount_point = "/boot/efi", source = "/dev/nvme0n1p1", kind = "local" } })
local nvme_row = disk_table(nvme).rows[1]
equal(nvme_row.device, "nvme0n1", "the namespace disk is the row")
equal(nvme_row.temperature, "51 °C", "the hottest sensor channel is the figure")
equal(nvme_row.temperature_source.label, "Sensor 1",
  "the channel that produced it is known")

-- 2. The controller number is a boundary, not a prefix: nvme0 does not own
-- nvme10n1, and a target naming no disk in the snapshot owns nothing.
local wrong_namespace = snapshot(
  { disk("nvme10n1", "Other") },
  { sensor("nvme", "../../nvme1", { channel("temperature", 1, 40) }) })
equal(#ViewModel.disk_sensor_join(wrong_namespace), 0,
  "a controller whose namespace is absent claims no sensor device")

-- 3. A SATA disk names itself outright; a thermal zone never matches.
local sata = snapshot(
  { disk("sda", "Samsung SSD 860") },
  { sensor("sata", "../sda", { channel("temperature", 1, 33) }),
    sensor("acpitz", "../../thermal_zone0", { channel("temperature", 1, 44) }) })
local sata_row = disk_table(sata).rows[1]
equal(sata_row.temperature, "33 °C", "a self-named target joins directly")
equal(sata_row.temperature_source.index, 1, "the channel is identified")

-- 4. No match is the ordinary case for most sensors, and the cell says so
-- rather than borrowing another device's number.
local lonely = snapshot(
  { disk("sdb", "None") },
  { sensor("coretemp", "../../../coretemp.0", { channel("temperature", 1, 71) }) })
equal(disk_table(lonely).rows[1].temperature, "—",
  "a CPU sensor is not attributed to a disk")

-- 5. Channels without a reading, and channels that are not temperatures,
-- never become figures.
local quiet = snapshot(
  { disk("sdc", "Any") },
  { sensor("quiet", "../sdc", {
      channel("temperature", 1, nil),
      channel("voltage", 1, 5.0),
      channel("current", 1, 0.4),
    }) })
equal(disk_table(quiet).rows[1].temperature, "—",
  "no temperature input, no figure")

-- 6. The mount join: the shortest mount point on the owning disk wins,
-- because "/" is the answer to "which disk is the system on".
local mounts = ViewModel.disk_mount_join(snapshot(
  { disk("nvme0n1", "WD"), disk("loop0", nil, { identity = { virtual = true } }) },
  {},
  { { mount_point = "/", source = "/dev/nvme0n1p3", kind = "local" },
    { mount_point = "/home/user/data", source = "/dev/nvme0n1p3", kind = "local" },
    { mount_point = "/mnt/other", source = "tmpfs", kind = "pseudo" } }))
equal(mounts["nvme0n1"], "/", "the shortest mount point on the disk wins")
equal(mounts["loop0"], nil, "a source that extends no disk name owns nothing")

-- 7. The join is a single implementation, so the overlay's account cannot
-- drift from the table's: the claim names the disk, the model and the mount.
local overlay = table.concat(
  TUI.sensor_detail_lines(nvme, translator, nil), "\n")
equal(overlay:find("Disk nvme0n1 (WD PC SN740 · mounted at /) reads this device",
  1, true) ~= nil, true,
  "the overlay names the disk, its model and its mount: " .. overlay)
equal(overlay:find("Temperature ← Sensor 1", 1, true) ~= nil, true,
  "the overlay names the temperature channel: " .. overlay)

-- A device no disk reads gets no claim at all.
local unclaimed = table.concat(
  TUI.sensor_detail_lines(lonely, translator, nil), "\n")
equal(unclaimed:find("reads this device", 1, true), nil,
  "a CPU sensor is not claimed by any disk: " .. unclaimed)

-- 8. Degenerate snapshots join to nothing without erroring.
equal(type(ViewModel.disk_sensor_join({})), "table", "an empty snapshot still joins")
equal(type(ViewModel.disk_sensor_join(nil)), "table", "a missing snapshot still joins")
equal(type(ViewModel.disk_mount_join(nil)), "table", "mounts join an empty snapshot")

-- 9. The table declares the column it now draws, with a width that holds the
-- widest honest value rather than truncating a number into another number.
local columns = disk_table(nvme).columns
local temperature_column = nil
for _, column in ipairs(columns) do
  if column.key == "temperature" then temperature_column = column end
end
assert(temperature_column, "the storage table declares no temperature column")
assert(type(temperature_column.min_width) == "number"
    and temperature_column.min_width >= 7,
  "the temperature column must reserve room for a figure like -40 °C")

return true
