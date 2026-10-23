-- Read cached kernel PM attributes, without config-space access or policy writes.
local Common = require("wtop.collectors.common")
local FS = require("wtop.linux.fs")
local M = {}
local RUNTIME = { active=true, suspended=true, suspending=true, resuming=true,
    error=true, unsupported=true }
local PCI = { D0=true, D1=true, D2=true, D3hot=true, D3cold=true, unknown=true, error=true }
local CONTROL = { on=true, auto=true }

local function integer(text, signed)
    if not text:match(signed and "^%-?%d+$" or "^%d+$") then return end
    local number = tonumber(text)
    if math.type(number) ~= "integer" then return end
    if signed and (number < -2147483648 or number > 2147483647) then return end
    return number
end

function M.read(fs, path, context, is_pci, identity_matches)
    local started = Common.now_ns(context)
    local errors, found = {}, false
    local function read(key, relative, parse)
        local raw, failure = fs:read(path .. "/" .. relative, 64)
        if type(raw) ~= "string" then
            local status = FS.error_status(failure)
            -- This attribute returns EIO when the driver does not use autosuspend.
            if key == "autosuspend_delay_ms" and type(failure) == "table"
                and failure.kind == "io_error" and failure.errno == 5 then
                errors[key] = "unavailable"
                return
            end
            if status ~= "unavailable" then errors[key] = status end
            return
        end
        local trimmed = Common.trim(raw)
        local value
        if #raw <= 64 then value = parse(trimmed) end
        if value == nil then errors[key] = "error"
        else found = true end
        return value
    end
    local function runtime() return read("runtime_status", "power/runtime_status",
        function(s) return RUNTIME[s] and s or nil end) end
    local function pci_state() return read("pci_state", "power_state",
        function(s) return PCI[s] and s or nil end) end
    local before = runtime()
    local pci_before = is_pci and pci_state() or nil
    local result = { source=path, capture_started_ns=started }
    result.control = read("control", "power/control", function(s) return CONTROL[s] and s or nil end)
    result.active_time_ms = read("active_time_ms", "power/runtime_active_time", integer)
    result.suspended_time_ms = read("suspended_time_ms", "power/runtime_suspended_time", integer)
    result.autosuspend_delay_ms = read("autosuspend_delay_ms", "power/autosuspend_delay_ms",
        function(s) return integer(s, true) end)
    if is_pci then
        result.d3cold_allowed = read("d3cold_allowed", "d3cold_allowed", function(s)
            if s == "0" then return false elseif s == "1" then return true end
        end)
    end
    result.runtime_status = runtime()
    result.pci_state = is_pci and pci_state() or nil
    result.state_changed = before ~= result.runtime_status or pci_before ~= result.pci_state
    if result.state_changed then errors.capture = "gap" end
    if not found and next(errors) == nil then return nil end
    local same_identity = not identity_matches or identity_matches()
    local finished = Common.now_ns(context)
    if not same_identity then
        return { status="unavailable", source=result.source, errors={identity="gap"},
            capture_started_ns=started, capture_finished_ns=finished }
    end
    result.capture_finished_ns, result.observed_at_ns = finished, finished
    result.errors = errors
    if found then result.status = next(errors) and "partial" or "ok"
    else
        result.status = "error"
        for _, state in pairs(errors) do
            if state == "denied" then result.status = "denied" end
        end
    end
    return result
end

return M
