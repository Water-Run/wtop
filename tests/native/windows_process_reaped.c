/* Check exactly one test reader by PID and creation time, without treating
 * access or wait failures as proof that it exited. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv) {
    if(argc!=4)return 2;
    DWORD pid=(DWORD)strtoul(argv[1],NULL,10),wait=(DWORD)strtoul(argv[3],NULL,10);
    unsigned long long expected=strtoull(argv[2],NULL,10);
    if(!pid||!expected||wait>10000)return 2;
    HANDLE process=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_INFORMATION,FALSE,pid);
    if(!process) {
        DWORD error=GetLastError();
        if(error==ERROR_INVALID_PARAMETER){puts("reader PID absent");return 0;}
        printf("OpenProcess error %lu\n",(unsigned long)error);return 3;
    }
    FILETIME created,exited,kernel,user;
    if(!GetProcessTimes(process,&created,&exited,&kernel,&user)){CloseHandle(process);return 4;}
    unsigned long long actual=(unsigned long long)created.dwHighDateTime<<32|created.dwLowDateTime;
    if(actual!=expected){CloseHandle(process);puts("original reader identity exited; PID reused");return 0;}
    DWORD result=WaitForSingleObject(process,wait);CloseHandle(process);
    if(result==WAIT_OBJECT_0){puts("reader process signalled");return 0;}
    printf("reader not reaped: wait result %lu\n",(unsigned long)result);return 5;
}
