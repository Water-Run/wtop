#ifndef WTOP_LINUX_PROCESS_STATUS_H
#define WTOP_LINUX_PROCESS_STATUS_H
/* Retain the metadata lines already decoded by Lua.
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
static int wtop_linux_process_status_input(lua_State *L){
 size_t length;const char *input=luaL_checklstring(L,1,&length);
 if(length>256u*1024u){lua_pushnil(L);return 1;}
 struct wtop_status_span seen[128]={{0,0}},fields[9]={{0,0}};
 unsigned count=0;
 for(size_t at=0;at<length;){
  const char *newline=memchr(input+at,'\n',length-at);
  size_t end=newline?(size_t)(newline-input):length,key_end=at;uint32_t hash=2166136261u;
  while(key_end<end&&wtop_status_key_byte((unsigned char)input[key_end])){hash=(hash^(unsigned char)input[key_end])*16777619u;++key_end;}
  if(key_end<end&&(unsigned char)input[key_end]>=128){lua_pushnil(L);return 1;}
  if(key_end>at&&key_end<end&&input[key_end]==':'){
   size_t key_length=key_end-at;unsigned slot=hash&127u;
   while(seen[slot].length){
    if(seen[slot].length==key_length&&!memcmp(input+seen[slot].at,input+at,key_length)){lua_pushnil(L);return 1;}
    slot=(slot+1u)&127u;
   }
   if(++count>96){lua_pushnil(L);return 1;}
   seen[slot].at=(uint32_t)at;seen[slot].length=(uint32_t)key_length;
   for(unsigned i=0;i<9;++i)if(strlen(wtop_status_metadata_keys[i])==key_length&&!memcmp(wtop_status_metadata_keys[i],input+at,key_length)){
    fields[i].at=(uint32_t)at;fields[i].length=(uint32_t)(end-at);break;
   }
  }
  at=end+(newline!=NULL);
 }
 luaL_Buffer buffer;luaL_buffinit(L,&buffer);
 for(unsigned i=0;i<9;++i)if(fields[i].length){luaL_addlstring(&buffer,input+fields[i].at,fields[i].length);luaL_addchar(&buffer,'\n');}
 luaL_pushresult(&buffer);return 1;
}

#endif
