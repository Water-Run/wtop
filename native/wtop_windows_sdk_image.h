/* Immutable reader binaries in the user's application cache. The read handle
 * pins verified bytes against replacement for the whole reader lifetime. */
#ifndef WTOP_WINDOWS_SDK_IMAGE_H
#define WTOP_WINDOWS_SDK_IMAGE_H
#include "wtop_nvml_helpers.h"
static HANDLE nvml_reader_image(WCHAR *path,DWORD capacity) {
    SYSTEM_INFO info;GetSystemInfo(&info);
    typedef void (WINAPI *native_info_fn)(LPSYSTEM_INFO);
    native_info_fn native_info=(native_info_fn)(void *)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"GetNativeSystemInfo");
    if(native_info)native_info(&info);
    int bits=info.wProcessorArchitecture==PROCESSOR_ARCHITECTURE_AMD64?64:32;
    if(info.wProcessorArchitecture!=PROCESSOR_ARCHITECTURE_AMD64
        &&info.wProcessorArchitecture!=PROCESSOR_ARCHITECTURE_INTEL)return NULL;
    const unsigned char *image=bits==64?wtop_nvml_x64:wtop_nvml_x86;
    DWORD size=(DWORD)(bits==64?sizeof(wtop_nvml_x64):sizeof(wtop_nvml_x86));
    DWORD length=GetEnvironmentVariableW(L"APPDATA",path,capacity);
    if(!length||length>=capacity-80||!((length>=3&&path[1]==L':'
        &&(path[2]==L'\\'||path[2]==L'/'))||(length>=2&&path[0]==L'\\'&&path[1]==L'\\')))return NULL;
    wcscat(path,L"\\wtop");
    if(!CreateDirectoryW(path,NULL)&&GetLastError()!=ERROR_ALREADY_EXISTS)return NULL;
    wcscat(path,L"\\readers");
    if(!CreateDirectoryW(path,NULL)&&GetLastError()!=ERROR_ALREADY_EXISTS)return NULL;
    length=(DWORD)wcslen(path);
    int used=_snwprintf(path+length,capacity-length,L"\\nvml-x%d-%08lx.exe",bits,(unsigned long)gpu_checksum(image,size));
    if(used<=0||(DWORD)used>=capacity-length)return NULL;
    HANDLE writer=CreateFileW(path,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(writer!=INVALID_HANDLE_VALUE){
        DWORD done=0;int ok=1;
        while(done<size){DWORD n=0;if(!WriteFile(writer,image+done,size-done,&n,NULL)||!n){ok=0;break;}done+=n;}
        if(!CloseHandle(writer))ok=0;
        if(!ok){DeleteFileW(path);return NULL;}
    }else if(GetLastError()!=ERROR_FILE_EXISTS&&GetLastError()!=ERROR_ALREADY_EXISTS)return NULL;
    HANDLE guard=INVALID_HANDLE_VALUE;
    for(unsigned attempt=0;attempt<50;++attempt){
        guard=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
        if(guard!=INVALID_HANDLE_VALUE)break;
        if(GetLastError()!=ERROR_SHARING_VIOLATION)return NULL;
        Sleep(2);
    }
    if(guard==INVALID_HANDLE_VALUE)return NULL;
    LARGE_INTEGER actual;
    if(!GetFileSizeEx(guard,&actual)||actual.QuadPart!=size){CloseHandle(guard);return NULL;}
    unsigned char buffer[4096];DWORD done=0;
    while(done<size){DWORD n=0,amount=size-done;if(amount>sizeof(buffer))amount=sizeof(buffer);
        if(!ReadFile(guard,buffer,amount,&n,NULL)||n!=amount||memcmp(buffer,image+done,n)){CloseHandle(guard);return NULL;}
        done+=n;}
    return guard;
}
#endif
