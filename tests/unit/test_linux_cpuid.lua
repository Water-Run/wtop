package.path='./src/?.lua;./src/?/init.lua;'..package.path
local Model=require('wtop.model.cpuid')
local Adapter=require('wtop.collectors.linux_cpuid')
local Export=require('wtop.export')
local f=assert(io.open('tests/fixtures/cpuid/intel-06-97.bin','rb'));local original=f:read('a');f:close()
local function u32(raw,at,value)return raw:sub(1,at-1)..string.pack('<I4',value)..raw:sub(at+4)end
local function seal(raw)
 local hash=2166136261;for i=33,#raw do hash=((hash~raw:byte(i))*16777619)&0xffffffff end
 return u32(raw,25,hash)
end
local windows={};for id=0,7 do windows[#windows+1]={id=id,processor_group=0,logical_processor_index=id}end
assert(Model.decode(u32(original,5,2),windows)==nil,'Linux packet accepted Windows coordinates')
local ids={0,65,1000,1001,2048,4096,65536,1048575};local targets={};local raw=u32(original,5,2)
local at=33
for i=1,8 do
 targets[i]={id=ids[i]};local n=string.unpack('<I4',raw,at+16)
 raw=u32(u32(u32(raw,at,ids[i]),at+4,0),at+8,ids[i])
 for j=0,n-1 do
  local p=at+48+j*24;local leaf=string.unpack('<I4',raw,p)
  if leaf==0x1a then raw=u32(raw,p+8,(i<=6 and 0x40000000 or 0x20000000)|1)end
 end
 at=at+48+n*24
end
raw=seal(raw)
local decoded=assert(Model.decode(raw,targets));assert(decoded.platform=='linux'and decoded.caches_complete)
for _,cpu in ipairs(decoded.logical_cpus)do assert(cpu.processor_group==nil and cpu.logical_processor_index==nil and cpu.os_logical_cpu_id==cpu.id)end
assert(#decoded.core_types==2)
local counts={};for _,kind in ipairs(decoded.core_types)do counts[kind.core_type]=kind.logical_cpu_count end
assert(counts[0x40]==6 and counts[0x20]==2)
local data={identity={},topology={threads=8,quality='fresh',logical_cpus={}},caches=decoded.caches}
for _,cpu in ipairs(decoded.logical_cpus)do
 data.topology.logical_cpus[#data.topology.logical_cpus+1]={id=cpu.id,online=true,package_id=cpu.topology.package_id,core_key=cpu.topology.core_key}
end
local os_top,os_caches=data.topology,data.caches
Model.enrich(data,{status='ok',raw=raw,targets=targets,observed_at_ns=1e9,transport='process'})
assert(data.topology==os_top and data.caches==os_caches and data.os_topology==nil,'CPUID replaced the kernel report')
assert(data.cpuid.os_comparison.topology_matches==true and data.cpuid.os_comparison.cache_matches==true)
data.topology.logical_cpus[1].core_key='different'
Model.enrich(data,{status='ok',raw=raw,targets=targets})
assert(data.cpuid.os_comparison.topology_matches==false and data.topology==os_top)
data.topology.logical_cpus[1].core_key=decoded.logical_cpus[1].topology.core_key
local missing={};for i,cache in ipairs(decoded.caches)do local row={};for k,v in pairs(cache)do row[k]=v end;missing[i]=row end
missing[1].ways_of_associativity=nil;data.caches=missing
Model.enrich(data,{status='ok',raw=raw,targets=targets})
assert(data.cpuid.os_comparison.cache_matches==nil and not data.cpuid.os_comparison.cache_geometry_complete)
local shifted={};for i,cache in ipairs(decoded.caches)do local c={};for k,v in pairs(cache)do c[k]=v end;shifted[i]=c end
shifted[1].size_bytes=shifted[1].size_bytes+64;data.caches=shifted
Model.enrich(data,{status='ok',raw=raw,targets=targets})
assert(data.cpuid.os_comparison.cache_matches==false and data.caches==shifted)
-- A 32-bit Linux observation cannot prove OS-managed SSE state from hardware.
local small=assert(Model.decode(u32(raw,17,32),targets))
for _,feature in ipairs(small.logical_cpus[1].features)do if feature.name=='SSE2' then assert(feature.hardware and feature.os_enabled==nil and feature.usable==nil)end end
-- Last observation time survives cache reads, and a changed OS roster forces a new query.
local now,calls=1e9,0
local owner={proc_cpuinfo_path='/fixture',sys_cpu_path='/fixture',cpuid_provider=function(rows)
 calls=calls+1;assert(#rows==8);return{status='ok',timestamp_ns=now,data={status='ok',raw=raw}}
end}
local ctx={now_ns=function()return now end}
Adapter.enrich(owner,data,ctx,{})
assert(calls==1 and data.cpuid.observed_at_ns==1e9)
now=2e9;Adapter.enrich(owner,data,ctx,{})
assert(calls==1 and data.cpuid.observed_at_ns==1e9 and data.cpuid.age_ms==1000)
data.identity.microcode='changed';now=3e9;Adapter.enrich(owner,data,ctx,{})
assert(calls==2 and data.cpuid.observed_at_ns==3e9)
owner.cpuid_provider=function()return{status='error',sampling_pending=true,reason='hardware_query_pending'}end
now=40e9;local retry,pending=Adapter.enrich(owner,data,ctx,{})
assert(retry==25 and pending and data.cpuid.quality=='stale'and data.cpuid.retained and data.cpuid.observed_at_ns==3e9 and data.topology==os_top)
Adapter.close(owner);Adapter.enrich(owner,data,ctx,{})
assert(not owner._cpuid_worker and not owner._cpuid_last)
Model.enrich(data,{status='ok',raw=raw,targets=targets,transport='process',observed_at_ns=3e9})
local snapshot={cpu_info=data,quality={cpu_info={status='ok',quality='fresh'}},timestamp_ns=now}
local exported=Export.snapshot(snapshot).cpu_info.cpuid
assert(exported.platform=='linux'and exported.transport=='process'and exported.os_comparison.cache_matches==false)
assert(exported.logical_cpus[8].os_logical_cpu_id==1048575 and #exported.cache_summary>0)
assert(Export.agent(snapshot).metrics.cpu.cpuid.core_types[1].logical_cpu_count>0)
local partial={topology={threads=16,logical_cpus={table.unpack(data.topology.logical_cpus)}}}
for id=600000,600007 do partial.topology.logical_cpus[#partial.topology.logical_cpus+1]={id=id}end
Model.enrich(partial,{status='ok',raw=raw,targets=targets})
assert(partial.cpuid.quality=='partial'and partial.cpuid.truncated and not partial.cpuid.roster_complete)
assert(partial.topology.threads==16 and partial.cpuid.os_comparison.topology_matches==nil)
local malformed={topology={logical_cpus={false}}}
Model.enrich(malformed,{status='ok',raw=raw,targets=targets})
assert(malformed.cpuid.reason=='cpuid_invalid_response')
malformed={topology={logical_cpus=data.topology.logical_cpus}}
Model.enrich(malformed,{status='ok',raw=raw,targets='invalid'})
assert(malformed.cpuid.reason=='cpuid_invalid_response')
local i18n=assert(require('wtop.i18n').new({locale='en-US'}))
local TUI=require('wtop.tui')
local detail=table.concat(TUI.hardware_detail_lines(snapshot,'cpu:0',i18n),'\n')
assert(detail:find('Hardware core type: 0x40 · CPUID.1A',1,true),detail)
assert(detail:find('Native core model:',1,true)and detail:find('AVX: Hardware yes · Usable yes',1,true))
local View=require('wtop.view_model')
local model=View.build({history_values=function()return{}end},snapshot,i18n,{},'compute')
local found={};for _,entry in ipairs(model.cpu_identity.entries or{})do if entry.label then found[entry.label]=entry.value end end
assert(found['Topology matches OS']=='yes'and found['Caches match OS']=='no')
local report=require('wtop.report').render(Export.snapshot(snapshot))
assert(report:find('CPU hardware core types (CPUID.1A)',1,true)and report:find('| Topology matches OS | yes |',1,true))
print('ok: Linux CPUID v2 sparse IDs, OS report preservation, topology/cache disagreement, SSE uncertainty, cache time/roster, close and exports')
return true
