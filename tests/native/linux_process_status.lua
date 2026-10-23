package.path='./src/?.lua;./src/?/init.lua;'..package.path
local Parsers=require('wtop.linux.parsers')
local Reduce=_G.WTOP_STATUS_REDUCE or assert(require('wtop.native').process_status_metadata_input)
local Decode=_G.WTOP_STATUS_FIELDS or assert(require('wtop.native').process_status_metadata_fields)
local checked,declined,decoded=0,0,0
local function same(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if k~='raw'and not same(v,b[k])then return false end end
 for k,v in pairs(b)do if k~='raw'and a[k]==nil then return false end end
 return true
end
local function check(content)
 local baseline,reason=Parsers.process_status(content);local compact=Reduce(content)
 if compact==nil then declined=declined+1 else assert(type(compact)=='string')end
 local result,why=Parsers.process_status(compact or content)
 assert(same(baseline,result)and reason==why,'reduced input changed decoded fields or error: '..content:sub(1,120))
 local direct=Decode(content)
 if direct then
  assert(type(direct)=='table'and same(baseline,direct),'native metadata differs: '..content:sub(1,120))
  decoded=decoded+1
 end
 checked=checked+1
end
local f=assert(io.open('tests/fixtures/proc/100.status','rb'));local sample=f:read('*a');f:close();check(sample)
f=assert(io.open('/proc/self/status','rb'));local real=f:read('*a');f:close();check(real)
local keys={'Uid','Tgid','VmRSS','voluntary_ctxt_switches','nonvoluntary_ctxt_switches','NSpid','NStgid','Cpus_allowed_list','Mems_allowed_list','Name','State','Unknown_1'}
local values={'','0','1','1000\t1000\t1000\t1000','123 kB','0-1,4','1 2 3','not a number','-1','18446744073709551616','1\0x','你好','1\r','  1\t '}
for _,key in ipairs(keys)do for _,value in ipairs(values)do
 for _,suffix in ipairs({'','\n','\r\n'})do
  check(key..':'..value..suffix)
  check('Name: before\n'..key..':\t'..value..suffix)
  check(key..': '..value..'\n'..key..': '..value..'\n')
 end
end end
for _,s in ipairs({'','\n',' \nUid: 1 1 1 1','Uid : 1\n',' UID: 1\n','Uid: 1 1 1 1\nName: a:b\n','Name: x\nUnknown: 1\nUnknown: 2','\255: x\nUid: 1 1 1 1','Uid\255: 1\nUid: 2 2 2 2','Uid: 1 1 1 1\0\n','Uid: '..string.rep(' ',60000)..'1000 1000 1000 1000\n'})do check(s)end
local large={};for i=1,150 do large[#large+1]='Extra_'..i..': arbitrary' end;large[#large+1]='Uid: 7 7 7 7';check(table.concat(large,'\n'))
check(string.rep('x',256*1024+1))
-- Force bounded hash collisions without changing the Lua interpretation.
local collisions={};local n=0
while #collisions<80 do
 n=n+1;local key='Collision_'..n;local hash=2166136261
 for i=1,#key do hash=((hash~key:byte(i))*16777619)&0xffffffff end
 if hash&127==0 then collisions[#collisions+1]=key..': data'end
end
collisions[#collisions+1]='Uid: 4 4 4 4';check(table.concat(collisions,'\n'))
math.randomseed(624813)
for trial=1,2000 do
 local lines={}
 for j=1,math.random(0,20)do
  local key=keys[math.random(#keys)];local value=values[math.random(#values)]
  lines[#lines+1]=(math.random(4)==1 and ' 'or'')..key..':'..value
 end
 check(table.concat(lines,'\n'))
end
for n=1,1000 do
 local content=('Uid:\t%d\t%d\t0\t0\nTgid:\t%d\nVmRSS:\t%d kB\nNSpid:\t%d\t1\nNStgid:\t%d\t1\nCpus_allowed_list:\t0-15,20-31\nMems_allowed_list:\t0\nvoluntary_ctxt_switches:\t%d\nnonvoluntary_ctxt_switches:\t%d\n'):format(n,n,n,n*1024,n,n,n*100,n*10)
 assert(type(Decode(content))=='table','ordinary status must use direct decoding');check(content)
end
for _,content in ipairs({
 'Uid: 9223372036854775807\t0\n', 'Uid: 9223372036854775808\t0\n',
 'VmRSS: 9007199254740991 kB\n','VmRSS: 9007199254740992 kB\n',
 'voluntary_ctxt_switches: 9223372036854775807\n','nonvoluntary_ctxt_switches: 9223372036854775808\n',
 'Cpus_allowed_list: 0-4095\n','Cpus_allowed_list: 0-4096\n',
 'Cpus_allowed_list: 000,01-02,65535\nMems_allowed_list: 0\n',
 'Cpus_allowed_list: 1,0\n','Cpus_allowed_list: 1,1\n','Cpus_allowed_list: count\n',
 'NSpid: '..string.rep('1 ',33)..'\n','NSpid: '..string.rep('1 ',34)..'\n',
})do check(content)end
assert(checked>4000 and declined>0 and decoded>=1000)
print(('metadata reduction equivalence: %d cases, %d safe declines; real status, all decoded fields/errors, duplicates, huge fields, Unicode/NUL, collisions and bounded overflow passed'):format(checked,declined))
print(('direct metadata decode equivalence: %d accepted cases; native declines preserve Lua interpretation'):format(decoded))
