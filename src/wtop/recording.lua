-- Versioned local measurement files. Typed data only; no source is evaluated.
local Wire = require("wtop.core.worker_wire")
local Privacy = require("wtop.privacy")
local Snapshot = require("wtop.model.snapshot")
local Quality = require("wtop.model.quality")
local native = require("wtop.native")
local M = { MAGIC = "WTOPREC\0\1", MAX_FRAMES = 1000000, INDEX_STRIDE = 256,
    MAX_FRAME_BYTES = 64 * 1024 * 1024, MAX_FILE_BYTES = 16 * 1024 * 1024 * 1024 }
local LIMITS = { max_bytes = M.MAX_FRAME_BYTES, max_nodes = 4000000, max_depth = 64 }
local Writer, Reader = {}, {}
Writer.__index, Reader.__index = Writer, Reader

local crc_table = {}
for i = 0, 255 do
    local n = i
    for _ = 1, 8 do n = (n >> 1) ~ ((n & 1) ~= 0 and 0xedb88320 or 0) end
    crc_table[i] = n
end
local function crc32(body)
    local n = 0xffffffff
    for i = 1, #body do n = (n >> 8) ~ crc_table[(n ~ body:byte(i)) & 255] end
    return n ~ 0xffffffff
end
M.crc32 = crc32

local function uint(n)
    return math.type(n) == "integer" and n >= 0
end
local function nonnegative_number(n)
    return type(n) == "number" and n == n and n >= 0 and n < math.huge
end
local function copy(t)
    local r = {}; for k, v in pairs(t or {}) do r[k] = v end; return r
end

local function recorded_snapshot(snapshot, timestamp_ns, unmask)
    local result = copy(snapshot)
    result.timestamp_ns = timestamp_ns
    -- Resource slots already contain the installed values. Collector results
    -- repeat them and may retain a different attempt; keep just their metadata.
    result.collectors = {}
    for id, value in pairs(snapshot.collectors or {}) do
        if type(value) == "table" then
            local row = copy(value); row.data = nil; result.collectors[id] = row
        end
    end
    if not unmask and type(snapshot.connections) == "table" then
        local connections = copy(snapshot.connections)
        -- These are lookup aliases of the same socket rows, not extra readings.
        connections.by_id, connections.by_inode = nil, nil
        connections.connections = {}
        for i, value in ipairs(snapshot.connections.connections or {}) do
            local row = copy(value)
            row.remote_address = Privacy.mask_address(row.remote_address)
            if type(value.remote_endpoint) == "table" then
                row.remote_endpoint = copy(value.remote_endpoint)
                row.remote_endpoint.address = Privacy.mask_address(value.remote_endpoint.address)
                row.remote_endpoint.text = Privacy.masked_endpoint_text(value.remote_endpoint)
            end
            row.id = Privacy.masked_connection_id(value)
            connections.connections[i] = row
        end
        result.connections = connections
    end
    return result
end

function M.writer(options)
    options = options or {}
    assert(type(options.write) == "function", "recording output is unavailable")
    local limit = options.max_bytes or 256 * 1024 * 1024
    assert(uint(limit) and limit >= 1024 and limit <= M.MAX_FILE_BYTES, "invalid recording size limit")
    local header = copy(options.metadata)
    assert(({ Linux=true, Darwin=true, Windows=true })[header.platform], "invalid recorded platform")
    assert(uint(header.interval_ms) and header.interval_ms >= 100 and header.interval_ms <= 10000,
        "invalid recorded interval")
    assert(header.privilege == nil or type(header.privilege) == "table", "invalid recorded privilege")
    header.schema = "dev.waterrun.wtop.recording/v1"
    header.encoding = "typed-block/v1"
    header.remote_addresses_unmasked = options.include_remote_addresses == true
    local payload = Wire.encode(header)
    assert(#payload <= 65536, "recording metadata is too large")
    local bytes = M.MAGIC .. string.pack("<I4I4", #payload, crc32(payload)) .. payload
    assert(#bytes + 12 <= limit, "recording limit is too small")
    local ok, why = options.write(bytes)
    assert(ok, "recording write failed: " .. tostring(why))
    return setmetatable({ write = options.write, max_bytes = limit, bytes = #bytes,
        count = 0, unmask = options.include_remote_addresses == true, closed = false,
        compress = options.compression ~= false and native.recording_compress or nil }, Writer)
end

function Writer:append(snapshot, timestamp_ns, wall_ns, capabilities)
    assert(not self.closed, "recording is closed")
    assert(type(snapshot) == "table" and uint(snapshot.sequence) and uint(timestamp_ns)
        and uint(wall_ns), "invalid recording frame")
    assert(not self.last_ns or timestamp_ns > self.last_ns, "recording time did not advance")
    assert(not self.last_sequence or snapshot.sequence >= self.last_sequence, "recording sequence went backwards")
    local retained = recorded_snapshot(snapshot, timestamp_ns, self.unmask)
    retained.recording_capabilities = capabilities
    local raw = Wire.encode(retained, LIMITS)
    local block = self.compress and self.compress(raw)
    local compressed = type(block) == "string" and #block < #raw
    local payload = string.pack("<BI4", compressed and 1 or 0, #raw) .. (compressed and block or raw)
    local times = string.pack("<i8i8", timestamp_ns, wall_ns)
    local frame = string.pack("<I4I4", #payload, crc32(times .. payload)) .. times .. payload
    if self.count == M.MAX_FRAMES or self.bytes + #frame + 12 > self.max_bytes then
        if self.count == 0 then error("a measurement frame exceeds the recording limit", 2) end
        return false, "limit"
    end
    local ok, why = self.write(frame)
    assert(ok, "recording write failed: " .. tostring(why))
    self.count, self.bytes = self.count + 1, self.bytes + #frame
    self.last_ns, self.last_sequence = timestamp_ns, snapshot.sequence
    return true
end

function Writer:close()
    if self.closed then return true end
    self.closed = true
    local ok, why = self.write(string.pack("<I4i8", 0, self.count))
    assert(ok, "recording close failed: " .. tostring(why))
    return true
end

local function exact(file, n)
    local body = file:read(n)
    assert(body and #body == n, "recording is truncated")
    return body
end

local function validate_snapshot(snapshot, timestamp_ns)
    assert(type(snapshot) == "table" and uint(snapshot.sequence)
        and snapshot.timestamp_ns == timestamp_ns, "invalid recorded snapshot")
    assert(snapshot.recording_capabilities == nil or type(snapshot.recording_capabilities) == "table",
        "invalid recorded capabilities")
    -- Raw Snapshot slots are maps/arrays, not executable objects. Defaults also
    -- let recordings omit resources unavailable on their original platform.
    local defaults = Snapshot.new(snapshot.sequence, timestamp_ns)
    for key in pairs(defaults) do
        if type(defaults[key]) == "table" then
            assert(snapshot[key] == nil or type(snapshot[key]) == "table", "invalid recorded resource " .. key)
            if snapshot[key] == nil then snapshot[key] = {} end
        end
    end
    for _, state in pairs(snapshot.quality) do
        assert(type(state) == "table" and Quality.VALID_STATUS[state.status]
            and Quality.VALID_QUALITY[state.quality], "invalid recorded quality")
        for _, key in ipairs({ "timestamp_ns", "value_timestamp_ns", "duration_ns" }) do
            assert(state[key] == nil or (nonnegative_number(state[key]) and
                (key == "duration_ns" or state[key] <= timestamp_ns)), "invalid recorded source time")
        end
    end
    return snapshot
end

function M.open(path)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
        return nil, "invalid recording path"
    end
    if type(native.recording_open) ~= "function" and native.available and type(native.path_type) == "function" then
        local kind = native.path_type(path, true)
        if kind ~= "regular" then return nil, "recording must be a regular file" end
    end
    local file, why
    if type(native.recording_open) == "function" then
        local called
        called, file, why = pcall(native.recording_open, path)
        if not called then return nil, tostring(file) end
    else file, why = io.open(path, "rb") end
    if not file then return nil, why end
    local ok, reader = pcall(function()
        local size = assert(file:seek("end"), "recording must be a seekable file")
        assert(size <= M.MAX_FILE_BYTES, "recording exceeds the file size limit")
        assert(file:seek("set", 0))
        assert(exact(file, #M.MAGIC) == M.MAGIC, "unsupported recording format")
        local length, checksum = string.unpack("<I4I4", exact(file, 8))
        assert(length > 0 and length <= 65536, "invalid recording metadata length")
        local body = exact(file, length)
        assert(crc32(body) == checksum, "recording metadata checksum mismatch")
        local header = Wire.decode(body)
        assert(type(header) == "table" and header.schema == "dev.waterrun.wtop.recording/v1"
            and ({ Linux=true, Darwin=true, Windows=true })[header.platform]
            and header.encoding == "typed-block/v1"
            and uint(header.interval_ms) and header.interval_ms >= 100 and header.interval_ms <= 10000,
            "unsupported recording metadata")
        assert(header.capabilities == nil or type(header.capabilities) == "table", "invalid recording capabilities")
        assert(header.host == nil or type(header.host) == "table", "invalid recorded host")
        assert(header.privilege == nil or type(header.privilege) == "table", "invalid recorded privilege")
        assert(header.version == nil or (type(header.version) == "string" and #header.version <= 128), "invalid recorded version")
        assert(header.revision == nil or (type(header.revision) == "string" and #header.revision <= 256), "invalid recorded revision")
        local self = setmetatable({ file=file, header=header, index={}, count=0,
            size=size, complete=false, truncated=false }, Reader)
        local previous_ns
        while true do
            local offset = assert(file:seek())
            if offset == size then self.truncated = true; break end
            if size - offset < 4 then self.truncated = true; break end
            local n = string.unpack("<I4", exact(file, 4))
            if n == 0 then
                if size - offset < 12 then self.truncated = true; break end
                assert(size - offset == 12, "invalid recording footer")
                assert(string.unpack("<i8", exact(file, 8)) == self.count, "recording frame count mismatch")
                self.complete = true; break
            end
            assert(n <= M.MAX_FRAME_BYTES + 5, "recording frame exceeds the size limit")
            if size - offset < n + 24 then self.truncated = true; break end
            assert(self.count < M.MAX_FRAMES, "recording exceeds the frame count limit")
            local _, at, wall = string.unpack("<I4i8i8", exact(file, 20))
            assert(uint(at) and uint(wall) and (not previous_ns or at > previous_ns), "invalid recording timeline")
            self.count = self.count + 1
            if (self.count - 1) % M.INDEX_STRIDE == 0 then
                self.index[#self.index + 1] = { number=self.count, offset=offset, at_ns=at }
            end
            self.first_ns, self.last_ns = self.first_ns or at, at
            previous_ns = at
            assert(file:seek("cur", n))
        end
        assert(self.count > 0, "recording contains no complete measurements")
        return self
    end)
    if not ok then file:close(); return nil, tostring(reader) end
    return reader
end

function Reader:_locate(number)
    assert(self.file, "recording is closed")
    assert(uint(number) and number >= 1 and number <= self.count, "recorded frame is out of range")
    local index = self.index[(number - 1) // M.INDEX_STRIDE + 1]
    assert(self.file:seek("set", index.offset))
    for _ = index.number, number - 1 do
        local length = string.unpack("<I4", exact(self.file, 4))
        assert(length > 0 and length <= M.MAX_FRAME_BYTES + 5, "recording changed after opening")
        assert(self.file:seek("cur", length + 20))
    end
end

function Reader:timestamp(number)
    self:_locate(number)
    local length, _, at = string.unpack("<I4I4i8", exact(self.file, 16))
    assert(length >= 5 and length <= M.MAX_FRAME_BYTES + 5 and uint(at), "invalid recording frame")
    return at
end

function Reader:frame(number)
    self:_locate(number)
    local length, checksum, at, wall = string.unpack("<I4I4i8i8", exact(self.file, 24))
    assert(length >= 5 and length <= M.MAX_FRAME_BYTES + 5 and uint(at) and uint(wall), "invalid recording frame")
    local body = exact(self.file, length)
    assert(crc32(string.pack("<i8i8", at, wall) .. body) == checksum, "recording frame checksum mismatch")
    local codec, expected = string.unpack("<BI4", body)
    assert(expected > 0 and expected <= M.MAX_FRAME_BYTES, "invalid recording block output size")
    local raw = body:sub(6)
    if codec == 1 then
        assert(type(native.recording_decompress) == "function", "this native module cannot read compressed recordings")
        raw = native.recording_decompress(raw, expected)
    else
        assert(codec == 0, "unsupported recording block codec")
    end
    assert(type(raw) == "string" and #raw == expected, "invalid recording block length")
    return { snapshot=validate_snapshot(Wire.decode(raw, LIMITS), at), timestamp_ns=at, wall_ns=wall }
end

function Reader:close()
    if self.file then self.file:close(); self.file = nil end
end

return M
