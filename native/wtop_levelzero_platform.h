/* Loader services shared by Linux and native-architecture Windows readers. */
#ifndef WTOP_LEVELZERO_PLATFORM_H
#define WTOP_LEVELZERO_PLATFORM_H
#ifdef _WIN32
#ifndef WINVER
#define WINVER 0x0501
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0501
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <wchar.h>
#define WTOP_L0_CALL __cdecl
static void *l0_library_open(void) {
    WCHAR path[32768];
    UINT size=GetSystemDirectoryW(path,32768);
    if(!size||size>=32740)return NULL;
    /* The helper matches the OS architecture. Neither PATH nor the working
     * directory supplies a driver loader. Keep dependency lookup in System32. */
    if(!SetCurrentDirectoryW(path))return NULL;
    wcscat(path,L"\\ze_loader.dll");
    return LoadLibraryExW(path,NULL,LOAD_WITH_ALTERED_SEARCH_PATH);
}
static void *l0_library_symbol(void *library,const char *name) {
    return (void *)GetProcAddress((HMODULE)library,name);
}
static void l0_library_close(void *library) {FreeLibrary((HMODULE)library);}
#else
#include <dlfcn.h>
#define WTOP_L0_CALL
static void *l0_library_open(void) {
    void *library=dlopen("libze_loader.so.1",RTLD_NOW|RTLD_LOCAL);
    return library?library:dlopen("libze_loader.so",RTLD_NOW|RTLD_LOCAL);
}
static void *l0_library_symbol(void *library,const char *name) {return dlsym(library,name);}
static void l0_library_close(void *library) {dlclose(library);}
#endif
#endif
