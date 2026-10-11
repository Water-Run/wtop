package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Network = require("wtop.collectors.network")
local Export = require("wtop.export")
local Parsers = require("wtop.linux.parsers")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local ViewModel = require("wtop.view_model")
local Width = require("wtop.ui.renderer.width")

local handle = assert(io.open("tests/fixtures/proc/netdev.1", "rb"))
local netdev = assert(handle:read("*a"))
handle:close()

local function softnet_line(processed, dropped, squeezed, backlog, cpu, input, processing)
  local fields = { processed, dropped, squeezed }
  for index = 4, 11 do fields[index] = 0 end
  fields[12], fields[13], fields[14], fields[15] = backlog, cpu, input, processing
  local output = {}
  for _, value in ipairs(fields) do output[#output + 1] = string.format("%08x", value) end
  return table.concat(output, " ") .. "\n"
end
local first_softnet = softnet_line(100, 2, 1, 3, 0, 1, 2)
  .. softnet_line(200, 0, 0, 5, 1, 3, 2)
assert(Parsers.softnet_stat("00000001 00000000 00000000\n").indexed == false,
  "older softnet layouts can be read without inventing a CPU identity")
assert(Parsers.softnet_stat("xyz 00000000 00000000\n") == nil)
assert(Parsers.softnet_stat(softnet_line(1, 0, 0, 0, 0, 0, 0)
  .. softnet_line(2, 0, 0, 0, 0, 0, 0)) == nil,
  "duplicate CPU ids cannot be summed as two CPUs")

local files = {
  ["/proc/net/dev"] = netdev,
  ["/proc/net/softnet_stat"] = first_softnet,
  ["/sys/class/net/lo/ifindex"] = "1\n",
  ["/sys/class/net/eth0/ifindex"] = "2\n",
  ["/sys/class/net/lo/carrier_changes"] = "0\n",
  ["/sys/class/net/lo/carrier_up_count"] = "0\n",
  ["/sys/class/net/lo/carrier_down_count"] = "0\n",
  ["/sys/class/net/eth0/carrier_changes"] = "4\n",
  ["/sys/class/net/eth0/carrier_up_count"] = "2\n",
  ["/sys/class/net/eth0/carrier_down_count"] = "2\n",
  ["/sys/class/net/lo/queues/tx-0/tx_timeout"] = "0\n",
  ["/sys/class/net/eth0/queues/tx-0/tx_timeout"] = "4\n",
  ["/sys/class/net/lo/queues/rx-0/rps_cpus"] = "0000\n",
  ["/sys/class/net/lo/queues/rx-0/rps_flow_cnt"] = "0\n",
  ["/sys/class/net/lo/queues/tx-0/xps_rxqs"] = "0\n",
  ["/sys/class/net/lo/queues/tx-0/tx_maxrate"] = "0\n",
  ["/sys/class/net/eth0/queues/rx-0/rps_cpus"] = "0003\n",
  ["/sys/class/net/eth0/queues/rx-0/rps_flow_cnt"] = "64\n",
  ["/sys/class/net/eth0/queues/rx-1/rps_cpus"] = "0000\n",
  ["/sys/class/net/eth0/queues/rx-1/rps_flow_cnt"] = "0\n",
  ["/sys/class/net/eth0/queues/tx-0/xps_cpus"] = "0003\n",
  ["/sys/class/net/eth0/queues/tx-0/xps_rxqs"] = "0\n",
  ["/sys/class/net/eth0/queues/tx-0/tx_maxrate"] = "1000\n",
}
local directories = {
  ["/sys/class/net/lo/queues"] = { "rx-0", "tx-0" },
  ["/sys/class/net/eth0/queues"] = { "rx-0", "rx-1", "tx-0", "notes" },
}
local truncated = {}
local list_calls = 0
local fs = {}
function fs:read(path)
  if type(files[path]) == "table" and files[path].kind then
    return nil, files[path]
  end
  if files[path] then return files[path] end
  return nil, { kind = "missing", path = path }
end
function fs:read_number(path)
  local value, err = self:read(path)
  return value and tonumber(value) or nil, err
end
function fs:list(path)
  list_calls = list_calls + 1
  if directories[path] == "denied" then
    return nil, { kind = "denied", path = path }
  end
  if directories[path] then
    return directories[path], nil, truncated[path]
  end
  return nil, { kind = "missing", path = path }
end
function fs:readlink()
  return nil, { kind = "missing" }
end

local now = 1000000000
local context = { fs = fs, now_ns = function() return now end }
local collector = Network.new()
local function eth0(sample)
  for _, interface in ipairs(sample.data.interfaces) do
    if interface.name == "eth0" then return interface end
  end
  error("eth0 missing from the network fixture")
end
local function equal(actual, expected, label)
  assert(actual == expected,
    string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
end

local first = collector:sample(context)
equal(first.data.softnet.status, "ok", "softnet source status")
equal(first.data.softnet.quality, "gap", "a first softnet read has no rate")
equal(first.data.softnet.cpu_count, 2, "observed softnet CPU count")
equal(first.data.softnet.backlog_packets, 8, "per-CPU receive queues sum only as softnet backlog")
equal(first.data.softnet.hot_cpu, 1, "largest backlog keeps its CPU identity")
equal(first.data.softnet.dropped_per_second, nil, "the first sample is unknown, not zero")
local interface = eth0(first)
equal(interface.link_events.status, "ok", "carrier transition counters are readable")
equal(interface.link_events.changes_total, 4, "lifetime link changes are retained")
equal(interface.link_events.change.quality, "gap", "first sample has no new transitions")
equal(interface.queues.rx_count, 2, "visible receive queues")
equal(interface.queues.tx_count, 1, "visible transmit queues")
equal(interface.queues.status, "ok", "unrelated entries do not invent queues")
equal(interface.queues.tx_timeout_total, 4, "TX queue timeout count is read")
equal(interface.queues.timeout_status, "ok", "complete TX timeout data has its own status")
equal(interface.queues.timeout_change.quality, "gap",
  "a first queue scan has no previous timeout count")
equal(interface.queues.config_status, "ok", "queue steering and cap fields are readable")
equal(interface.queues.rx_details[1].rps_cpus, "0003", "RPS CPU mask stays per RX queue")
equal(interface.queues.rx_details[1].rps_flow_count, 64,
  "RPS flow count stays per RX queue")
equal(interface.queues.tx_details[1].xps_cpus, "0003", "XPS CPU mask stays per TX queue")
equal(interface.queues.tx_details[1].maxrate_mbps, 1000,
  "TX max rate retains its Mbps unit")
equal(interface.queues.tx_details[1].rate_limit_enabled, true,
  "a positive TX max rate is an enabled limit")
local snapshot = { network = first.data, quality = {} }
local exported = Export.snapshot(snapshot).network.interfaces
local exported_eth0
for _, row in ipairs(exported) do
  if row.name == "eth0" then exported_eth0 = row end
end
equal(exported_eth0.queues.rx_count, 2, "queue topology reaches Snapshot JSON")
equal(exported_eth0.queues.tx_timeout_total, 4, "TX timeout total reaches JSON")
equal(exported_eth0.queues.tx_timeouts[1].id, 0, "per-queue identity reaches JSON")
equal(exported_eth0.queues.tx_timeouts[1].total, 4, "per-queue count reaches JSON")
equal(exported_eth0.queues.rx_details[1].rps_flow_count, 64,
  "RPS queue detail reaches JSON")
equal(exported_eth0.queues.tx_details[1].maxrate_mbps, 1000,
  "XPS and rate-cap detail reaches JSON")
equal(exported_eth0.queues.scanned_ns, nil, "internal refresh time stays out of JSON")
equal(exported_eth0.link_events.changes_total, 4,
  "carrier transitions reach Snapshot without borrowing interface packet drops")
equal(exported_eth0.link_events.change.quality, "gap",
  "Snapshot labels the missing first delta")
local first_export = Export.snapshot(snapshot).network.softnet
equal(first_export.per_cpu[2].cpu, 1, "per-CPU softnet identity reaches Snapshot")
equal(first_export.backlog_packets, 8, "softnet backlog reaches Snapshot")
equal(first_export.dropped_per_second, nil, "first-sample gap reaches Snapshot")
local oversized_softnet = { status = "ok", cpu_count = 300, per_cpu = {} }
for cpu = 0, 299 do
  oversized_softnet.per_cpu[#oversized_softnet.per_cpu + 1] = {
    cpu = cpu, dropped = 0, private = "omit",
  }
end
local bounded_export = Export.snapshot({ network = {
  interfaces = {}, softnet = oversized_softnet,
} }).network.softnet
equal(bounded_export.exported, 256, "softnet JSON caps the per-CPU list")
assert(bounded_export.truncated and bounded_export.cpu_count == 300
  and bounded_export.per_cpu[1].private == nil,
  "the cap and field whitelist disclose what was omitted")
local translator = assert(I18n.new({ locale = "en-US" }))
local detail = table.concat(TUI.hardware_detail_lines(snapshot, "net:2", translator), "\n")
assert(detail:find("RX queues: 2", 1, true)
    and detail:find("Carrier changes: 4", 1, true)
    and detail:find("Link down reports: 2", 1, true)
    and detail:find("TX queues: 1", 1, true)
    and detail:find("TX timeout reports: 4", 1, true)
    and detail:find("tx-0: 4", 1, true)
    and detail:find("RPS-enabled RX queues: 1", 1, true)
    and detail:find("XPS-enabled TX queues: 1", 1, true)
    and detail:find("Rate-capped TX queues: 1", 1, true),
  "network device detail shows queue health and steering configuration")

directories["/sys/class/net/eth0/queues"] = { "rx-0", "rx-1", "rx-2", "tx-0" }
files["/sys/class/net/eth0/queues/tx-0/tx_timeout"] = "7\n"
files["/sys/class/net/eth0/queues/rx-0/rps_cpus"] = "0000\n"
files["/sys/class/net/eth0/queues/tx-0/xps_cpus"] = "0000\n"
files["/sys/class/net/eth0/queues/tx-0/tx_maxrate"] = "0\n"
files["/sys/class/net/eth0/carrier_changes"] = "7\n"
files["/sys/class/net/eth0/carrier_up_count"] = "3\n"
files["/sys/class/net/eth0/carrier_down_count"] = "4\n"
files["/proc/net/softnet_stat"] = softnet_line(110, 4, 3, 0, 0, 0, 0)
  .. softnet_line(210, 1, 1, 2, 1, 1, 1)
now = now + 1000000000
local cached = collector:sample(context, first)
equal(eth0(cached).link_events.change.quality, "fresh",
  "unchanged interface identity supports a carrier delta")
equal(eth0(cached).link_events.change.new_changes, 3,
  "a recovered link still exposes transitions between samples")
equal(eth0(cached).link_events.change.new_up, 1,
  "new up transitions remain separate")
equal(eth0(cached).link_events.change.new_down, 2,
  "new down transitions remain separate")
equal(cached.data.softnet.quality, "fresh", "matching CPU ids establish rates")
equal(cached.data.softnet.new_dropped, 3, "drops are differenced per CPU")
equal(cached.data.softnet.dropped_per_second, 3, "drop rate uses the actual interval")
equal(cached.data.softnet.time_squeeze_per_second, 3,
  "budget-squeeze events are separate from lost packets")
equal(cached.data.softnet.backlog_packets, 2, "backlog is an instantaneous queue length")
local cached_export = Export.snapshot({ network = cached.data }).network.softnet
equal(cached_export.per_cpu[1].dropped_per_second, 2,
  "per-CPU drop rates reach the bounded Snapshot list")
equal(Export.agent({ network = cached.data }).metrics.network.softnet_dropped_per_second,
  3, "Agent reports the compact softnet drop rate")
local network_export = Export.snapshot({ network = cached.data }).network.interfaces[2]
equal(network_export.link_events.change.new_changes, 3,
  "new carrier transitions reach Snapshot")
local agent_interfaces = Export.agent({ network = cached.data }).top.interfaces
local agent_eth0
for _, item in ipairs(agent_interfaces) do
  if item.name == "eth0" then agent_eth0 = item end
end
equal(agent_eth0.new_link_changes, 3,
  "Agent's compact interface row includes new link changes")
local model_snapshot = { network = cached.data, cpu = {}, memory = {}, pressure = {},
  disks = {}, connections = {}, processes = {}, gpus = {}, cpu_frequency = {},
  sensors = {}, mounts = {}, workloads = {}, quality = {} }
local model_engine = { history_values = function() return {} end }
local softnet_model = ViewModel.build(model_engine, model_snapshot, translator, {}, "network")
  .network_softnet
local softnet_labels = {}
for _, item in ipairs(softnet_model.entries) do softnet_labels[item.label_id] = item.value end
equal(softnet_labels["softnet.backlog"], "2", "Network page shows the live backlog")
equal(softnet_labels["softnet.dropped_rate"], "3/s",
  "Network page labels new softnet drops as a rate")
local network_model = ViewModel.build(model_engine, model_snapshot, translator, {}, "network")
  .network_table
local eth0_row
for _, row in ipairs(network_model.rows) do
  if row.interface == "eth0" then eth0_row = row end
end
equal(eth0_row.link_changes, "+3", "Network table shows transitions since the prior sample")
local link_column
for _, column in ipairs(network_model.columns) do
  if column.key == "link_changes" then link_column = column end
end
assert(link_column, "the new link transition value needs a visible table column")
local portable_columns = ViewModel.build(model_engine, model_snapshot, translator, {},
  "network", nil, nil, { platform = "Windows" }).network_table.columns
for _, column in ipairs(portable_columns) do
  assert(column.key ~= "link_changes",
    "a Linux-only link counter must not consume a Windows table column")
end
for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "fr-FR", "ru-RU",
    "de-DE", "es-ES", "pt-BR", "ja-JP", "ko-KR" }) do
  local label = assert(I18n.new({ locale = locale })):t("network.link_new")
  assert(Width.display_width(label) <= link_column.min_width,
    locale .. " link column label is wider than its readable minimum")
end
local changed_detail = table.concat(TUI.hardware_detail_lines(
  { network = cached.data }, "net:2", translator), "\n")
assert(changed_detail:find("New transitions: 3", 1, true)
    and changed_detail:find("New link down: 2", 1, true),
  "network detail separates lifetime reports from this interval:\n" .. changed_detail)
equal(eth0(cached).queues.rx_count, 2, "queue enumeration is cached across fast samples")
equal(eth0(cached).queues.tx_timeout_total, 4,
  "TX timeouts share the bounded queue refresh interval")
equal(eth0(cached).queues.rx_details[1].rps_cpus, "0003",
  "queue steering data shares the bounded refresh interval")
equal(list_calls, 2, "both interfaces were listed only on the first sample")
now = now + 30000000000
local refreshed = collector:sample(context, cached)
equal(eth0(refreshed).queues.rx_count, 3, "queue topology refreshes after 30 seconds")
equal(eth0(refreshed).queues.tx_timeout_total, 7,
  "TX timeout reports refresh with the queue inventory")
equal(eth0(refreshed).queues.timeout_change.new_reports, 3,
  "adjacent queue scans report new TX timeout events")
equal(eth0(refreshed).queues.timeout_change.interval_seconds, 31,
  "the timeout delta carries the actual scan interval")
equal(eth0(refreshed).queues.tx_timeouts[1].change.new_reports, 3,
  "per-queue deltas identify the queue that reported the events")
equal(eth0(refreshed).queues.rx_details[1].rps_cpus, "0000",
  "RPS settings refresh after 30 seconds")
equal(eth0(refreshed).queues.tx_details[1].rate_limit_enabled, false,
  "a zero TX max rate is an explicitly disabled limit")
equal(list_calls, 4, "refresh lists each interface once")
local refreshed_json = Export.snapshot({ network = refreshed.data }).network.interfaces[2]
equal(refreshed_json.queues.timeout_change.new_reports, 3,
  "timeout deltas reach Snapshot JSON")
local refreshed_detail = table.concat(TUI.hardware_detail_lines(
  { network = refreshed.data }, "net:2", translator), "\n")
assert(refreshed_detail:find("New since previous queue scan: 3", 1, true)
    and refreshed_detail:find("tx-0: +3", 1, true),
  "device detail shows the new timeout reports and their queue")

files["/sys/class/net/eth0/queues/tx-0/tx_timeout"] = "2\n"
files["/sys/class/net/eth0/carrier_changes"] = "2\n"
files["/sys/class/net/eth0/carrier_up_count"] = "1\n"
files["/sys/class/net/eth0/carrier_down_count"] = "1\n"
now = now + 30000000000
local reset = collector:sample(context, refreshed)
equal(eth0(reset).queues.timeout_change.quality, "reset",
  "a lower counter is a reset, not a negative event count")
equal(eth0(reset).queues.tx_timeouts[1].change.quality, "reset",
  "the reset remains visible on its queue")
equal(eth0(reset).link_events.change.quality, "reset",
  "a decreasing carrier counter is a reset, not negative link transitions")

directories["/sys/class/net/eth0/queues"] =
  { "rx-0", "rx-1", "rx-2", "tx-0", "tx-1" }
files["/sys/class/net/eth0/queues/tx-1/tx_timeout"] = "1\n"
now = now + 30000000000
local reshaped = collector:sample(context, reset)
equal(eth0(reshaped).queues.timeout_change.quality, "gap",
  "a changed TX queue set cannot inherit an aggregate timeout baseline")

files["/sys/class/net/eth0/ifindex"] = "9\n"
directories["/sys/class/net/eth0/queues"] = { "rx-0", "tx-0" }
files["/sys/class/net/eth0/queues/tx-0/tx_timeout"] = "7\n"
now = now + 1000000000
local replaced = collector:sample(context, reshaped)
equal(eth0(replaced).queues.rx_count, 1, "ifindex reuse cannot retain old queue topology")
equal(eth0(replaced).queues.timeout_change.quality, "gap",
  "an ifindex change cannot inherit a TX timeout baseline")
equal(eth0(replaced).link_events.change.quality, "gap",
  "an ifindex change cannot inherit another interface's carrier baseline")

directories["/sys/class/net/eth0/queues"] = { "rx-0", "tx-0" }
truncated["/sys/class/net/eth0/queues"] = true
now = now + 30000000000
local cut = collector:sample(context, replaced)
equal(eth0(cut).queues.status, "partial", "truncated directory is not complete")
equal(eth0(cut).queues.config_status, "partial",
  "configuration cannot claim complete coverage when queue enumeration truncates")
equal(eth0(cut).queues.timeout_status, "partial",
  "a truncated queue list cannot have a complete TX timeout total")
equal(eth0(cut).queues.tx_timeout_total, nil,
  "a truncated queue list does not export an invented aggregate")
equal(Export.snapshot({ network = cut.data }).network.interfaces[2].queues.status,
  "partial", "partial queue inventory reaches JSON")

truncated["/sys/class/net/eth0/queues"] = nil
directories["/sys/class/net/eth0/queues"] = "denied"
now = now + 30000000000
local denied = collector:sample(context, cut)
equal(eth0(denied).queues.status, "denied", "permission failure remains explicit")
equal(eth0(denied).queues.rx_count, nil, "unreadable queues are not reported as zero")

directories["/sys/class/net/eth0/queues"] = nil
now = now + 30000000000
local absent = collector:sample(context, denied)
equal(eth0(absent).queues.status, "unavailable", "older kernels may lack queue sysfs")
equal(absent.status, "ok", "optional queue topology does not hide network counters")

directories["/sys/class/net/eth0/queues"] = { "rx-0", "tx-0" }
files["/sys/class/net/eth0/queues/tx-0/tx_timeout"] = "invalid\n"
now = now + 30000000000
local malformed = collector:sample(context, absent)
equal(eth0(malformed).queues.timeout_status, "error",
  "a malformed kernel counter is not interpreted as zero")
equal(eth0(malformed).queues.tx_timeout_total, nil,
  "malformed counters do not create a total")
files["/sys/class/net/eth0/queues/tx-0/tx_timeout"] = { kind = "denied" }
now = now + 30000000000
local refused = collector:sample(context, malformed)
equal(eth0(refused).queues.timeout_status, "denied",
  "a denied timeout counter stays distinct from an empty report")

files["/sys/class/net/eth0/queues/tx-0/tx_timeout"] = nil
now = now + 30000000000
local missing_counter = collector:sample(context, refused)
equal(eth0(missing_counter).queues.timeout_status, "unavailable",
  "an older kernel without tx_timeout does not report zero")
equal(eth0(missing_counter).queues.tx_timeout_total, nil,
  "missing per-queue counters do not produce an aggregate")

files["/sys/class/net/eth0/queues/rx-0/rps_cpus"] = "not-a-mask\n"
now = now + 30000000000
local bad_config = collector:sample(context, missing_counter)
equal(eth0(bad_config).queues.config_status, "partial",
  "malformed steering masks make queue configuration partial")
equal(eth0(bad_config).queues.rx_details[1].issues[1].field, "rps_cpus",
  "the field behind a malformed setting remains identifiable")
equal(Export.snapshot({ network = bad_config.data }).network.interfaces[2]
  .queues.rx_details[1].issues[1].status, "error",
  "a queue configuration issue reaches JSON")
local partial_detail = table.concat(TUI.hardware_detail_lines(
  { network = bad_config.data }, "net:9", translator), "\n")
assert(partial_detail:find("Queue configuration status: Partial", 1, true)
    and partial_detail:find("rx-0/rps_cpus: Error", 1, true)
    and not partial_detail:find("RPS-enabled RX queues:", 1, true),
  "a partial queue configuration names its failed field without claiming totals")
files["/sys/class/net/eth0/queues/rx-0/rps_cpus"] = { kind = "denied" }
now = now + 30000000000
local denied_config = collector:sample(context, bad_config)
equal(eth0(denied_config).queues.rx_details[1].issues[1].status, "denied",
  "denied steering configuration is distinct from a missing optional field")

files["/sys/class/net/eth0/queues/rx-0/rps_cpus"] = nil
files["/sys/class/net/eth0/queues/rx-0/rps_flow_cnt"] = nil
files["/sys/class/net/eth0/queues/tx-0/xps_cpus"] = nil
files["/sys/class/net/eth0/queues/tx-0/xps_rxqs"] = nil
files["/sys/class/net/eth0/queues/tx-0/tx_maxrate"] = nil
now = now + 30000000000
local no_config = collector:sample(context, denied_config)
equal(eth0(no_config).queues.config_status, "unavailable",
  "missing optional queue settings do not masquerade as disabled settings")

local many_tx = { "rx-0" }
for index = 0, 512 do
  many_tx[#many_tx + 1] = "tx-" .. index
  files["/sys/class/net/eth0/queues/tx-" .. index .. "/tx_timeout"] = "0\n"
end
directories["/sys/class/net/eth0/queues"] = many_tx
now = now + 30000000000
local bounded = collector:sample(context, no_config)
equal(eth0(bounded).queues.tx_count, 513, "queue count remains visible past the probe cap")
equal(#eth0(bounded).queues.tx_timeouts, 511,
  "the global read budget includes the loopback TX queue")
equal(eth0(bounded).queues.timeout_status, "partial",
  "unprobed TX queues are not claimed as complete")
equal(eth0(bounded).queues.tx_timeout_total, nil,
  "a bounded timeout scan has no aggregate total")

local balanced_queues = {}
for index = 0, 127 do
  balanced_queues[#balanced_queues + 1] = "rx-" .. index
  balanced_queues[#balanced_queues + 1] = "tx-" .. index
end
directories["/sys/class/net/eth0/queues"] = balanced_queues
now = now + 30000000000
local config_bound = collector:sample(context, bounded)
equal(#eth0(config_bound).queues.rx_details, 128,
  "bounded configuration keeps the receive queue identities")
assert(#eth0(config_bound).queues.tx_details < 128,
  "the global configuration read budget stops before all transmit queues")
equal(eth0(config_bound).queues.config_status, "partial",
  "budgeted configuration scans disclose incomplete coverage")

files["/proc/net/softnet_stat"] = softnet_line(111, 1, 4, 3, 0, 1, 2)
  .. softnet_line(211, 1, 2, 0, 1, 0, 0)
now = now + 1000000000
local softnet_reset = collector:sample(context, config_bound)
equal(softnet_reset.data.softnet.quality, "reset",
  "a decreasing 32-bit softnet counter is not treated as a huge wrap rate")
equal(softnet_reset.data.softnet.dropped_per_second, nil,
  "a reset does not emit a misleading per-second drop count")
equal(softnet_reset.status, "ok", "a softnet reset does not erase interface data")
files["/proc/net/softnet_stat"] = softnet_line(112, 2, 5, 0, 0, 0, 0)
  .. softnet_line(1, 0, 0, 0, 2, 0, 0)
now = now + 1000000000
local cpu_changed = collector:sample(context, softnet_reset)
equal(cpu_changed.data.softnet.quality, "gap",
  "a new CPU cannot inherit a different CPU's softnet baseline")
equal(cpu_changed.data.softnet.reason, "softnet_cpu_set_changed",
  "the gap states why rates are absent")
files["/proc/net/softnet_stat"] = { kind = "missing" }
now = now + 1000000000
local missing_softnet = collector:sample(context, cpu_changed)
equal(missing_softnet.data.softnet.status, "unavailable",
  "an absent optional softnet file has its own status")
equal(missing_softnet.status, "ok",
  "an absent softnet file does not make the network interface collector fail")
local missing_agent = Export.agent({ network = missing_softnet.data }).metrics.network
equal(missing_agent.softnet_status, "unavailable",
  "Agent names the optional source failure without inventing a drop rate")
equal(missing_agent.softnet_dropped_per_second, nil,
  "an unavailable softnet source is not zero traffic")
files["/proc/net/softnet_stat"] = "00000010 00000002 00000001\n"
now = now + 1000000000
local old_layout = collector:sample(context, missing_softnet)
equal(old_layout.data.softnet.dropped, 2, "old layouts retain cumulative counters")
equal(old_layout.data.softnet.backlog_packets, nil,
  "a kernel that did not publish backlog has no invented queue length")
equal(#Export.snapshot({ network = old_layout.data }).network.softnet.per_cpu, 0,
  "old-format rows without CPU ids are not exported as if identified")
now = now + 1000000000
local old_again = collector:sample(context, old_layout)
equal(old_again.data.softnet.quality, "gap",
  "line position on an older kernel is not a durable CPU identity")
files["/proc/net/softnet_stat"] = "not-hex 00000000 00000000\n"
now = now + 1000000000
local bad_softnet = collector:sample(context, old_again)
equal(bad_softnet.data.softnet.status, "error", "malformed softnet data is named")
equal(bad_softnet.status, "ok", "malformed optional data leaves interfaces readable")

files["/sys/class/net/eth0/carrier_changes"] = "5\n"
files["/sys/class/net/eth0/carrier_up_count"] = nil
files["/sys/class/net/eth0/carrier_down_count"] = nil
now = now + 1000000000
local old_carrier = collector:sample(context, bad_softnet)
equal(eth0(old_carrier).link_events.status, "partial",
  "older kernels may publish a total without up/down components")
equal(eth0(old_carrier).link_events.change.new_changes, 3,
  "the readable total still reports link transitions")
equal(eth0(old_carrier).link_events.change.new_down, nil,
  "an absent down counter is unknown, not zero")
files["/sys/class/net/eth0/carrier_changes"] = nil
now = now + 1000000000
local missing_carrier = collector:sample(context, old_carrier)
equal(eth0(missing_carrier).link_events.change.quality, "gap",
  "up/down component values are not summed into a missing total")
equal(missing_carrier.status, "ok",
  "unavailable carrier sysfs does not hide interface throughput")
files["/sys/class/net/eth0/carrier_changes"] = "4\n"
files["/sys/class/net/eth0/carrier_up_count"] = "2\n"
files["/sys/class/net/eth0/carrier_down_count"] = "2\n"
now = now + 1000000000
local carrier_baseline = collector:sample(context, missing_carrier)
files["/sys/class/net/eth0/carrier_changes"] = "7\n"
files["/sys/class/net/eth0/carrier_up_count"] = "4\n"
files["/sys/class/net/eth0/carrier_down_count"] = "4\n"
now = now + 1000000000
local skewed = collector:sample(context, carrier_baseline)
local skewed_link = eth0(skewed).link_events
equal(skewed_link.change.new_changes, 3,
  "the total remains comparable when three separate reads straddle an event")
equal(skewed_link.change.new_up, nil,
  "contradictory up/down deltas are not presented as a complete breakdown")
equal(skewed_link.change.components_quality, "gap",
  "a non-atomic component comparison is explicitly named")
equal(skewed_link.status, "partial",
  "device detail can disclose the partial component reading")

local many_lines = {
  "Inter-| Receive | Transmit", " face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed",
}
for index = 1, 257 do
  many_lines[#many_lines + 1] = string.format(
    "vnic%d: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0", index)
end
local carrier_reads = 0
local many_fs = {}
function many_fs:read(path)
  if path == "/proc/net/dev" then return table.concat(many_lines, "\n") .. "\n" end
  if path:find("/carrier_changes$", 1) or path:find("/carrier_up_count$", 1)
      or path:find("/carrier_down_count$", 1) then
    carrier_reads = carrier_reads + 1
    return "0\n"
  end
  return nil, { kind = "missing", path = path }
end
function many_fs:read_number(path)
  local value = self:read(path)
  return value and tonumber(value) or nil
end
function many_fs:list(path)
  return nil, { kind = "missing", path = path }
end
function many_fs:readlink()
  return nil, { kind = "missing" }
end
local carrier_bound = Network.new({ fs = many_fs }):sample({ fs = many_fs,
  now_ns = function() return now end })
equal(carrier_reads, 768, "carrier sysfs work has a global read budget")
local by_name = {}
for _, row in ipairs(carrier_bound.data.interfaces) do by_name[row.name] = row end
equal(by_name.vnic256.link_events.status, "ok",
  "the last admitted interface is measured")
equal(by_name.vnic257.link_events.status, "truncated",
  "an interface beyond the budget reports missing coverage")

print("ok: network queues, softnet and bounded link transitions")
