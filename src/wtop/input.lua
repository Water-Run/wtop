local Decoder = {}
Decoder.__index = Decoder

local MAX_BUFFER_BYTES = 1024 * 1024
local MAX_SEQUENCE_BYTES = 4096

local CSI_KEYS = {
    A = "up",
    B = "down",
    C = "right",
    D = "left",
    H = "home",
    F = "end",
    Z = "shift_tab",
}

local TILDE_KEYS = {
    [1] = "home",
    [2] = "insert",
    [3] = "delete",
    [4] = "end",
    [5] = "page_up",
    [6] = "page_down",
    [11] = "f1",
    [12] = "f2",
    [13] = "f3",
    [14] = "f4",
    [15] = "f5",
    [17] = "f6",
    [18] = "f7",
    [19] = "f8",
    [20] = "f9",
    [21] = "f10",
    [23] = "f11",
    [24] = "f12",
}

local function key(name, extra)
    extra = extra or {}
    extra.type = "key"
    extra.key = name
    return extra
end

local function decode_plain(byte)
    if byte == 3 then
        return key("c", { ctrl = true })
    elseif byte == 9 then
        return key("tab")
    elseif byte == 13 or byte == 10 then
        return key("enter")
    elseif byte == 12 then
        return key("l", { ctrl = true })
    elseif byte == 32 then
        return key("space")
    elseif byte == 127 or byte == 8 then
        return key("backspace")
    elseif byte >= 33 and byte <= 126 then
        return key(string.char(byte))
    end
    return nil
end

local function decode_modifier(value)
    value = tonumber(value) or 1
    if value % 1 ~= 0 or value < 1 or value > 16 then value = 1 end
    value = value - 1
    return {
        shift = value % 2 == 1,
        alt = math.floor(value / 2) % 2 == 1,
        ctrl = math.floor(value / 4) % 2 == 1,
    }
end

local function decode_csi(sequence)
    local mouse_button, mouse_x, mouse_y, mouse_action = sequence:match("^<(%d+);(%d+);(%d+)([Mm])$")
    if mouse_button then
        mouse_button, mouse_x, mouse_y = tonumber(mouse_button), tonumber(mouse_x), tonumber(mouse_y)
        if not mouse_button or mouse_button > 65535 or not mouse_x or mouse_x < 1
            or mouse_x > 1048576 or not mouse_y or mouse_y < 1 or mouse_y > 1048576 then
            return { type = "unknown", sequence = "\27[" .. sequence }
        end
        return {
            type = "mouse",
            button = mouse_button,
            x = mouse_x,
            y = mouse_y,
            action = mouse_action == "M" and "press" or "release",
        }
    end

    local final = sequence:sub(-1)
    local simple = CSI_KEYS[final]
    if simple then
        local parameters = sequence:sub(1, -2)
        local modifier = parameters:match(";%s*(%d+)$")
        return key(simple, modifier and decode_modifier(modifier) or nil)
    end
    if final == "~" then
        local number, modifier = sequence:match("^(%d+);?(%d*)~$")
        local name = TILDE_KEYS[tonumber(number)]
        if name then
            return key(name, modifier ~= "" and decode_modifier(modifier) or nil)
        end
    end
    return { type = "unknown", sequence = "\27[" .. sequence }
end

function Decoder.new()
    return setmetatable({ buffer = "", paste = false, max_buffer_bytes = MAX_BUFFER_BYTES }, Decoder)
end

function Decoder:feed(data)
    data = data or ""
    if type(data) ~= "string" then error("decoder input must be a string", 2) end
    if #data > self.max_buffer_bytes - #self.buffer then
        self.buffer = ""
        self.paste = false
        return { { type = "error", reason = "input_buffer_limit" } }
    end
    self.buffer = self.buffer .. data
    local events = {}
    local cursor = 1

    while cursor <= #self.buffer do
        local byte = self.buffer:byte(cursor)
        if byte ~= 27 then
            if not self.paste then
                local event = decode_plain(byte)
                if event then
                    events[#events + 1] = event
                end
            end
            cursor = cursor + 1
        elseif self.buffer:sub(cursor, cursor + 1) == "\27[" then
            local final_position = self.buffer:find("[@-~]", cursor + 2)
            if not final_position then
                break
            end
            if final_position - cursor + 1 > MAX_SEQUENCE_BYTES then
                events[#events + 1] = { type = "error", reason = "input_sequence_limit" }
                cursor = final_position + 1
                goto continue
            end
            local sequence = self.buffer:sub(cursor + 2, final_position)
            if sequence == "200~" then
                self.paste = true
            elseif sequence == "201~" then
                self.paste = false
            elseif not self.paste then
                events[#events + 1] = decode_csi(sequence)
            end
            cursor = final_position + 1
        elseif self.buffer:sub(cursor, cursor + 1) == "\27O" then
            if cursor + 2 > #self.buffer then
                break
            end
            local application_key = self.buffer:sub(cursor + 2, cursor + 2)
            local names = { P = "f1", Q = "f2", R = "f3", S = "f4" }
            if not self.paste then
                events[#events + 1] = key(names[application_key] or application_key, { alt = true })
            end
            cursor = cursor + 3
        elseif cursor == #self.buffer then
            break
        else
            local next_byte = self.buffer:byte(cursor + 1)
            local event = decode_plain(next_byte)
            if event and not self.paste then
                event.alt = true
                events[#events + 1] = event
            end
            cursor = cursor + 2
        end
        ::continue::
    end

    self.buffer = self.buffer:sub(cursor)
    return events
end

function Decoder:flush_escape()
    if self.buffer == "\27" then
        self.buffer = ""
        return { key("escape") }
    end
    return {}
end

return Decoder
