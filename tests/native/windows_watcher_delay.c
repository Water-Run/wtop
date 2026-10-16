#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
HANDLE WINAPI delayed_thread(LPSECURITY_ATTRIBUTES a,SIZE_T size,LPTHREAD_START_ROUTINE run,LPVOID data,DWORD flags,LPDWORD output){
 DWORD tid=0;HANDLE h=CreateThread(a,size,run,data,flags|CREATE_SUSPENDED,&tid);if(!h)return NULL;if(output)*output=tid;
 char path[1024],text[200];DWORD n=GetEnvironmentVariableA("WTOP_WATCH_THREAD",path,sizeof(path));
 if(n&&n<sizeof(path)){
  FILETIME c,e,k,u;GetThreadTimes(h,&c,&e,&k,&u);
  int count=snprintf(text,sizeof(text),"%lu %lu %lu %lu\n",(unsigned long)GetCurrentProcessId(),(unsigned long)tid,(unsigned long)c.dwHighDateTime,(unsigned long)c.dwLowDateTime);
  HANDLE f=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,CREATE_ALWAYS,0,NULL);
  if(f!=INVALID_HANDLE_VALUE){DWORD done;WriteFile(f,text,(DWORD)count,&done,NULL);CloseHandle(f);}
 }
 return h;
}
