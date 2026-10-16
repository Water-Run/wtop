#ifndef WTOP_TEST_NVML_PATHS_H
#define WTOP_TEST_NVML_PATHS_H
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
static UINT WINAPI test_system_directory(WCHAR *path,UINT capacity){
 WCHAR root[32768];DWORD n=GetEnvironmentVariableW(L"WTOP_NVML_TEST_ROOT",root,32768);
 if(!n||n>32000||n+8>=capacity)return 0;
 wcscat(root,L"\\system");wcscpy(path,root);return (UINT)wcslen(path);
}
static DWORD WINAPI test_environment(const WCHAR *name,WCHAR *path,DWORD capacity){
 if(!wcscmp(name,L"ProgramW6432")||!wcscmp(name,L"ProgramFiles")){
  WCHAR root[32768];DWORD n=GetEnvironmentVariableW(L"WTOP_NVML_TEST_ROOT",root,32768);
  if(!n||n>32000||n+9>=capacity)return 0;
  wcscat(root,L"\\program");wcscpy(path,root);return (DWORD)wcslen(path);
 }
 return GetEnvironmentVariableW(name,path,capacity);
}
#define GetSystemDirectoryW test_system_directory
#define GetEnvironmentVariableW test_environment
#endif
