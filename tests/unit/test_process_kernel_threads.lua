package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local Process = require("wtop.collectors.process")
local Parsers = require("wtop.linux.parsers")
local Native = require("wtop.native")

local file = assert(io.open("tests/fixtures/proc/100.stat.1", "rb"))
local original = file:read("*a");file:close()
local prefix, suffix = original:match("^(100 %b())%s+(.+)$")
local fields = {};for value in suffix:gmatch("%S+") do fields[#fields+1] = value end
local function stat(flags, start)
    local copy = {};for i,v in ipairs(fields) do copy[i] = v end
    copy[7], copy[20] = tostring(flags), tostring(start or 1000)
    return prefix .. " " .. table.concat(copy, " ") .. "\n"
end
assert(Parsers.process_stat(stat(0x200000)).flags == 0x200000)
assert(Parsers.process_stat(stat(0, 2000)).starttime_ticks == 2000)

for _, provider in ipairs({ Native, { available = false }, {
    available = true, process_stat_fields = function(content) return Parsers.process_stat(content) end,
} }) do
    local now, flags, start = 1e9, 0x200000, 1000
    local command, reads, stat_reads = "", 0, 0
    local uid, present, change_after_status, change_after_command = 0, true, false, false
    local status_reads = 0
    local fs = { list = function() return present and { "100" } or {} end }
    function fs:read(path)
        if path == "/proc/uptime" then return "100.0 0.0\n" end
        if path == "/proc/100/stat" then stat_reads=stat_reads+1;return stat(flags,start) end
        if path == "/proc/100/cmdline" then
            reads=reads+1
            if change_after_command then flags=0x200000 end
            return command
        end
        if path == "/proc/100/status" then
            status_reads = status_reads + 1
            if change_after_status then flags=0 end
            return "Uid:\t" .. uid .. "\t0\t0\t0\nVmRSS:\t8192 kB\n"
        end
        return nil, { kind = "missing" }
    end
    local collector = Process.new({ fs=fs, native=provider, read_cmdline=true,
        clock_ticks_per_second=100, page_size_bytes=4096 })
    local previous
    local function sample(detail)
        local context = { fs=fs, now_ns=function() return now end }
        if detail then context.selected_process_ids={ ["100:" .. start]=true } end
        previous=collector:sample(context, previous);now=now+1e9
        return previous.data.by_id["100:" .. start]
    end
    for index=1,6 do
        local row=assert(sample())
        assert(row.command==nil and row.kernel_thread==nil)
        assert(row.name=="worker" and row.resident_bytes==(index==1 and 8388608 or 2097152))
    end
    assert(reads==0, "kernel-thread polling performed command-line I/O")
    assert(stat_reads==6+status_reads, "each periodic or initial status read requires a full identity readback")
    assert(sample(true).command==nil and reads==1, "explicit details did not query cmdline")
    assert(sample().command==nil and reads==1)

    -- A kernel worker can exec into user space without changing pid/start.
    -- Its previous no-command cache must not hide new argv or credentials.
    flags, command, uid = 0, "new\0worker\0", 1001
    local user=assert(sample())
    assert(user.command=="new worker" and user.uid==1001 and reads==2)
    assert(sample().command=="new worker")
    command="changed\0argv\0"
    assert(sample().command=="changed argv" and reads==3,
        "ordinary argv updates stopped refreshing")

    flags, command = 0x200000, ""
    assert(sample().command==nil and reads==3, "old user argv crossed a role change")
    present=false;sample();assert(next(collector.identity_cache)==nil)
    present=true;assert(sample().command==nil and reads==3)
    flags, command, start = 0, "reused\0", 2000
    assert(sample().command=="reused" and reads==4)

    -- Changing the role during a supplemental read must discard mixed data,
    -- even if pid and starttime still match the initial stat record.
    flags, start, change_after_status = 0x200000, 3000, true
    assert(sample()==nil and previous.data.races==1)
    assert(next(collector.identity_cache)==nil)
    change_after_status=false;flags=0;start=4000;change_after_command=true
    assert(sample()==nil and previous.data.races==1)
end

-- A missing flag from an older/custom parser provides no kernel-thread proof.
do
    local reads=0
    local fs={ list=function() return { "100" } end, read=function(_,path)
        if path=="/proc/100/stat" then return stat(0x200000) end
        if path=="/proc/100/cmdline" then reads=reads+1;return "ordinary\0" end
        if path=="/proc/uptime" then return "100.0 0.0\n" end
        return nil,{kind="missing"}
    end }
    local provider={ available=true, process_stat_fields=function(content)
        local parsed=assert(Parsers.process_stat(content));parsed.flags=nil;return parsed
    end }
    local c=Process.new({ fs=fs,native=provider,read_status=false,read_cmdline=true })
    local r=c:sample({ fs=fs,now_ns=function()return 1e9 end })
    assert(r.data.list[1].command=="ordinary" and reads==1)
end
print("ok: kernel-thread cmdline I/O, selected details, user argv freshness, role/identity changes and parser fallback")
