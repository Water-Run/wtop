local Engine = require("wtop.engine")
local Snapshot = require("wtop.model.snapshot")
local Recording = require("wtop.recording")
local native = require("wtop.native")
local Replay = {}
Replay.__index = Replay
setmetatable(Replay, { __index=Engine })
local SPEEDS = { 0.25, 0.5, 1, 2, 4 }
local SOURCE = {}
for id, resource in pairs(Snapshot.RESOURCE_IDS) do SOURCE[resource] = id end

function Replay.new(path, options)
    options = options or {}
    local reader, why = Recording.open(path)
    if not reader then error("cannot open recording: " .. tostring(why), 2) end
    local at, wall = 0, 0
    local ok, engine = pcall(function()
        local self = Engine.new({ collectors={}, safe_mode=true, clock={
            now_ns=function() return at end, wall_ns=function() return wall end,
        }, interval_ms=reader.header.interval_ms })
        setmetatable(self, Replay)
        self.replay, self.reader, self.frame_number = true, reader, 0
        self.capabilities = reader.header.capabilities or {}
        self.platform = reader.header.platform
        self.real_now = options.now_ns or native.monotonic_ns
        self.speed_index, self.speed = 3, 1
        self.last_sources = {}
        self._recorded_clock = function(frame) at, wall = frame.timestamp_ns, frame.wall_ns end
        assert(options.frame == nil or (math.type(options.frame) == "integer"
            and options.frame >= 1 and options.frame <= reader.count), "recorded frame is out of range")
        self:seek(options.frame or 1)
        return self
    end)
    if not ok then reader:close(); error(engine, 2) end
    return engine
end

function Replay:probe() return self.capabilities end
function Replay:set_active_tab() return true end
function Replay:has_pending_samples() return false end
function Replay:tick_visible() return self.snapshot, {} end

function Replay:_install(number, frame)
    local completed = {}
    for resource, state in pairs(frame.snapshot.quality or {}) do
        local signature = table.concat({ tostring(state.timestamp_ns), tostring(state.value_timestamp_ns),
            tostring(state.status), tostring(state.quality) }, ":")
        if self.last_sources[resource] ~= signature then
            completed[SOURCE[resource] or resource] = state
            self.last_sources[resource] = signature
        end
    end
    self.snapshot, self.sequence, self.frame_number = frame.snapshot, frame.snapshot.sequence, number
    self.capabilities = frame.snapshot.recording_capabilities or self.reader.header.capabilities or {}
    self._recorded_clock(frame)
    self:_record_history(self.snapshot, completed)
    self.upcoming = number < self.reader.count and { timestamp_ns=self.reader:timestamp(number + 1) } or nil
end

function Replay:seek(number)
    assert(math.type(number) == "integer", "invalid replay frame")
    number = math.max(1, math.min(self.reader.count, number))
    local frame = self.reader:frame(number)
    -- A manual seek starts a new chart segment. It does not connect readings
    -- across unseen time or invent samples for a gap in the recording.
    for _, ring in pairs(self.history) do ring:clear() end
    self.last_sources = {}
    self:_install(number, frame)
    self.paused, self.due_ns = true, nil
    return true
end

function Replay:step(delta) return self:seek(self.frame_number + delta) end

function Replay:_schedule()
    self.due_ns = self.upcoming and self.real_now()
        + math.max(1, math.floor((self.upcoming.timestamp_ns - self.snapshot.timestamp_ns) / self.speed)) or nil
end

function Replay:set_paused(paused)
    self.paused = paused == true or not self.upcoming
    if self.paused then self.due_ns = nil else self:_schedule() end
end

function Replay:cycle_speed()
    self.speed_index = self.speed_index % #SPEEDS + 1
    self.speed = SPEEDS[self.speed_index]
    if not self.paused then self:_schedule() end
    return self.speed
end

function Replay:tick()
    if self.paused or not self.due_ns or self.real_now() < self.due_ns then return self.snapshot, {} end
    -- One measurement per presentation; a slow renderer never skips a peak.
    self:_install(self.frame_number + 1, self.reader:frame(self.frame_number + 1))
    if self.upcoming then self:_schedule() else self:set_paused(true) end
    return self.snapshot, { replay=true }
end

function Replay:next_delay_ms(maximum)
    maximum = maximum or 100
    if self.paused or not self.due_ns then return maximum end
    return math.max(0, math.min(maximum, math.ceil((self.due_ns - self.real_now()) / 1000000)))
end

function Replay:stop()
    Engine.stop(self)
    self.reader:close()
end

return Replay
