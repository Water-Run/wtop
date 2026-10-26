package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local Process = require("wtop.collectors.process")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")
local file = assert(io.open("tests/fixtures/proc/100.stat.1", "rb"))
local original = file:read("*a"); file:close()

-- Text remains safe for a terminal, including every single-byte input and
-- strings that must take UTF-8 repair rather than the ordinary ASCII path.
assert(Process.sanitize_text(false) == nil)
assert(Process.sanitize_text("  plain task  ") == "plain task")
assert(Process.sanitize_text(" 你好🙂 ") == "你好🙂")
assert(Process.sanitize_text("a\0\0b\tc\nd") == "a b c?d")
assert(Process.sanitize_text("a\240\159b") == "a��b")
for byte = 0, 255 do
  local input = string.char(byte)
  local expected = (byte == 0 or byte == 9) and " "
    or (byte < 32 or byte == 127) and "?"
    or byte > 127 and "�" or input
  assert(Process.sanitize_text("a" .. input .. "b") == "a" .. expected .. "b",
    "unexpected process text byte: " .. byte)
end

-- Direct metadata decoding is optional. A decline keeps the existing parser's
-- partial/error semantics, and supplemental identity checks still fence it.
do
 local Native=require("wtop.native")
 local decode=Native.process_status_metadata_fields or Parsers.process_status
 local direct_calls,reduced_calls,start,race=0,0,1000,false
 local content="Uid:\t1000\t1000\t1000\t1000\nNSpid:\t100\t1\nCpus_allowed_list:\t0-1\nMems_allowed_list:\t0\n"
 local provider={available=true,process_status_metadata_fields=function(value)
  direct_calls=direct_calls+1;return decode(value)
 end,process_status_metadata_input=function(value)reduced_calls=reduced_calls+1;return value end}
 local fs={list=function()return{"100"}end}
 function fs:read(path)
  if path=="/proc/uptime"then return"100 0\n"end
  if path=="/proc/100/stat"then return(original:gsub(" 1000 10485760 "," "..start.." 10485760 "))end
  if path=="/proc/100/status"then if race then start=2000 end;return content end
  return nil,{kind="missing"}
 end
 local function sample()
  return Process.new({fs=fs,native=provider,clock_ticks_per_second=100,page_size_bytes=4096})
   :sample({fs=fs,now_ns=function()return 1e9 end})
 end
 local first=sample();local row=assert(first.data.by_pid[100])
 assert(direct_calls==1 and reduced_calls==0)
 assert(row.uid==1000 and row.namespaces.inner_pid==1 and row.affinity.cpus_allowed_count==2)
 provider.process_status_metadata_fields=function()direct_calls=direct_calls+1;return nil end
 content="Uid:\t2000\t2000\t2000\t2000\nCpus_allowed_list:\t1,0\n"
 local second=sample();assert(second.data.by_pid[100].uid==2000)
 assert(second.data.by_pid[100].affinity.status=="partial" and reduced_calls==1)
 content="Uid: 1 1 1 1\nUid: 2 2 2 2\n"
 local malformed=sample();assert(malformed.data.supplemental_parse_errors==1)
 assert(malformed.data.by_pid[100].uid==nil and malformed.data.by_pid[100].partial)
 content="Uid: 3000 3000 3000 3000\n";race=true
 local replaced=sample();assert(#replaced.data.list==0 and replaced.data.races==1)
 assert(first.data.by_pid[100].uid==1000 and first.data.by_pid[100].affinity.cpus_allowed_count==2)
end

local function stat(pid)
  return original:gsub("^100 ", tostring(pid) .. " ")
end

-- A successful command survives repeated cache reuse. Explicit detail refreshes
-- still replace it, clear an empty result, retry failures, and fence PID reuse.
do
  local Native = require("wtop.native")
  for _, provider in ipairs({ { available = false }, Native }) do
    local now, reads, generation = 1e9, 0, 1000
    local command, denied, race = "first\0argument\0", false, false
    local comm = "worker"
    local fs = { list = function() return { "100" } end }
    function fs:read(path)
      if path == "/proc/uptime" then return "100 0\n" end
      if path == "/proc/100/stat" then
        local body = original:gsub("%b()", "(" .. comm .. ")", 1)
        local fields = {}; for token in body:gmatch("%S+") do fields[#fields + 1] = token end
        -- The fixture's comm has no spaces; field 22 is the start time.
        fields[22] = tostring(generation)
        return table.concat(fields, " ")
      end
      if path == "/proc/100/cmdline" then
        reads = reads + 1
        if race then generation = generation + 1; race = false end
        if denied then return nil, { kind = "denied" } end
        return command
      end
      return nil, { kind = "missing" }
    end
    local c = Process.new({ fs = fs, native = provider, read_status = false,
      read_cmdline = true })
    local previous
    local function sample(detail)
      now = now + 100000000
      local context = { fs = fs, now_ns = function() return now end }
      if detail then context.selected_process_ids = { ["100:" .. generation] = true } end
      previous = c:sample(context, previous)
      return previous.data.by_pid[100]
    end
    local first = assert(sample()); assert(first.command == "first argument")
    for _ = 1, 8 do assert(sample().command == first.command) end
    assert(reads == 1, "cached command was periodically re-read")
    command = "replacement\0"; assert(sample(true).command == "replacement")
    command = ""; assert(sample(true).command == nil)
    local empty_reads = reads
    for _ = 1, 4 do assert(sample().command == nil) end
    assert(reads == empty_reads, "known empty command was re-read")
    denied = true; local failed = sample(true)
    assert(failed.command_status == "denied")
    denied, command = false, "recovered\0"; assert(sample().command == "recovered")
    local recovered_reads = reads
    for _ = 1, 4 do assert(sample().command == "recovered") end
    assert(reads == recovered_reads, "retried command was not retained")
    command, now = "rewritten argv\0", now + 6e9
    assert(sample().command == "rewritten argv", "command cache did not expire")
    comm, command = "renamed", "same PID exec\0"
    assert(sample().command == "same PID exec", "changed process name kept old arguments")
    command, now = "clock reversed\0", now - 1e9
    assert(sample().command == "clock reversed", "clock reversal kept an invalid deadline")
    generation, command = generation + 1, "new PID\0"
    assert(sample().command == "new PID", "reused PID inherited the old command")
    race, command = true, "raced\0"; assert(sample(true) == nil)
    assert(previous.data.races == 1 and next(c.identity_cache) == nil)
    command = "after race\0"; assert(sample().command == "after race")
    assert(first.command == "first argument", "cache refresh changed an older snapshot")
  end
end

-- Enumeration order, noncanonical PIDs, limits and a disappearing PID must
-- not change native batch alignment or the public numeric PID ordering.
local entries = { "300", "bad", "030", "200", "3", "0", "-1", "2147483648", "100" }
local batches, reads = {}, {}
local throw_batch, empty_batch, denied_batch, parsed = false, false, false, false
local function read(_, path)
  reads[path] = (reads[path] or 0) + 1
  if path == "/proc/uptime" then return "100 0\n" end
  local pid = path:match("^/proc/(%d+)/stat$")
  if pid and pid ~= "100" then return stat(tonumber(pid)) end
  return nil, { kind = "missing" }
end
local provider = { available = true }
function provider.proc_batch(pids, mode)
  local copy = {}; for i, pid in ipairs(pids) do copy[i] = pid end
  batches[#batches + 1] = { pids = copy, mode = mode }
  if throw_batch then error("batch unavailable") end
  if empty_batch then return nil end
  local contents, denied = {}, {}
  for i, pid in ipairs(pids) do
    contents[i] = mode == "io" and "read_bytes: 10\nwrite_bytes: 20\n"
      or pid ~= 100 and (parsed and assert(Parsers.process_stat(stat(pid))) or stat(pid))
      or false
    if pid == 100 and denied_batch then denied[i] = true end
  end
  return contents, denied
end

local prior_list, prior_read = FS.default.list, FS.default.read
local ok, failure = xpcall(function()
  FS.default.list = function(_, path, limit)
    assert(path == "/proc" and limit >= 256)
    return entries
  end
  FS.default.read = read
  for _, max in ipairs({ 1, 3, 8 }) do
    for _, use_parsed in ipairs({ false, true }) do
      parsed = use_parsed
      provider.process_stat_fields = use_parsed and Parsers.process_stat or nil
      batches, reads = {}, {}
      local c = Process.new({ native = provider, max_processes = max,
        max_bulk_io_reads = 2, read_status = false })
      local r = c:sample({ now_ns = function() return 1e9 end, scan_process_io = true })
      assert(r.data.process_candidates == 4 and r.data.scanned == math.min(max, 4))
      assert(r.data.truncated == (max < 4))
      assert(#batches == 2 and batches[1].mode == "io")
      assert(#batches[1].pids == math.min(max, 2))
      assert(batches[2].mode == (use_parsed and "stat_parsed" or "stat"))
      local wanted = { 3, 100, 200, 300 }
      -- There are four canonical entries; 030 is not a second spelling of 30.
      assert(#batches[2].pids == math.min(max, #wanted))
      for i, pid in ipairs(batches[2].pids) do assert(pid == wanted[i]) end
      local last = 0
      for _, row in ipairs(r.data.list) do
        assert(row.pid > last and row.pid ~= 100)
        assert(r.data.by_id[row.id] == row and r.data.by_pid[row.pid] == row)
        last = row.pid
      end
    end
  end

  for _, kind in ipairs({ "throw", "empty", "denied" }) do
    throw_batch, empty_batch, denied_batch = kind == "throw", kind == "empty", kind == "denied"
    local c = Process.new({ native = provider, read_status = false })
    local r = c:sample({ now_ns = function() return 1e9 end })
    assert(#r.data.list == 3 and r.data.scanned == 4)
    assert(r.data.denied == (denied_batch and 1 or 0))
    assert(r.data.races == (denied_batch and 0 or 1))
  end
  throw_batch, empty_batch, denied_batch = false, false, false
  batches = {}
  local injected = { list = FS.default.list, read = read }
  local c = Process.new({ native = provider, read_status = false })
  assert(#c:sample({ fs = injected, now_ns = function() return 1e9 end }).data.list == 3)
  assert(#batches == 0, "context filesystem was sent to real-proc batch reader")

  -- A duplicate just beyond the scan cap still prevents reuse of a private
  -- cache record that belongs to the previous sample.
  entries = { "3" }
  c = Process.new({ native = provider, read_status = false, max_processes = 1 })
  local first = c:sample({ now_ns = function() return 1e9 end })
  local cached = c.identity_cache[first.data.list[1].id]
  entries = { "3", "3" }
  local second = c:sample({ now_ns = function() return 2e9 end }, first)
  assert(second.data.truncated and #second.data.list == 1)
  assert(c.identity_cache[second.data.list[1].id] ~= cached)

  -- All native batch forms must pass the same final identity fence. The
  -- batch provides the first stat; only the read after schedstat can detect
  -- replacement between those two lookups.
  do
    local real = require("wtop.native")
    local saved_list, saved_read = FS.default.list, FS.default.read
    for _, mode in ipairs({ "stat", "stat_parsed", "stat_rows" }) do
      if mode ~= "stat_rows" or type(real.process_stat_row_fields) == "function" then
        local replaced, at, stat_reads = false, 1000000000, 0
        local native_provider = { available = true }
        if mode ~= "stat" then native_provider.process_stat_fields = Parsers.process_stat end
        if mode == "stat_rows" then
          native_provider.process_stat_row_fields = real.process_stat_row_fields
        end
        function native_provider.proc_batch(pids, requested)
          assert(#pids == 1 and pids[1] == 100 and requested == mode)
          local value = mode == "stat" and original
            or mode == "stat_rows" and assert(real.process_stat_row_fields(original))
            or assert(Parsers.process_stat(original))
          return { value }, {}
        end
        FS.default.list = function() return { "100" } end
        FS.default.read = function(_, path)
          if path == "/proc/uptime" then return "100 0\n" end
          if path == "/proc/100/schedstat" then return "1000000000 200000000 10\n" end
          if path == "/proc/100/stat" then
            stat_reads = stat_reads + 1
            return replaced and original:gsub(" 1000 10485760 ", " 2000 10485760 ") or original
          end
          return nil, { kind = "missing" }
        end
        local scanner = Process.new({ native = native_provider, read_status = false,
          clock_ticks_per_second = 100, page_size_bytes = 4096 })
        local scan_context = { now_ns = function() return at end,
          visible_process_ids = { ["100:1000"] = true } }
        local valid = scanner:sample(scan_context)
        assert(valid.data.by_id["100:1000"].scheduler.wait_ns == 200000000)
        local memo = scanner.sched_memo["pid /proc/100"]
        replaced, at = true, 2000000000
        local invalid = scanner:sample(scan_context, valid)
        assert(#invalid.data.list == 0 and invalid.data.races == 1, mode)
        assert(scanner.sched_memo["pid /proc/100"] == memo and stat_reads == 2,
          "native batch scheduler must commit only identity-checked readings: " .. mode)
      end
    end
    FS.default.list, FS.default.read = saved_list, saved_read
  end

  -- The native row path and the older parsed-stat path must publish the same
  -- complete result, including unusual names, counters and rejected races.
  local real_native = require("wtop.native")
  if type(real_native.process_stat_row_fields) == "function" then
    local function copy(value)
      if type(value) ~= "table" then return value end
      local result = {}; for key, field in pairs(value) do result[key] = copy(field) end
      return result
    end
    local function same(left, right)
      if type(left) ~= type(right) then return false end
      if type(left) ~= "table" then return left == right end
      for key, value in pairs(left) do if not same(value, right[key]) then return false end end
      for key in pairs(right) do if left[key] == nil then return false end end
      return true
    end
    local tokens = {}
    for token in original:match("^100 %b()%s+(.+)$"):gmatch("%S+") do
      tokens[#tokens + 1] = token
    end
    local function body(name, rss, flags, start)
      local copy = {}; for i, value in ipairs(tokens) do copy[i] = value end
      copy[7], copy[20], copy[22] = tostring(flags), tostring(start), tostring(rss)
      return "3 (" .. name .. ") " .. table.concat(copy, " ")
    end
    local function collect(use_rows, initial, final)
      local observed_mode
      local p = { available = true, process_stat_fields = real_native.process_stat_fields,
        process_stat_row_fields = use_rows and real_native.process_stat_row_fields or nil }
      function p.proc_batch(pids, mode)
        assert(#pids == 1 and pids[1] == 3)
        observed_mode = mode
        local parse = use_rows and real_native.process_stat_row_fields or real_native.process_stat_fields
        return { parse(initial) or initial }, {}
      end
      FS.default.read = function(_, path)
        if path == "/proc/uptime" then return "100 0\n" end
        if path == "/proc/3/stat" then return final or initial end
        if path == "/proc/3/cmdline" then return "program\0argument\0" end
        return nil, { kind = "missing" }
      end
      entries = { "3" }
      local collector = Process.new({ native = p, read_status = false, read_cmdline = true,
        clock_ticks_per_second = 100, page_size_bytes = 4096 })
      local result = collector:sample({ now_ns = function() return 1e9 end })
      assert(observed_mode == (use_rows and "stat_rows" or "stat_parsed"))
      local saved = copy(result)
      collector:sample({ now_ns = function() return 2e9 end }, result)
      assert(same(result, saved), "native row reuse mutated an old snapshot")
      return result
    end
    for _, case in ipairs({
      { body("plain", 512, 0, 1000) },
      { body("name ) 你好\255", -1, 0, 1000) },
      { body("large RSS", math.maxinteger, 0, 1000) },
      { body("kernel worker", 512, 0x200000, 1000) },
      { body("reused", 512, 0, 1000), body("new", 512, 0, 2000) },
      { body("changed role", 512, 0, 1000), body("kernel", 512, 0x200000, 1000) },
      { body("malformed final", 512, 0, 1000), "invalid" },
      { "invalid initial" },
    }) do
      local old = collect(false, table.unpack(case))
      local current = collect(true, table.unpack(case))
      assert(same(current, old), "native row changed the public process sample")
    end
  end
end, debug.traceback)
FS.default.list, FS.default.read = prior_list, prior_read
assert(ok, failure)
print("ok: process text bytes, PID ordering, scan and I/O caps, batch failures, fallback and duplicate boundary")

-- Credential and affinity metadata must refresh without requiring details.
do
  local Native=require("wtop.native")
  for _,provider in ipairs({{available=false},Native}) do
    local f=assert(io.open('tests/fixtures/proc/100.stat.1','rb'));local body=f:read('*a');f:close()
    local uid,mask,now,status_reads,stat_reads=1000,'0-1',1e9,0,0
    local start,denied,race=1000,false,false
    local fs={list=function()return{'100'}end}
    function fs:read(path)
     if path=='/proc/uptime'then return'100 0\n'end
     if path=='/proc/100/stat'then stat_reads=stat_reads+1;return body:gsub(' 1000 10485760 ',' '..start..' 10485760 ')end
     if path=='/proc/100/status'then
      status_reads=status_reads+1
      if race then start=2000 end
      if denied then return nil,{kind='denied'}end
      return ('Uid:\t%d\t%d\t%d\t%d\nCpus_allowed_list:\t%s\nNSpid:\t100\n'):format(uid,uid,uid,uid,mask)
     end
     return nil,{kind='missing'}
    end
    local c=Process.new({fs=fs,native=provider,clock_ticks_per_second=100,page_size_bytes=4096})
    local previous
    local function sample(detail,resolver)
     local ctx={fs=fs,now_ns=function()return now end,resolve_username=resolver}
     if detail then ctx.selected_process_ids={['100:'..start]=true}end
     previous=c:sample(ctx,previous)
     return previous.data.by_id['100:'..start]
    end
    local first=assert(sample(false,function(v)return'user'..v end));assert(first.uid==1000 and first.user=='user1000'and status_reads==1 and stat_reads==2)
    uid,mask=2000,'2-3';now=now+1000000
    assert(sample().uid==1000 and status_reads==1,'ordinary sub-period sample reread status')
    now=now+5e9;local changed=assert(sample());assert(changed.uid==2000 and changed.user==nil and changed.affinity.cpus_allowed_list=='2-3')
    assert(first.uid==1000 and first.user=='user1000'and first.affinity.cpus_allowed_list=='0-1','old snapshot mutated')
    assert(stat_reads==5,'periodic status refresh lost complete final-stat readback')
    now=now+6e9;denied=true;local missing=assert(sample());assert(missing.uid==nil and missing.user==nil and missing.affinity==nil and missing.namespaces==nil and missing.partial_reason=='status_denied')
    local n=status_reads;now=now+1e6;sample();assert(status_reads==n,'failed refresh retried on every tick')
    now=1;denied=false;uid=3000;assert(sample().uid==3000 and status_reads==n+1,'clock reversal retained old metadata')
    now=now+1e6;uid=4000;assert(sample(true).uid==4000,'selected details did not override refresh cadence')
    local cache=c.identity_cache['100:1000'];local saved_uid=cache.uid;now=now+6e9;race=true
    assert(sample()==nil and previous.data.races==1 and next(c.identity_cache)==nil)
    assert(cache.uid==saved_uid,'failed identity validation mutated the prior cache')
    race=false;start=1000;local off=Process.new({fs=fs,native={available=false},read_status=false});local n=status_reads
    off:sample({fs=fs,now_ns=function()return now end});assert(status_reads==n)
  end
end

-- Stable phases distribute this sequential thousand-identity fixture.
do
  local f=assert(io.open('tests/fixtures/proc/100.stat.1','rb'));local body=f:read('*a');f:close()
  local entries,bodies={},{}
  for pid=1,1000 do entries[pid]=tostring(pid);bodies[pid]=body:gsub('^100 ',pid..' ')end
  local uid,reads,now=1000,0,1e9
  local fs={list=function()return entries end}
  function fs:read(path)
   if path=='/proc/uptime'then return'100 0\n'end
   local pid=tonumber(path:match('^/proc/(%d+)/stat$'));if pid then return bodies[pid]end
   pid=tonumber(path:match('^/proc/(%d+)/status$'))
   if pid then reads=reads+1;return('Uid:\t%d\t%d\t%d\t%d\nCpus_allowed_list:\t0-1\nNSpid:\t%d\n'):format(uid,uid,uid,uid,pid)end
   return nil,{kind='missing'}
  end
  local c=Process.new({fs=fs,native={available=false},clock_ticks_per_second=100,page_size_bytes=4096})
  local previous=c:sample({fs=fs,now_ns=function()return now end});assert(reads==1000 and #previous.data.list==1000)
  uid=2000;local counts={}
  for step=1,10 do
   reads=0;now=now+1e9;previous=c:sample({fs=fs,now_ns=function()return now end},previous)
   counts[step]=reads;assert(reads<=300,'too many metadata refreshes in one tick')
   if step>=5 then for _,row in ipairs(previous.data.list)do assert(row.uid==2000)end end
  end
end

print("ok: periodic process metadata, old-module fallback, immutable snapshots, denied/backoff, clock reversal, full identity readback and thousand-identity phases")

-- A scan shares resolved names by UID, without extending the database TTL.
do
 local Native=require("wtop.native")
local f=assert(io.open("tests/fixtures/proc/100.stat.1","rb"));local body=f:read("a");assert(f:close())
for _,native in ipairs({{available=false},Native})do
 local now,calls,step=1e9,{},1
 local fs={list=function()return{"4","04","3","2","1"}end}
 function fs:read(path)
  if path=="/proc/uptime"then return"100 0\n"end
  local pid=tonumber(path:match("/proc/(%d+)/stat$"));if pid then return(body:gsub("^100 ",pid.." "))end
  pid=tonumber(path:match("/proc/(%d+)/status$"))
  if pid then local uid=pid<=2 and 1000 or 2000;return("Uid:\t%d\t%d\t%d\t%d\n"):format(uid,uid,uid,uid)end
  return nil,{kind="missing"}
 end
 local collector=Process.new({fs=fs,native=native,clock_ticks_per_second=100,page_size_bytes=4096})
 local function resolve(uid)
  calls[uid]=(calls[uid]or 0)+1
  if step==1 then return uid==1000 and"  Alice\t "or nil end
  if step==2 then return uid==1000 and"Renamed"or"Second"end
  if step==3 then
   if uid==1000 and calls[uid]==1 then error("lookup transient failure")end
   return uid==1000 and"Recovered"or nil
  end
  return nil
 end
 local context={fs=fs,now_ns=function()return now end,resolve_username=resolve}
 local first=collector:sample(context);assert(#first.data.list==4)
 assert(calls[1000]==1 and calls[2000]==1,"same scan repeated a successful UID lookup")
 assert(first.data.by_pid[1].user=="Alice"and first.data.by_pid[2].user=="Alice")
 assert(first.data.by_pid[3].user==nil and first.data.by_pid[4].user==nil)
 step=2;calls={};now=now+1e9
 local second=collector:sample(context,first)
 assert(calls[1000]==1 and calls[2000]==1)
 assert(second.data.by_pid[1].user=="Renamed"and second.data.by_pid[2].user=="Renamed")
 assert(second.data.by_pid[3].user=="Second"and second.data.by_pid[4].user=="Second")
 assert(first.data.by_pid[1].user=="Alice"and first.data.by_pid[3].user==nil,"old snapshot changed")
 step=3;calls={};now=now+1e9
 local third=collector:sample(context,second)
 assert(calls[1000]==2 and calls[2000]==1,"lookup exception was memoized")
 assert(third.data.by_pid[1].user=="Renamed"and third.data.by_pid[2].user=="Recovered")
 assert(third.data.by_pid[3].user==nil and third.data.by_pid[4].user==nil)
 step=4;calls={};now=now+1e9
 context.resolve_username=function(uid)calls[uid]=(calls[uid]or 0)+1;return"Replacement"end
 local fourth=collector:sample(context,third)
 assert(calls[1000]==1 and calls[2000]==1)
 for _,row in ipairs(fourth.data.list)do assert(row.user=="Replacement")end
 assert(third.data.by_pid[1].user=="Renamed"and third.data.by_pid[2].user=="Recovered")
end
 print("per-scan UID names: sanitized once, missing preserved, next-scan rename, resolver replacement, exception retry and immutable old snapshots")
end
