local RuntimePM = require("wtop.model.runtime_pm")
local Technical = require("wtop.i18n.technical")
local M = {}

local function text(i18n, key, fallback)
    local value = i18n and i18n:t(key)
    return value and value ~= key and value or fallback
end

function M.append(raw, source_quality, now_ns, add, lines, i18n)
    local row = RuntimePM.public(raw, source_quality, now_ns)
    if not row then return end
    lines[#lines + 1] = ""
    lines[#lines + 1] = text(i18n, "runtime_pm.title", "Device power management")
    add("runtime_pm.quality", "Observation quality", Technical.state(i18n, row.quality))
    if row.runtime_status then
        add("runtime_pm.status", "Runtime PM state",
            text(i18n, "runtime_pm.state." .. row.runtime_status, row.runtime_status))
    end
    if row.pci_state then add("runtime_pm.pci_state", "Kernel PCI power state", row.pci_state) end
    if row.control then
        add("runtime_pm.control", "Runtime PM policy",
            text(i18n, "runtime_pm.control." .. row.control, row.control))
    end
    local function ms(value)
        if type(value) ~= "number" then return nil end
        return (i18n and i18n.format:number(value, {precision=0}) or tostring(value)) .. " ms"
    end
    add("runtime_pm.active_time", "Reported active time", ms(row.active_time_ms))
    add("runtime_pm.suspended_time", "Reported suspended time", ms(row.suspended_time_ms))
    if row.autosuspend_delay_ms ~= nil then
        add("runtime_pm.autosuspend", "Configured autosuspend delay", row.autosuspend_delay_ms < 0
            and text(i18n, "runtime_pm.autosuspend_disabled", "Autosuspend disabled") .. " ("
                .. tostring(row.autosuspend_delay_ms) .. ")" or ms(row.autosuspend_delay_ms))
    end
    if row.d3cold_allowed ~= nil then
        add("runtime_pm.d3cold", "D3cold allowed by policy", row.d3cold_allowed)
    end
    if row.age_ms ~= nil then add("runtime_pm.age", "Sample age", ms(row.age_ms)) end
    if row.state_changed then
        lines[#lines + 1] = text(i18n, "runtime_pm.changed", "Power state changed during this read")
    end
    local labels = {
        runtime_status={"runtime_pm.status","Runtime PM state"}, pci_state={"runtime_pm.pci_state","Kernel PCI power state"},
        control={"runtime_pm.control","Runtime PM policy"}, active_time_ms={"runtime_pm.active_time","Reported active time"},
        suspended_time_ms={"runtime_pm.suspended_time","Reported suspended time"},
        autosuspend_delay_ms={"runtime_pm.autosuspend","Configured autosuspend delay"},
        d3cold_allowed={"runtime_pm.d3cold","D3cold allowed by policy"},
        capture={"runtime_pm.quality","Observation quality"}, identity={"runtime_pm.identity","Device identity check"},
    }
    local keys = {};for key in pairs(row.errors) do keys[#keys + 1] = key end;table.sort(keys)
    for _, key in ipairs(keys) do
        local label = labels[key]
        add(label[1], label[2], Technical.state(i18n, row.errors[key]))
    end
    add("metrics.source", "Source", row.source)
    lines[#lines + 1] = text(i18n, "runtime_pm.note",
        "Kernel reports and policy; runtime suspend is not a PCI state or a power reading. Timers are cumulative accounting.")
end

return M
