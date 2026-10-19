package.path='./src/?.lua;./src/?/init.lua;'..package.path
local Parsers=require('wtop.linux.parsers')
local Reduce=_G.WTOP_STATUS_REDUCE or assert(require('wtop.native').process_status_metadata_input)
local checked,declined=0,0
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
assert(checked>3000 and declined>0)
print(('metadata reduction equivalence: %d cases, %d safe declines; real status, all decoded fields/errors, duplicates, huge fields, Unicode/NUL, collisions and bounded overflow passed'):format(checked,declined))
