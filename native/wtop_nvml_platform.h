/* Driver-library and UTC clock services used by the shared NVML collector. */
#ifndef WTOP_NVML_PLATFORM_H
#define WTOP_NVML_PLATFORM_H
#ifdef _WIN32
#ifndef WINVER
#define WINVER 0x0501
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0501
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
static void *nvml_library_open(void) {
    WCHAR path[32768];
    DWORD size=GetSystemDirectoryW(path,32768);
    if(size&&size<32750){
        /* The reader uses the native OS architecture, avoiding WOW64 path
         * redirection. A driver in the working directory is not a candidate. */
        SetCurrentDirectoryW(path);
        wcscat(path,L"\\nvml.dll");
        HMODULE module=LoadLibraryExW(path,NULL,LOAD_WITH_ALTERED_SEARCH_PATH);
        if(module)return module;
    }
    size=GetEnvironmentVariableW(L"ProgramW6432",path,32768);
    if(!size)size=GetEnvironmentVariableW(L"ProgramFiles",path,32768);
    if(!size||size>=32700||!((path[0]&&path[1]==L':'&&(path[2]==L'\\'||path[2]==L'/'))
        ||(path[0]==L'\\'&&path[1]==L'\\')))return NULL;
    wcscat(path,L"\\NVIDIA Corporation\\NVSMI\\nvml.dll");
    return LoadLibraryExW(path,NULL,LOAD_WITH_ALTERED_SEARCH_PATH);
}
static void *nvml_library_symbol(void *library,const char *name) {
    return (void *)GetProcAddress((HMODULE)library,name);
}
static void nvml_library_close(void *library) { FreeLibrary((HMODULE)library); }
static int nvml_realtime_us(int64_t *value) {
    FILETIME time;GetSystemTimeAsFileTime(&time);
    uint64_t ticks=((uint64_t)time.dwHighDateTime<<32)|time.dwLowDateTime;
    if(ticks<UINT64_C(116444736000000000))return 0;
    *value=(int64_t)((ticks-UINT64_C(116444736000000000))/10);return 1;
}
#else
#include <dlfcn.h>
#include <time.h>
static void *nvml_library_open(void) {return dlopen("libnvidia-ml.so.1",RTLD_NOW|RTLD_LOCAL);}
static void *nvml_library_symbol(void *library,const char *name) {return dlsym(library,name);}
static void nvml_library_close(void *library) {dlclose(library);}
static int nvml_realtime_us(int64_t *value) {
    struct timespec time;if(clock_gettime(CLOCK_REALTIME,&time)||time.tv_sec<0
        ||(uint64_t)time.tv_sec>=INT64_MAX/UINT64_C(1000000))return 0;
    *value=(int64_t)time.tv_sec*INT64_C(1000000)+time.tv_nsec/1000;return 1;
}
#endif
#endif
