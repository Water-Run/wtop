package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local Recording = require("wtop.recording")
local Wire = require("wtop.core.worker_wire")
local Snapshot = require("wtop.model.snapshot")
local CLI = require("wtop.cli")
assert(Recording.crc32("123456789") == 0xcbf43926)
assert(not Recording.open("."), "a directory was accepted as a recording")

local paths = {}
local function temporary(body)
    local path = os.tmpname(); paths[#paths + 1] = path
    local file = assert(io.open(path, "wb")); assert(file:write(body)); assert(file:close())
    return path
end
local function writer(extra)
    local chunks = {}
    local options = { write=function(s) chunks[#chunks + 1] = s; return true end,
        compression=false,
        metadata={ platform="Linux", interval_ms=1000 } }
    for k, v in pairs(extra or {}) do options[k] = v end
    return Recording.writer(options), chunks
end
local function snapshot(number)
    local result = Snapshot.new(number, number * 1000000000)
    result.cpu = { total={ utilization=number }, cores={ [0]={ id=0, utilization=25 } } }
    result.power = { total_power_watts=17.5, zones={ { id="intel-rapl:0", power_watts=17.5,
        constraints={ { name="long_term", power_limit_watts=20 } } } } }
    result.quality.power = { status="ok", quality="fresh", timestamp_ns=result.timestamp_ns,
        value_timestamp_ns=result.timestamp_ns - 100 }
    local socket = { id="tcp:192.0.2.123:443", remote_address="192.0.2.123", remote_port=443,
        family="ipv4", protocol="tcp", remote_endpoint={ address="192.0.2.123", port=443,
            family="ipv4", text="192.0.2.123:443" }, owners={ { pid=12, fd=3 } } }
    result.connections = { connections={ socket }, by_id={ [socket.id]=socket }, by_inode={ [55]=socket } }
    result.collectors.connections = { status="ok", quality="fresh", data=result.connections }
    return result
end

local output, chunks = writer()
local original = snapshot(1)
assert(output:append(original, 1000000010, 1700000000000000000))
assert(output:append(snapshot(2), 2000000010, 1700000001000000000))
output:close(); output:close()
local body = table.concat(chunks)
assert(not body:find("192.0.2.123", 1, true), "remote address leaked through an alias or identity")
assert(original.connections.connections[1].remote_address == "192.0.2.123", "recording mutated live data")
local file = assert(Recording.open(temporary(body)))
assert(file.complete and not file.truncated and file.count == 2)
local first = file:frame(1)
assert(first.timestamp_ns == 1000000010 and first.snapshot.cpu.cores[0].id == 0)
assert(first.snapshot.quality.power.value_timestamp_ns == 999999900)
assert(first.snapshot.power.zones[1].constraints[1].power_limit_watts == 20)
assert(first.snapshot.collectors.connections.data == nil)
assert(first.snapshot.connections.connections[1].remote_endpoint.text == "192.0.2.x:443")
assert(file:frame(2).snapshot.cpu.total.utilization == 2)
file:close(); file:close()
assert(not pcall(file.frame, file, 1))

local unmasked, parts = writer({ include_remote_addresses=true })
unmasked:append(original, 1000000010, 1700000000000000000); unmasked:close()
assert(table.concat(parts):find("192.0.2.123", 1, true))

-- Every cut in the last frame/footer can recover just the preceding complete
-- measurements. It cannot turn an interrupted frame into a valid reading.
local prefix = #chunks[1] + #chunks[2]
for cut = prefix, #body - 1 do
    local path = temporary(body:sub(1, cut))
    local recovered = assert(Recording.open(path))
    assert(recovered.truncated and not recovered.complete)
    assert(recovered.count == (cut >= #body - 12 and 2 or 1))
    assert(recovered:frame(1).snapshot.sequence == 1)
    recovered:close()
    os.remove(path)
end
assert(not Recording.open(temporary("return os.execute('false')")))
assert(not Recording.open(temporary(Recording.MAGIC .. string.pack("<I4I4", 65537, 0))))
local function flip(text, position)
    return text:sub(1, position - 1) .. string.char(text:byte(position) ~ 1) .. text:sub(position + 1)
end
assert(not Recording.open(temporary(flip(body, 20))))
local corrupted = assert(Recording.open(temporary(flip(body, prefix))))
assert(not pcall(corrupted.frame, corrupted, 1), "corrupt frame passed its checksum")
corrupted:close()
assert(not Recording.open(temporary(body .. "extra")))
assert(not Recording.open(temporary(chunks[1] .. string.pack("<I4", Recording.MAX_FRAME_BYTES + 6))))
local invalid, invalid_parts = writer()
local bad = snapshot(1); bad.quality.power.value_timestamp_ns = 9999999999
invalid:append(bad, 1000000010, 1000000010); invalid:close()
local invalid_file = assert(Recording.open(temporary(table.concat(invalid_parts))))
assert(not pcall(invalid_file.frame, invalid_file, 1), "future source timestamp was accepted")
invalid_file:close()

local bounded, bounded_chunks = writer({ max_bytes=#body })
assert(bounded:append(snapshot(1), 1000000010, 1700000000000000000))
assert(bounded:append(snapshot(2), 2000000010, 1700000001000000000))
assert(not bounded:append(snapshot(3), 3000000010, 1700000002000000000))
bounded:close(); assert(#table.concat(bounded_chunks) == #body)
assert(not pcall(bounded.append, bounded, snapshot(4), 4000000010, 4))
local failed = pcall(Recording.writer, { metadata={ platform="Linux", interval_ms=1000 },
    write=function() return nil, "disk full" end })
assert(not failed)
assert(not pcall(Wire.encode, "abc", { max_bytes=7 }))
assert(Wire.decode(Wire.encode({[0]=false}, {max_nodes=3}), {max_nodes=3})[0] == false)
assert(not pcall(Wire.decode, Wire.encode({[0]=false}), {max_nodes=2}))
assert(not pcall(Wire.decode, "t", {max_bytes=0}))

local native = require("wtop.native")
if type(native.recording_compress) == "function" then
    for _, size in ipairs({ 1, 15, 255, 4096, 65536, 1048576 }) do
        local raw = ("abc\0\255\1280123456789\r\n"):rep(math.ceil(size / 19)):sub(1, size)
        local block = native.recording_compress(raw)
        assert(native.recording_decompress(block, #raw) == raw)
        assert(not pcall(native.recording_decompress, block, #raw + 1))
        assert(not pcall(native.recording_decompress, block:sub(1, #block - 1), #raw))
    end
    assert(not pcall(native.recording_decompress, "x", 0))
    assert(not pcall(native.recording_decompress, "x", 67108865))
    assert(not pcall(native.recording_compress, ""))
    for seed = 1, 128 do
        local malformed = (string.char(seed, seed ~ 255)):rep(seed)
        pcall(native.recording_decompress, malformed, 1024)
    end
    local compressed, compressed_parts = writer({ compression=true })
    local large = snapshot(1); large.cpu.notes = ("hardware label with repeated declarations"):rep(10000)
    compressed:append(large, 1000000010, 1700000000000000000); compressed:close()
    local bytes = table.concat(compressed_parts)
    assert(#bytes < 20000)
    local file = assert(Recording.open(temporary(bytes)))
    assert(file:frame(1).snapshot.cpu.notes == large.cpu.notes); file:close()
    print("Recording native LZ4: bounded binary round trips, malformed blocks, independent compressed frames and output limits")
else
    print("Recording native LZ4: native codec not loaded; raw typed-block fallback verified")
end

assert(CLI.parse({"--record", "--count", "3", "--record-limit-mib", "1"}).command == "record")
assert(CLI.parse({"--replay", "sample.wtop"}).replay_path == "sample.wtop")
assert(CLI.parse({"--snapshot", "--replay", "sample.wtop", "--replay-frame", "2"}).command == "snapshot")
assert(CLI.parse({"--record", "--unmask-remote-addresses"}).include_remote_addresses)
for _, args in ipairs({ {"--replay"}, {"--replay", ""}, {"--replay", "a\0b"},
    {"--replay", "sample.wtop", "--count", "1"}, {"--replay", "sample.wtop", "--sudo"},
    {"--record", "--stream"}, {"--record-limit-mib", "1"}, {"--record", "--record-limit-mib", "0"},
    {"--record", "--record-limit-mib", "16385"}, {"--replay", "a", "--stream"},
    {"--replay-frame", "2"}, {"--replay", "a", "--replay-frame", "0"} }) do
    assert(not CLI.parse(args))
end
for _, path in ipairs(paths) do os.remove(path) end
print("Recording: typed full snapshots, exact source times, CRC32, bounded frames/files and interrupted-tail recovery")
print("Recording: remote addresses masked through socket IDs, lookup aliases and collector data; explicit unmask and CLI boundaries")
