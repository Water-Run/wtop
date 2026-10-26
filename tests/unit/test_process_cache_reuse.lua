package.path='./src/?.lua;./src/?/init.lua;'..package.path
local Process=require('wtop.collectors.process')
local file=assert(io.open('tests/fixtures/proc/100.stat.1','rb'))
local original=file:read('*a');file:close()
local now,command,uid,bytes,start,entries=1e9,'first\0argument\0',1000,10,1000,{'100'}
local stat_reads,command_reads,race_after_command=0,0,false
local function stat()
    local line=original:gsub(' 1000 10485760 ',' '..start..' 10485760 ')
    return line
end
local fs={list=function(_,path)
    if path=='/proc'then return entries end
    return nil,{kind='missing'}
end}
function fs:read(path)
    if path=='/proc/uptime'then return'100.0 0.0\n'end
    if path=='/proc/100/stat'then
        stat_reads=stat_reads+1
        return stat()
    end
    if path=='/proc/100/cmdline'then
        command_reads=command_reads+1
        if race_after_command then start=2000 end
        return command
    end
    if path=='/proc/100/status'then
        return 'Uid:\t'..uid..'\t0\t0\t0\nVmRSS:\t2048 kB\nCpus_allowed_list:\t0-1\nNSpid:\t100\t1\n'
    end
    if path=='/proc/100/io'then return'read_bytes: '..bytes..'\nwrite_bytes: '..bytes..'\n'end
    return nil,{kind='missing'}
end
local c=Process.new({fs=fs,read_cmdline=true,clock_ticks_per_second=100,page_size_bytes=4096})
local prior
local function sample(detail)
    local context={fs=fs,now_ns=function()return now end,scan_process_io_rate=true}
    if detail then context.selected_process_ids={['100:'..start]=true}end
    prior=c:sample(context,prior);now=now+1e9
    return prior.data.by_id['100:'..start]
end
local first=assert(sample());local entry=c.identity_cache['100:1000']
assert(first.command=='first argument'and command_reads==1 and first.io.read_bytes==10)
local second=assert(sample())
assert(c.identity_cache['100:1000']==entry,'stable identity rebuilt its private cache record')
assert(second.command=='first argument'and command_reads==1 and entry.command_read)
command,bytes='updated\0argument\0',30
now=now+6e9
local third=assert(sample())
assert(third.command=='updated argument'and command_reads==2 and third.io.read_bytes==30)
assert(c.identity_cache['100:1000']==entry)
assert(first.command=='first argument'and first.io.read_bytes==10 and second.io.read_bytes==10,
    'cache reuse mutated an earlier public snapshot')
assert(first.namespaces.inner_pid==1)
command,uid,bytes='',2000,40
local refreshed=assert(sample(true))
assert(refreshed.command==nil and refreshed.uid==2000 and refreshed.io.read_bytes==40)
assert(first.uid==1000 and first.io.read_bytes==10 and first.command=='first argument')
assert(c.identity_cache['100:1000']==entry and entry.command==nil)
assert(sample().command==nil)
command='final\0'
now=now+6e9
assert(sample().command=='final','ordinary argv did not refresh after its deadline')
local valid_entry=c.identity_cache['100:1000'];local valid_command=valid_entry.command
local valid_read=valid_entry.command_read;race_after_command=true;command='mixed\0'
sample(true)
assert(#prior.data.list==0 and prior.data.races==1 and next(c.identity_cache)==nil)
assert(valid_entry.command==valid_command and valid_entry.command_read==valid_read,
    'an invalid supplemental record mutated the previous cache')
race_after_command=false;start=1000;command='final\0';sample()

-- Duplicate input rows must not mutate the prior-cache record while another
-- row in that same pass is still reading it.
local old_entry=c.identity_cache['100:1000'];entries={'100','100'}
sample();assert(#prior.data.list==2 and c.identity_cache['100:1000']~=old_entry)
entries={};sample();assert(next(c.identity_cache)==nil)
entries={'100'};local reappeared=assert(sample())
assert(reappeared.command=='final'and c.identity_cache['100:1000']~=old_entry)
start=2000;command='new-generation\0'
local reused=assert(sample());assert(reused.id=='100:2000'and reused.command=='new-generation')
assert(not c.identity_cache['100:1000'])

-- A different filesystem can reuse pid/start with different metadata.
local before=c.identity_cache['100:2000']
local other={list=fs.list,read=fs.read};uid=3000;command='other-source\0'
local changed=c:sample({fs=other,now_ns=function()return now end},prior)
assert(changed.data.by_id['100:2000'].uid==3000 and changed.data.by_id['100:2000'].command=='other-source')
assert(c.identity_cache['100:2000']~=before)
print('ok: private cache object reuse, bounded argv refresh, immutable older snapshots, duplicates and process/filesystem lifecycle')
