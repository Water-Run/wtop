/* Test-only substitute for the system loader location. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
static UINT WINAPI adl_test_directory(WCHAR *path,UINT capacity) {
    WCHAR root[32768];DWORD size=GetEnvironmentVariableW(L"WTOP_ADL_TEST_ROOT",root,32768);
    if(!size||size>32000||size+8>=capacity)return 0;
    wcscat(root,L"\\system");wcscpy(path,root);return (UINT)wcslen(path);
}
#define GetSystemDirectoryW adl_test_directory
