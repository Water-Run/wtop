#ifndef WTOP_LINUX_PROCESS_STATUS_H
#define WTOP_LINUX_PROCESS_STATUS_H
/* Decode ordinary process metadata or retain its input for Lua parsing.
 * A bounded key inventory preserves rejection of duplicate unknown fields.
 * Unsupported inputs decline to the existing full Lua parser. */
#include <lua.h>
#include <lauxlib.h>
#include <stdint.h>
#include <string.h>
struct wtop_status_span {uint32_t at,length;};
static int wtop_status_key_byte(unsigned char c){
 return(c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_';
}
static const char *const wtop_status_metadata_keys[]={"Uid","Tgid","VmRSS","voluntary_ctxt_switches","nonvoluntary_ctxt_switches","NSpid","NStgid","Cpus_allowed_list","Mems_allowed_list"};
static int wtop_status_spans(const char *input,size_t length,struct wtop_status_span fields[9]){
 if(length>256u*1024u)return 0;
 struct wtop_status_span seen[128]={{0,0}};
 unsigned count=0;
 for(size_t at=0;at<length;){
  const char *newline=memchr(input+at,'\n',length-at);
  size_t end=newline?(size_t)(newline-input):length,key_end=at;uint32_t hash=2166136261u;
  while(key_end<end&&wtop_status_key_byte((unsigned char)input[key_end])){hash=(hash^(unsigned char)input[key_end])*16777619u;++key_end;}
  if(key_end<end&&(unsigned char)input[key_end]>=128)return 0;
  if(key_end>at&&key_end<end&&input[key_end]==':'){
   size_t key_length=key_end-at;unsigned slot=hash&127u;
   while(seen[slot].length){
    if(seen[slot].length==key_length&&!memcmp(input+seen[slot].at,input+at,key_length))return 0;
    slot=(slot+1u)&127u;
   }
   if(++count>96)return 0;
   seen[slot].at=(uint32_t)at;seen[slot].length=(uint32_t)key_length;
   for(unsigned i=0;i<9;++i)if(strlen(wtop_status_metadata_keys[i])==key_length&&!memcmp(wtop_status_metadata_keys[i],input+at,key_length)){
    fields[i].at=(uint32_t)at;fields[i].length=(uint32_t)(end-at);break;
   }
  }
  at=end+(newline!=NULL);
 }
 return 1;
}
static int wtop_linux_process_status_input(lua_State *L){
 size_t length;const char *input=luaL_checklstring(L,1,&length);
 struct wtop_status_span fields[9]={{0,0}};
 if(!wtop_status_spans(input,length,fields)){lua_pushnil(L);return 1;}
 luaL_Buffer buffer;luaL_buffinit(L,&buffer);
 for(unsigned i=0;i<9;++i)if(fields[i].length){luaL_addlstring(&buffer,input+fields[i].at,fields[i].length);luaL_addchar(&buffer,'\n');}
 luaL_pushresult(&buffer);return 1;
}

static int wtop_status_space(unsigned char c){
 return c==' '||c=='\t'||c=='\r'||c=='\n'||c=='\f'||c=='\v';
}
static int wtop_status_uint(const char **cursor,const char *end,lua_Integer maximum,lua_Integer *value){
 const char *p=*cursor;lua_Integer result=0;
 if(p==end||*p<'0'||*p>'9')return 0;
 do{
  lua_Integer digit=*p-'0';
  if(result>(maximum-digit)/10)return 0;
  result=result*10+digit;++p;
 }while(p<end&&*p>='0'&&*p<='9');
 *cursor=p;*value=result;return 1;
}
static int wtop_status_range(const char *p,const char *end,lua_Integer *count){
 lua_Integer total=0,previous=-1;
 if(p==end||(size_t)(end-p)>1024)return 0;
 for(;;){
  lua_Integer first,last;
  if(!wtop_status_uint(&p,end,65535,&first))return 0;
  last=first;
  if(p<end&&*p=='-'){++p;if(!wtop_status_uint(&p,end,65535,&last))return 0;}
  if(first>last||first<=previous||last-first+1>4096-total)return 0;
  total+=last-first+1;previous=last;
  if(p==end){*count=total;return 1;}
  if(*p!=','||++p==end)return 0;
 }
}
/* Decode only values accepted by the Lua oracle. A decline lets that parser
 * retain its detailed errors and partial-affinity handling. No external
 * allocation or descriptor survives a Lua allocation failure. */
static int wtop_linux_process_status_fields(lua_State *L){
 size_t length;const char *input=luaL_checklstring(L,1,&length);
 struct wtop_status_span fields[9]={{0,0}},values[9]={{0,0}};
 lua_Integer numbers[9]={0},chains[2][33]={{0}};unsigned chain_counts[2]={0};
 if(!wtop_status_spans(input,length,fields))goto decline;
 for(unsigned i=0;i<9;++i){
  if(!fields[i].length)continue;
  const char *end=input+fields[i].at+fields[i].length;
  const char *p=input+fields[i].at+strlen(wtop_status_metadata_keys[i])+1;
  while(p<end&&wtop_status_space((unsigned char)*p))++p;
  while(end>p&&wtop_status_space((unsigned char)end[-1]))--end;
  values[i].at=(uint32_t)(p-input);values[i].length=(uint32_t)(end-p);
  if(i<5){
   if(!wtop_status_uint(&p,end,LUA_MAXINTEGER,&numbers[i]))goto decline;
   if(i==0){if(p==end||!wtop_status_space((unsigned char)*p))goto decline;}
   else if(i==2){
    if(p==end||!wtop_status_space((unsigned char)*p))goto decline;
    while(p<end&&wtop_status_space((unsigned char)*p))++p;
    if(end-p!=2||p[0]!='k'||p[1]!='B'||numbers[i]>LUA_MAXINTEGER/1024)goto decline;
    numbers[i]*=1024;
   }else if(p!=end)goto decline;
  }else if(i<7){
   unsigned n=i-5;
   while(p<end){
    lua_Integer id;
    if(chain_counts[n]==33||!wtop_status_uint(&p,end,2147483647,&id)||id<1)goto decline;
    chains[n][chain_counts[n]++]=id;
    if(p<end&&!wtop_status_space((unsigned char)*p))goto decline;
    while(p<end&&wtop_status_space((unsigned char)*p))++p;
   }
   if(!chain_counts[n])goto decline;
  }else if(!wtop_status_range(p,end,&numbers[i]))goto decline;
 }
 luaL_checkstack(L,8,"process metadata");
 lua_createtable(L,0,8);
 static const char *const output_keys[]={"uid","tgid","rss_bytes","voluntary_context_switches","nonvoluntary_context_switches"};
 for(unsigned i=0;i<5;++i)if(fields[i].length){lua_pushinteger(L,numbers[i]);lua_setfield(L,-2,output_keys[i]);}
 for(unsigned n=0;n<2;++n)if(fields[n+5].length){
  lua_createtable(L,(int)chain_counts[n],0);
  for(unsigned j=0;j<chain_counts[n];++j){lua_pushinteger(L,chains[n][j]);lua_rawseti(L,-2,(lua_Integer)j+1);}
  lua_setfield(L,-2,n?"nstgid":"nspid");
 }
 if(fields[7].length||fields[8].length){
  lua_createtable(L,0,6);lua_newtable(L);lua_setfield(L,-2,"issues");
  for(unsigned i=7;i<9;++i)if(fields[i].length){
   lua_pushlstring(L,input+values[i].at,values[i].length);lua_setfield(L,-2,i==7?"cpus_allowed_list":"mems_allowed_list");
   lua_pushinteger(L,numbers[i]);lua_setfield(L,-2,i==7?"cpus_allowed_count":"mems_allowed_count");
  }
  lua_pushstring(L,fields[7].length&&fields[8].length?"ok":"partial");lua_setfield(L,-2,"status");
  lua_setfield(L,-2,"affinity");
 }
 return 1;
decline:
 lua_pushnil(L);return 1;
}

#endif
