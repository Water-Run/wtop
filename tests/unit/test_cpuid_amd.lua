-- Independent upstream hardware dumps and hwloc XML; see fixture metadata/license.
local source=debug.getinfo(1,"S").source:gsub("^@", ""):gsub("\\", "/")
local root=source:match("^(.*)/tests/unit/[^/]+$")or"."
do
local CPUID=require('wtop.model.cpuid')
local Decode=require('wtop.core.json')
local base=root.."/tests/fixtures/cpuid/amd"
local function read(path)
  local f=assert(io.open(path,'rb'));local value=f:read('a');f:close();return value
end
local function membership(ids)
  local copy={table.unpack(ids)};table.sort(copy);return table.concat(copy,',')
end
local function same_set(a,b)
  for key,value in pairs(a)do assert(b[key]==value,'missing/different '..key)end
  for key,value in pairs(b)do assert(a[key]==value,'unexpected/different '..key)end
end
for _,fixture in ipairs(assert(Decode.decode(read(base..'/replay/manifest.json'))))do
  local targets={};for _,id in ipairs(fixture.cpu_ids)do targets[#targets+1]={id=id}end
  local result=assert(CPUID.decode(read(base..'/'..fixture.path),targets))
  assert(result.topology.complete and result.caches_complete)
  local got={Core={},Package={},Cache={}}
  local cores,packages={},{}
  for _,cpu in ipairs(result.logical_cpus)do
    local top=cpu.topology
    cores[top.core_key]=cores[top.core_key]or{};table.insert(cores[top.core_key],cpu.id)
    packages[top.package_id]=packages[top.package_id]or{};table.insert(packages[top.package_id],cpu.id)
  end
  for _,ids in pairs(cores)do got.Core[membership(ids)]=true end
  for _,ids in pairs(packages)do got.Package[membership(ids)]=true end
  for _,cache in ipairs(result.caches)do
    local key=cache.level..':'..cache.type..':'..membership(cache.shared_cpu_list)
    assert(not got.Cache[key]);got.Cache[key]=string.format('%.0f:%d',cache.size_bytes,cache.coherency_line_size_bytes)
  end
  local want={Core={},Package={},Cache={}}
  for _,item in ipairs(assert(Decode.decode(read(base..'/replay/'..fixture.dataset..'.expected.json'))))do
    local kind=item.type
    if kind=='Core'or kind=='Package'then want[kind][membership(item.cpu_ids)]=true
    elseif kind:find('Cache',1,true)then
      local key=item.depth..':'..({['0']='Unified',['1']='Data',['2']='Instruction'})[item.cache_type]..':'..membership(item.cpu_ids)
      want.Cache[key]=tonumber(item.cache_size)..':'..tonumber(item.cache_linesize)
    end
  end
  same_set(got.Core,want.Core);same_set(got.Package,want.Package);same_set(got.Cache,want.Cache)
  if fixture.dataset:find('Zen5',1,true)then
    assert(#result.core_types==2)
    assert(result.core_types[1].core_type==0 and result.core_types[1].logical_cpu_count==8 and result.core_types[1].physical_core_count==4)
    assert(result.core_types[2].core_type==1 and result.core_types[2].logical_cpu_count==16 and result.core_types[2].physical_core_count==8)
  end
  print('Verified upstream XML package/core/cache membership, size and line: '..fixture.dataset)
end
end

do
local CPUID=require('wtop.model.cpuid')
local Decode=require('wtop.core.json')
local base=root.."/tests/fixtures/cpuid/amd"
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('a');f:close();return s end
local fixtures=assert(Decode.decode(read(base..'/replay/manifest.json')))
local function put(raw,p,v)return raw:sub(1,p-1)..string.pack('<I4',v)..raw:sub(p+4)end
local function seal(raw)
  local hash=2166136261
  for i=33,#raw do hash=((hash~raw:byte(i))*16777619)&0xffffffff end
  return put(raw,25,hash)
end
local function offset(raw,id,number,sub)
  local p=33
  for _=1,string.unpack('<I4',raw,13)do
    local cpu=string.unpack('<I4',raw,p);local n=string.unpack('<I4',raw,p+16)
    for i=0,n-1 do
      local q=p+48+i*24;local a,b=string.unpack('<I4I4',raw,q)
      if cpu==id and a==number and b==(sub or 0)then return q end
    end
    p=p+48+n*24
  end
  error('missing fixture leaf')
end
local function load(index)
  local f=fixtures[index];local t={};for _,id in ipairs(f.cpu_ids)do t[#t+1]={id=id}end
  return read(base..'/'..f.path),t
end
local modern,targets=load(3)
local no26=seal(put(modern,offset(modern,0,0x80000026)+12,0))
local fallback=assert(CPUID.decode(no26,targets))
assert(fallback.topology.complete and fallback.logical_cpus[1].topology.method=='CPUID.0B AMD')
assert(fallback.topology.physical_cores==192 and fallback.caches_complete)
local mismatch=modern
local ext=offset(mismatch,0,0x80000001)
mismatch=put(mismatch,ext+16,string.unpack('<I4',mismatch,ext+16)&~(1<<22))
for sub=0,3 do mismatch=put(mismatch,offset(mismatch,0,0x80000026,sub)+20,256)end
assert(not assert(CPUID.decode(seal(mismatch),targets)).topology.complete,
  'A valid older APIC view still checks AMD26 when TOPOEXT/1E is unavailable')
-- The Windows wire has different coordinates, including groups beyond64 CPUs.
local windows=put(modern,5,1)
local windows_targets={};local at=33
for _,target in ipairs(targets)do
  local id=target.id;local count=string.unpack('<I4',windows,at+16)
  windows_targets[#windows_targets+1]={id=id,processor_group=id//64,logical_processor_index=id%64}
  windows=put(put(windows,at+4,id//64),at+8,id%64)
  at=at+48+count*24
end
local large=assert(CPUID.decode(seal(windows),windows_targets))
assert(large.platform=='windows'and large.topology.physical_cores==192 and large.caches_complete)
local old_os={topology={logical_cpus=windows_targets,threads=#windows_targets},caches={}}
CPUID.enrich(old_os,{status='ok',raw=seal(windows),targets=windows_targets})
assert(old_os.topology.source=='CPUID'and old_os.topology.sockets==2 and #old_os.caches==600)
for sub=0,3 do
  local p=offset(modern,0,0x80000026,sub)
  local altered=seal(put(modern,p+20,256))
  assert(not assert(CPUID.decode(altered,targets)).topology.complete,'APIC disagreement cannot become independent hardware agreement')
end
for _,change in ipairs({{1,8,0},{1,16,0xff01},{2,16,0x202},{2,16,0x301}})do
  local sub,field,value=table.unpack(change)
  local altered=seal(put(modern,offset(modern,0,0x80000026,sub)+field,value))
  assert(not assert(CPUID.decode(altered,targets)).topology.complete,'Malformed active AMD26 cannot fall through to a confident older view')
end
local zen,zen_targets=load(1)
local p=offset(zen,0,0x80000001)
assert(not assert(CPUID.decode(seal(put(zen,p+16,string.unpack('<I4',zen,p+16)&~(1<<22))),zen_targets)).topology.complete)
local altered=modern
for _,target in ipairs(targets)do
  for sub=0,3 do
    local q=offset(altered,target.id,0x80000026,sub)
    altered=put(altered,q+12,(string.unpack('<I4',altered,q+12)&0xffff0000)|500)
  end
end
assert(assert(CPUID.decode(seal(altered),targets)).topology.physical_cores==192,'Advertised logical counts remain diagnostic')
local hybrid,hybrid_targets=load(4)
p=offset(hybrid,0,0x80000026)
local result=assert(CPUID.decode(seal(put(hybrid,p+8,string.unpack('<I4',hybrid,p+8)&~(1<<29))),hybrid_targets))
assert(result.logical_cpus[1].identity.core_type==0 and result.logical_cpus[1].identity.efficiency_ranking==nil)
local count=string.unpack('<I4',hybrid,49)
local subset=hybrid:sub(1,32+48+count*24)
subset=seal(put(put(subset,9,#subset),13,1))
local data={topology={logical_cpus=hybrid_targets,threads=#hybrid_targets,truncated=false,quality='fresh'}}
CPUID.enrich(data,{status='ok',raw=subset,targets={hybrid_targets[1]},platform='linux'})
assert(data.cpuid.truncated and not data.cpuid.roster_complete and data.cpuid.quality=='partial')
assert(data.cpuid.os_comparison.topology_matches==nil)
print('Modern AMD APIC/domain/TOPOEXT/diagnostic count/ranking validity/partial roster model checks passed')
end

do
  local CPUID=require('wtop.model.cpuid')
  local Export=require('wtop.export')
  local file=assert(io.open(root..'/tests/fixtures/cpuid/amd/replay/AMD-1Ah-Zen5StrixPoint-RyzenAI9HX370.bin','rb'))
  local raw=file:read('a');file:close()
  local targets={};for id=0,23 do targets[#targets+1]={id=id}end
  local data={identity={vendor='AuthenticAMD'},topology={logical_cpus=targets,threads=24,quality='fresh'}}
  CPUID.enrich(data,{status='ok',raw=raw,targets=targets,source='upstream register replay',platform='linux'})
  assert(data.cpuid.core_types[1].core_type_class=='performance'and data.cpuid.core_types[2].core_type_class=='efficiency')
  local snapshot={cpu_info=data}
  local exported=Export.snapshot(snapshot).cpu_info.cpuid
  assert(exported.core_types[1].vendor=='AuthenticAMD'and exported.core_types[1].efficiency_ranking_minimum==0)
  assert(exported.logical_cpus[1].identity.efficiency_ranking==0)
  assert(exported.logical_cpus[1].topology.levels[1].domain=='core')
  assert(exported.logical_cpus[1].topology.levels[4].domain=='socket')
  assert(Export.agent(snapshot).metrics.cpu.cpuid.core_types[2].core_type_class=='efficiency')
  local stale={topology={logical_cpus=targets,threads=24}}
  CPUID.enrich(stale,{status='ok',raw=raw,targets=targets,quality='stale',retained=true,reason='cpuid_probe_timeout'})
  assert(stale.cpuid.quality=='stale'and stale.cpuid.core_types[1].quality=='stale',
    'Retained hardware types must inherit their observation staleness')
  assert(Export.agent({cpu_info=stale}).metrics.cpu.cpuid.core_types[1].quality=='stale')
  local report=require('wtop.report').render(Export.snapshot(snapshot))
  assert(report:find('CPU hardware core types (CPUID.80000026)',1,true))
  assert(report:find('Power efficiency rank',1,true)and report:find('0 · 8/8 CPUs',1,true))
  assert(not report:find('CPU hardware core types (CPUID.1A)',1,true))
  local i18n=assert(require('wtop.i18n').new({locale='zh-CN'}))
  assert(require('wtop.i18n.technical').cpu_core_type(i18n,data.cpuid.core_types[1])=='AMD 性能')
  local view=require('wtop.view_model').build({history_values=function()return{}end},snapshot,i18n,{},'compute')
  local names={};for _,row in ipairs(view.cpu_identity.entries)do names[row.label or'']=true end
  assert(names['AMD 性能 (0x00)']and names['AMD 能效 (0x01)'])
  local detail=table.concat(require('wtop.tui').hardware_detail_lines(snapshot,'cpu:0',i18n),'\n')
  assert(detail:find('功耗效率排序值: 0',1,true),detail)
  -- Conflicting type reports within an independently decoded physical core
  -- retain raw observations but cannot both claim whole physical cores.
  local p=33
  local n=string.unpack('<I4',raw,p+16)
  local changed=raw
  for index=0,n-1 do
    local q=p+48+index*24;local number,sub=string.unpack('<I4I4',raw,q)
    if number==0x80000026 and sub==0 then
      changed=raw:sub(1,q+11)..string.pack('<I4',string.unpack('<I4',raw,q+12)~(1<<28))..raw:sub(q+16)
      break
    end
  end
  local hash=2166136261;for index=33,#changed do hash=((hash~changed:byte(index))*16777619)&0xffffffff end
  changed=changed:sub(1,24)..string.pack('<I4',hash)..changed:sub(29)
  local conflict=assert(CPUID.decode(changed,targets))
  assert(conflict.quality=='partial'and conflict.reason=='cpuid_core_type_views_disagree'and #conflict.issues>0)
  for _,kind in ipairs(conflict.core_types)do assert(kind.quality=='partial'and kind.physical_core_count==nil)end
  print('ok: AMD vendor type0/ranking0, Snapshot/Agent/report, localized Compute and conflicting SMT type evidence')
end
return true
