#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include <stdio.h>
static void record_parent(void){
 char path[1024],text[160];DWORD n=GetEnvironmentVariableA("WTOP_HW_PARENT",path,sizeof(path));
 if(!n||n>=sizeof(path))return;
 FILETIME created,ended,kernel,user;if(!GetProcessTimes(GetCurrentProcess(),&created,&ended,&kernel,&user))return;
 int size=snprintf(text,sizeof(text),"%lu %lu %lu parent\n",(unsigned long)GetCurrentProcessId(),(unsigned long)created.dwHighDateTime,(unsigned long)created.dwLowDateTime);
 HANDLE f=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,CREATE_ALWAYS,0,NULL);
 if(f!=INVALID_HANDLE_VALUE){DWORD done;WriteFile(f,text,(DWORD)size,&done,NULL);CloseHandle(f);}
}
static FARPROC WINAPI test_export(HMODULE module,const char *name){
 if(!strcmp(name,"GetNativeSystemInfo"))record_parent();
 char value[16];DWORD n=GetEnvironmentVariableA("WTOP_NVML_TEST_BITS",value,sizeof(value));
 if(n==2&&!strcmp(value,"32")&&!strcmp(name,"GetNativeSystemInfo"))return NULL;
 return GetProcAddress(module,name);
}
#define GetProcAddress test_export
