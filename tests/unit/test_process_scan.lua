package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local Process = require("wtop.collectors.process")
local Parsers = require("wtop.linux.parsers")
local FS = require("wtop.linux.fs")

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

local file = assert(io.open("tests/fixtures/proc/100.stat.1", "rb"))
local original = file:read("*a"); file:close()
local function stat(pid)
  return original:gsub("^100 ", tostring(pid) .. " ")
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
