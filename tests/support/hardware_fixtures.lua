-- Realistic sysfs trees for hardware this project's CI and most development
-- machines do not have.
--
-- Every tree here is modelled on what the named driver actually publishes: the
-- same filenames, the same units, the same quirks (Intel reports temperature in
-- millidegrees while `pp_dpm_sclk` marks the active DPM level with a trailing
-- asterisk, RAPL energy counters are microjoules that wrap at
-- `max_energy_range_uj`, and a laptop battery may report charge in µAh instead
-- of energy in µWh).  Getting those details wrong here would make the tests
-- agree with a mistake rather than with the kernel.
local M = {}

-- ---------------------------------------------------------------------------
-- hwmon
-- ---------------------------------------------------------------------------

--- Intel `coretemp`: package plus per-core temperatures, no fan, no power.
function M.hwmon_coretemp(base)
  base = base or "/sys/class/hwmon"
  local device = base .. "/hwmon0"
  return {
    files = {
      [device .. "/name"] = "coretemp\n",
      [device .. "/temp1_label"] = "Package id 0\n",
      [device .. "/temp1_input"] = "47000\n",
      [device .. "/temp1_max"] = "100000\n",
      [device .. "/temp1_crit"] = "100000\n",
      [device .. "/temp1_crit_alarm"] = "0\n",
      [device .. "/temp2_label"] = "Core 0\n",
      [device .. "/temp2_input"] = "45000\n",
      [device .. "/temp2_max"] = "100000\n",
      [device .. "/temp2_crit"] = "100000\n",
      [device .. "/temp3_label"] = "Core 1\n",
      [device .. "/temp3_input"] = "88000\n",
      [device .. "/temp3_max"] = "100000\n",
      [device .. "/temp3_crit"] = "100000\n",
      [device .. "/temp3_crit_alarm"] = "1\n",
    },
    links = { [device] = "../../devices/platform/coretemp.0/hwmon/hwmon0" },
  }
end

--- AMD `k10temp` alongside a `nct6775` super-I/O chip that does publish fans,
--- voltages and power, so the non-temperature channel kinds get exercised.
function M.hwmon_nct6775(base)
  base = base or "/sys/class/hwmon"
  local device = base .. "/hwmon1"
  return {
    files = {
      [device .. "/name"] = "nct6798\n",
      [device .. "/temp1_label"] = "SYSTIN\n",
      [device .. "/temp1_input"] = "32000\n",
      [device .. "/fan1_label"] = "CPU fan\n",
      [device .. "/fan1_input"] = "1420\n",
      [device .. "/fan1_min"] = "300\n",
      [device .. "/fan1_alarm"] = "0\n",
      [device .. "/fan2_input"] = "0\n",
      [device .. "/fan2_fault"] = "1\n",
      [device .. "/in0_label"] = "Vcore\n",
      [device .. "/in0_input"] = "1024\n",
      [device .. "/power1_label"] = "Package power\n",
      [device .. "/power1_input"] = "45000000\n",
      [device .. "/curr1_input"] = "3500\n",
      -- A file the enumerator must ignore rather than mistake for a channel.
      [device .. "/update_interval"] = "1000\n",
      [device .. "/pwm1"] = "128\n",
    },
    links = { [device] = "../../devices/platform/nct6775.2592/hwmon/hwmon1" },
  }
end

-- ---------------------------------------------------------------------------
-- powercap / RAPL
-- ---------------------------------------------------------------------------

--- Intel RAPL with a package zone, two sub-zones and a separate psys domain.
--
-- `/sys/class/powercap` is a flat directory of symlinks: `intel-rapl:0:0` sits
-- beside `intel-rapl:0` rather than inside it, and the hierarchy is carried by
-- the colon-separated name.  `intel-rapl` itself is the control-type directory
-- and has no colon, so it must be ignored.
function M.powercap_intel_rapl(base)
  base = base or "/sys/class/powercap"
  local package = base .. "/intel-rapl:0"
  local core = base .. "/intel-rapl:0:0"
  local uncore = base .. "/intel-rapl:0:1"
  local psys = base .. "/intel-rapl-mmio:0"
  return {
    files = {
      [base .. "/intel-rapl/enabled"] = "1\n",

      [package .. "/name"] = "package-0\n",
      [package .. "/enabled"] = "1\n",
      [package .. "/energy_uj"] = "123456789012\n",
      [package .. "/max_energy_range_uj"] = "262143328850\n",
      [package .. "/constraint_0_name"] = "long_term\n",
      [package .. "/constraint_0_power_limit_uw"] = "65000000\n",
      [package .. "/constraint_0_time_window_us"] = "27983872\n",
      [package .. "/constraint_0_max_power_uw"] = "65000000\n",
      [package .. "/constraint_1_name"] = "short_term\n",
      [package .. "/constraint_1_power_limit_uw"] = "78000000\n",
      [package .. "/constraint_1_time_window_us"] = "2440\n",

      [core .. "/name"] = "core\n",
      [core .. "/enabled"] = "1\n",
      [core .. "/energy_uj"] = "45678901234\n",
      [core .. "/max_energy_range_uj"] = "262143328850\n",

      [uncore .. "/name"] = "uncore\n",
      [uncore .. "/enabled"] = "1\n",
      [uncore .. "/energy_uj"] = "1234567890\n",
      [uncore .. "/max_energy_range_uj"] = "262143328850\n",

      [psys .. "/name"] = "psys\n",
      [psys .. "/enabled"] = "1\n",
      [psys .. "/energy_uj"] = "987654321098\n",
      [psys .. "/max_energy_range_uj"] = "262143328850\n",
    },
    links = {
      [package] = "../../devices/virtual/powercap/intel-rapl/intel-rapl:0",
      [core] = "../../devices/virtual/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0",
      [uncore] = "../../devices/virtual/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:1",
      [psys] = "../../devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0",
    },
  }
end

--- The same tree one sample later, so a rate can be derived from the delta.
function M.powercap_intel_rapl_advanced(base, microjoules)
  local tree = M.powercap_intel_rapl(base)
  base = base or "/sys/class/powercap"
  local package = base .. "/intel-rapl:0"
  local core = base .. "/intel-rapl:0:0"
  tree.files[package .. "/energy_uj"] = tostring(123456789012 + microjoules) .. "\n"
  tree.files[core .. "/energy_uj"] = tostring(45678901234 + microjoules // 2) .. "\n"
  return tree
end

-- ---------------------------------------------------------------------------
-- cpufreq
-- ---------------------------------------------------------------------------

--- Four policies driven by `intel_pstate`, one of them shared by two CPUs.
function M.cpufreq_policies(base)
  base = base or "/sys/devices/system/cpu/cpufreq"
  local files = {}
  local layout = {
    { policy = "policy0", cpus = "0 1", current = 3200000 },
    { policy = "policy2", cpus = "2", current = 800000 },
    { policy = "policy3", cpus = "3", current = 4700000 },
  }
  for _, entry in ipairs(layout) do
    local path = base .. "/" .. entry.policy
    files[path .. "/affected_cpus"] = entry.cpus .. "\n"
    files[path .. "/related_cpus"] = entry.cpus .. "\n"
    files[path .. "/scaling_cur_freq"] = tostring(entry.current) .. "\n"
    files[path .. "/scaling_min_freq"] = "800000\n"
    files[path .. "/scaling_max_freq"] = "4700000\n"
    files[path .. "/cpuinfo_min_freq"] = "800000\n"
    files[path .. "/cpuinfo_max_freq"] = "4700000\n"
    files[path .. "/scaling_governor"] = "powersave\n"
    files[path .. "/scaling_driver"] = "intel_pstate\n"
    files[path .. "/energy_performance_preference"] = "balance_performance\n"
    files[path .. "/scaling_available_governors"] = "performance powersave\n"
  end
  files[base .. "/boost"] = "1\n"
  return { files = files }
end

-- ---------------------------------------------------------------------------
-- DRM / GPU
-- ---------------------------------------------------------------------------

--- An AMD discrete GPU (amdgpu) with VRAM, GTT, DPM levels and a hwmon link.
function M.drm_amdgpu(base)
  base = base or "/sys/class/drm"
  local card = base .. "/card0"
  local device = card .. "/device"
  return {
    files = {
      [card .. "/dev"] = "226:0\n",
      [card .. "/uevent"] = "MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\n",
      [device .. "/vendor"] = "0x1002\n",
      [device .. "/device"] = "0x744c\n",
      [device .. "/subsystem_vendor"] = "0x1002\n",
      [device .. "/subsystem_device"] = "0x0e3b\n",
      [device .. "/revision"] = "0xc8\n",
      [device .. "/class"] = "0x030000\n",
      [device .. "/boot_vga"] = "1\n",
      [device .. "/numa_node"] = "-1\n",
      [device .. "/modalias"] = "pci:v00001002d0000744Csv00001002sd00000E3Bbc03sc00i00\n",
      [device .. "/power/runtime_status"] = "active\n",
      [device .. "/current_link_speed"] = "16.0 GT/s PCIe\n",
      [device .. "/current_link_width"] = "16\n",
      [device .. "/max_link_speed"] = "16.0 GT/s PCIe\n",
      [device .. "/max_link_width"] = "16\n",
      [device .. "/gpu_busy_percent"] = "73\n",
      [device .. "/mem_busy_percent"] = "41\n",
      [device .. "/mem_info_vram_total"] = "25753026560\n",
      [device .. "/mem_info_vram_used"] = "3221225472\n",
      [device .. "/mem_info_vis_vram_total"] = "25753026560\n",
      [device .. "/mem_info_vis_vram_used"] = "1073741824\n",
      [device .. "/mem_info_gtt_total"] = "25753026560\n",
      [device .. "/mem_info_gtt_used"] = "536870912\n",
      -- The active DPM level carries a trailing asterisk.
      [device .. "/pp_dpm_sclk"] = "0: 500Mhz\n1: 1500Mhz *\n2: 2500Mhz\n",
      [device .. "/pp_dpm_mclk"] = "0: 96Mhz\n1: 1249Mhz *\n",
      [device .. "/hwmon/hwmon5/name"] = "amdgpu\n",
      [device .. "/hwmon/hwmon5/temp1_label"] = "edge\n",
      [device .. "/hwmon/hwmon5/temp1_input"] = "61000\n",
      [device .. "/hwmon/hwmon5/temp1_crit"] = "100000\n",
      [device .. "/hwmon/hwmon5/power1_label"] = "PPT\n",
      [device .. "/hwmon/hwmon5/power1_input"] = "212000000\n",
      [device .. "/hwmon/hwmon5/fan1_input"] = "1650\n",
    },
    links = {
      [card] = "../../devices/pci0000:00/0000:00:01.0/0000:01:00.0/drm/card0",
      [device] = "../../../0000:01:00.0",
      [device .. "/driver"] = "../../../../bus/pci/drivers/amdgpu",
    },
  }
end

--- An Intel integrated GPU (i915), which publishes frequencies but no VRAM.
function M.drm_i915(base)
  base = base or "/sys/class/drm"
  local card = base .. "/card1"
  local device = card .. "/device"
  return {
    files = {
      [card .. "/dev"] = "226:1\n",
      [card .. "/uevent"] = "MAJOR=226\nMINOR=1\nDEVNAME=dri/card1\n",
      [card .. "/gt_cur_freq_mhz"] = "1450\n",
      [card .. "/gt_act_freq_mhz"] = "1400\n",
      [card .. "/gt_min_freq_mhz"] = "300\n",
      [card .. "/gt_max_freq_mhz"] = "1550\n",
      [device .. "/vendor"] = "0x8086\n",
      [device .. "/device"] = "0x4680\n",
      [device .. "/subsystem_vendor"] = "0x1043\n",
      [device .. "/subsystem_device"] = "0x8694\n",
      [device .. "/revision"] = "0x0c\n",
      [device .. "/class"] = "0x030000\n",
      [device .. "/boot_vga"] = "0\n",
      [device .. "/numa_node"] = "0\n",
      [device .. "/power/runtime_status"] = "suspended\n",
      [device .. "/current_link_speed"] = "Unknown\n",
      [device .. "/current_link_width"] = "Unknown\n",
    },
    links = {
      [card] = "../../devices/pci0000:00/0000:00:02.0/drm/card1",
      [device] = "../../../0000:00:02.0",
      [device .. "/driver"] = "../../../../bus/pci/drivers/i915",
    },
  }
end

--- The render node that sits beside a card, plus a process holding it open
--- with DRM fdinfo accounting.
function M.drm_render_and_clients(drm_base, proc_base)
  drm_base = drm_base or "/sys/class/drm"
  proc_base = proc_base or "/proc"
  local render = drm_base .. "/renderD128"
  return {
    files = {
      [render .. "/dev"] = "226:128\n",
      [render .. "/uevent"] = "MAJOR=226\nMINOR=128\nDEVNAME=dri/renderD128\n",

      [proc_base .. "/4242/comm"] = "glxgears\n",
      [proc_base .. "/4242/stat"] =
        "4242 (glxgears) S 1 4242 4242 0 -1 4194304 1000 0 0 0 120 35 0 0 20 0 3 0 900 "
        .. "123456789 4096 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 2 0 0 0 0 0\n",
      [proc_base .. "/4242/fdinfo/3"] =
        "pos:\t0\nflags:\t0100002\nmnt_id:\t26\n"
        .. "drm-driver:\tamdgpu\ndrm-client-id:\t17\ndrm-pdev:\t0000:01:00.0\n"
        .. "drm-engine-gfx:\t1234567890 ns\ndrm-engine-compute:\t45678 ns\n"
        .. "drm-memory-vram:\t262144 KiB\ndrm-memory-gtt:\t65536 KiB\n",
      [proc_base .. "/4242/fdinfo/4"] = "pos:\t0\nflags:\t02\nmnt_id:\t26\n",
    },
    links = {
      [render] = "../../devices/pci0000:00/0000:00:01.0/0000:01:00.0/drm/renderD128",
      [proc_base .. "/4242/fd/3"] = "/dev/dri/renderD128",
      [proc_base .. "/4242/fd/4"] = "/dev/null",
    },
  }
end

-- ---------------------------------------------------------------------------
-- power supplies
-- ---------------------------------------------------------------------------

--- A laptop reporting charge in µAh (the ACPI style), a second battery
--- reporting energy in µWh, and a disconnected mains adapter.
function M.power_supply_laptop(base)
  base = base or "/sys/class/power_supply"
  return {
    files = {
      [base .. "/BAT0/type"] = "Battery\n",
      [base .. "/BAT0/present"] = "1\n",
      [base .. "/BAT0/status"] = "Discharging\n",
      [base .. "/BAT0/technology"] = "Li-poly\n",
      [base .. "/BAT0/manufacturer"] = "Example Cells\n",
      [base .. "/BAT0/model_name"] = "EX-5500\n",
      [base .. "/BAT0/cycle_count"] = "212\n",
      [base .. "/BAT0/capacity"] = "48\n",
      [base .. "/BAT0/capacity_level"] = "Normal\n",
      [base .. "/BAT0/voltage_now"] = "11400000\n",
      [base .. "/BAT0/voltage_min_design"] = "11250000\n",
      [base .. "/BAT0/charge_now"] = "2400000\n",
      [base .. "/BAT0/charge_full"] = "5000000\n",
      [base .. "/BAT0/charge_full_design"] = "5500000\n",
      [base .. "/BAT0/current_now"] = "1500000\n",

      [base .. "/BAT1/type"] = "Battery\n",
      [base .. "/BAT1/present"] = "1\n",
      [base .. "/BAT1/status"] = "Charging\n",
      [base .. "/BAT1/capacity"] = "80\n",
      [base .. "/BAT1/voltage_now"] = "12000000\n",
      [base .. "/BAT1/energy_now"] = "40000000\n",
      [base .. "/BAT1/energy_full"] = "50000000\n",
      [base .. "/BAT1/energy_full_design"] = "56000000\n",
      [base .. "/BAT1/power_now"] = "20000000\n",

      [base .. "/AC/type"] = "Mains\n",
      [base .. "/AC/online"] = "0\n",
    },
  }
end

return M
