local M = {}
function M.quality(snapshot, device)
    local state = snapshot.quality and snapshot.quality.wifi
    if not state then return "unavailable" end
    if state.status ~= "ok" then
        if state.quality == "fresh" or state.quality == "partial" or state.quality == nil then
            return state.status == "denied" and "denied" or state.status == "error" and "error" or "unavailable"
        end
        return state.quality
    end
    if state.quality ~= "fresh" and state.quality ~= "partial" then return state.quality or "unknown" end
    if device.quality ~= "fresh" and device.quality ~= "partial" then return device.quality or "unknown" end
    local now, observed = snapshot.timestamp_ns, device.observed_at_ns
    local function finite(value) return type(value) == "number" and value == value and value >= 0 and value < math.huge end
    if not finite(now) or not finite(observed) or observed > now then return "unknown" end
    if now - observed > 15000000000 then return "stale" end
    return device.quality
end
return M
