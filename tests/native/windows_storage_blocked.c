/* Test-only replacement translation unit: all real storage calls are kept,
 * with a task-local trigger that delays one chosen reader's API entry. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

static int ends_with(const WCHAR *value, const WCHAR *suffix) {
    size_t length=wcslen(value),tail=wcslen(suffix);
    return length>=tail&&!wcscmp(value+length-tail,suffix);
}
static void marker(const char *root,const char *kind,const char *state) {
    char path[1024],data[256];FILETIME created,exited,kernel,user;
    if(!GetProcessTimes(GetCurrentProcess(),&created,&exited,&kernel,&user))ExitProcess(91);
    unsigned long long birth=(unsigned long long)created.dwHighDateTime<<32|created.dwLowDateTime;
    int size=snprintf(path,sizeof(path),"%s/%s.%s",root,kind,state);
    if(size<0||(size_t)size>=sizeof(path))ExitProcess(92);
    HANDLE file=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,CREATE_ALWAYS,0,NULL);
    if(file==INVALID_HANDLE_VALUE)ExitProcess(93);
    size=snprintf(data,sizeof(data),"{\"pid\":%lu,\"birth\":\"%llu\",\"lease_ms\":10000}\n",
        (unsigned long)GetCurrentProcessId(),birth);
    DWORD written=0;
    if(size<0||(size_t)size>=sizeof(data)||!WriteFile(file,data,(DWORD)size,&written,NULL)
        ||written!=(DWORD)size){CloseHandle(file);ExitProcess(94);}
    CloseHandle(file);
}
static BOOL WINAPI delayed_ioctl(HANDLE h,DWORD code,LPVOID input,DWORD input_size,
    LPVOID output,DWORD capacity,LPDWORD returned,LPOVERLAPPED overlapped) {
    char root[768],target[32],direct[8],trigger[1024];
    static int blocked_once;
    DWORD length=GetEnvironmentVariableA("WTOP_STORAGE_FAULT_ROOT",root,sizeof(root));
    DWORD target_length=GetEnvironmentVariableA("WTOP_STORAGE_FAULT_TARGET",target,sizeof(target));
    if(length&&length<sizeof(root)&&target_length&&target_length<sizeof(target)) {
        const WCHAR *command=GetCommandLineW();
        int reader=ends_with(command,L" disk_health")?1:ends_with(command,L" disk")?2:0;
        int synchronous=GetEnvironmentVariableA("WTOP_STORAGE_FAULT_DIRECT",direct,sizeof(direct))&&direct[0]=='1';
        int health=!strcmp(target,"health")&&(reader==1||(!reader&&synchronous));
        int disk=!strcmp(target,"disk")&&(reader==2||(!reader&&synchronous));
        int match=(health&&code==IOCTL_STORAGE_QUERY_PROPERTY&&input_size>=8
            &&((DWORD *)input)[0]==0)||(disk&&code==IOCTL_DISK_PERFORMANCE);
        if(match) {
            marker(root,target,"seen");
            int n=snprintf(trigger,sizeof(trigger),"%s/trigger",root);
            if(n<0||(size_t)n>=sizeof(trigger))ExitProcess(95);
            if(!blocked_once&&GetFileAttributesA(trigger)!=INVALID_FILE_ATTRIBUTES) {
                blocked_once=1;
                marker(root,target,"blocked");
                Sleep(10000);
            }
        }
    }
    return DeviceIoControl(h,code,input,input_size,output,capacity,returned,overlapped);
}
#define DeviceIoControl delayed_ioctl
#include "../../native/wtop_windows_disk.c"
