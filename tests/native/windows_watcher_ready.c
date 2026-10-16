#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>
#include <assert.h>
static int marker(const char *path,unsigned long *a,unsigned long *b,unsigned long *c,unsigned long *d){
 DWORD start=GetTickCount();
 do{FILE *f=fopen(path,"rb");int n=f?fscanf(f,"%lu %lu %lu %lu",a,b,c,d):0;if(f)fclose(f);
  if(n>=3)return n;
  Sleep(5);
 }while(GetTickCount()-start<5000);return 0;
}
int main(int argc,char **argv){
 if(argc==2&&!strcmp(argv[1],"--parent")){Sleep(INFINITE);return 0;}
 assert(argc==4);int ready=!strcmp(argv[1],"ready");
 char entered[1024],thread_file[1024],lease[1024];
 snprintf(entered,sizeof(entered),"%s/entered",argv[3]);snprintf(thread_file,sizeof(thread_file),"%s/thread",argv[3]);snprintf(lease,sizeof(lease),"%s/lease",argv[3]);
 DeleteFileA(entered);DeleteFileA(thread_file);DeleteFileA(lease);
 HANDLE file=CreateFileA(lease,GENERIC_WRITE,FILE_SHARE_READ,NULL,CREATE_ALWAYS,0,NULL);assert(file!=INVALID_HANDLE_VALUE);CloseHandle(file);
 assert(SetEnvironmentVariableA("WTOP_HW_ENTERED",entered));assert(SetEnvironmentVariableA("WTOP_HW_BLOCK",lease));assert(SetEnvironmentVariableA("WTOP_WATCH_THREAD",thread_file));assert(SetEnvironmentVariableA("WTOP_NVML_FIXTURE_MODE","45"));
 WCHAR self[32768],command[32768],helper[32768];DWORD n=GetModuleFileNameW(NULL,self,32768);assert(n&&n<32768);
 assert(MultiByteToWideChar(CP_UTF8,0,argv[2],-1,helper,32768));
 STARTUPINFOW startup;memset(&startup,0,sizeof(startup));startup.cb=sizeof(startup);
 PROCESS_INFORMATION parent,reader;memset(&parent,0,sizeof(parent));memset(&reader,0,sizeof(reader));
 _snwprintf(command,32768,L"\"%ls\" --parent",self);
 assert(CreateProcessW(self,command,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,NULL,&startup,&parent));CloseHandle(parent.hThread);
 SECURITY_ATTRIBUTES security={sizeof(security),NULL,TRUE};HANDLE parent_watch,cancel,in_child,in_parent,out_parent,out_child;
 assert(DuplicateHandle(GetCurrentProcess(),parent.hProcess,GetCurrentProcess(),&parent_watch,SYNCHRONIZE,TRUE,0));
 cancel=CreateEventW(&security,TRUE,FALSE,NULL);assert(cancel);
 assert(CreatePipe(&in_child,&in_parent,&security,4096)&&SetHandleInformation(in_parent,HANDLE_FLAG_INHERIT,0));
 assert(CreatePipe(&out_parent,&out_child,&security,4096)&&SetHandleInformation(out_parent,HANDLE_FLAG_INHERIT,0));
 _snwprintf(command,32768,L"\"%ls\" --wtop-hardware-reader %lx %lx %lx %lx nvml",helper,
  (unsigned long)(uintptr_t)parent_watch,(unsigned long)(uintptr_t)cancel,(unsigned long)(uintptr_t)in_child,(unsigned long)(uintptr_t)out_child);
 assert(CreateProcessW(helper,command,NULL,NULL,TRUE,CREATE_NO_WINDOW,NULL,NULL,&startup,&reader));CloseHandle(reader.hThread);
 CloseHandle(parent_watch);CloseHandle(in_child);CloseHandle(out_child);
 unsigned char request[29]={1,0,0,0,'x',0x57,0x54,0x4e,0x4d,2,0,0,0,1};DWORD done;
 assert(WriteFile(in_parent,request,sizeof(request),&done,NULL)&&done==sizeof(request));
 unsigned long pid=0,tid=0,high=0,low=0,extra=0;
 assert(marker(thread_file,&pid,&tid,&high,&low)==4&&pid==reader.dwProcessId);
 HANDLE thread=OpenThread(THREAD_SUSPEND_RESUME|THREAD_QUERY_INFORMATION,FALSE,(DWORD)tid);assert(thread);
 FILETIME created,ended,kernel,user;assert(GetThreadTimes(thread,&created,&ended,&kernel,&user)&&created.dwHighDateTime==high&&created.dwLowDateTime==low);
 if(!ready)assert(marker(entered,&pid,&high,&low,&extra)>=3&&pid==reader.dwProcessId);
 assert(ResumeThread(thread)==1);CloseHandle(thread);
 if(ready)assert(marker(entered,&pid,&high,&low,&extra)>=3&&pid==reader.dwProcessId);
 assert(TerminateProcess(parent.hProcess,19)&&WaitForSingleObject(parent.hProcess,1000)==WAIT_OBJECT_0);
 int reaped=WaitForSingleObject(reader.hProcess,1000)==WAIT_OBJECT_0;
 int held=GetFileAttributesA(lease)!=INVALID_FILE_ATTRIBUTES;
 printf("WATCH_CAUSAL mode=%s reader_reaped_before_release=%d lease_exists=%d\n",argv[1],reaped,held);fflush(stdout);
 assert(held&&reaped==ready);assert(DeleteFileA(lease));
 if(WaitForSingleObject(reader.hProcess,3000)!=WAIT_OBJECT_0){TerminateProcess(reader.hProcess,23);WaitForSingleObject(reader.hProcess,3000);assert(0);}
 CloseHandle(parent.hProcess);CloseHandle(reader.hProcess);CloseHandle(cancel);CloseHandle(in_parent);CloseHandle(out_parent);
 return 0;
}
