/* Explicit inherited-handle lists on Vista+, with a runtime XP fallback.
 * No newer kernel entry point is part of the program's import table. */
#ifndef WTOP_WINDOWS_SPAWN_H
#define WTOP_WINDOWS_SPAWN_H
struct wtop_startup_ex {STARTUPINFOW startup;void *attributes;};
typedef BOOL(WINAPI *wtop_init_attributes)(void *,DWORD,DWORD,SIZE_T *);
typedef BOOL(WINAPI *wtop_update_attributes)(void *,DWORD,DWORD_PTR,void *,SIZE_T,void *,SIZE_T *);
typedef void(WINAPI *wtop_delete_attributes)(void *);
static int wtop_spawn_reader(const WCHAR *executable,WCHAR *command,STARTUPINFOW *startup,
    HANDLE *handles,unsigned count,PROCESS_INFORMATION *process){
    HMODULE kernel=GetModuleHandleW(L"kernel32.dll");
    wtop_init_attributes initialize=(wtop_init_attributes)(void *)GetProcAddress(kernel,"InitializeProcThreadAttributeList");
    wtop_update_attributes update=(wtop_update_attributes)(void *)GetProcAddress(kernel,"UpdateProcThreadAttribute");
    wtop_delete_attributes destroy=(wtop_delete_attributes)(void *)GetProcAddress(kernel,"DeleteProcThreadAttributeList");
    if(!initialize||!update||!destroy)
        return CreateProcessW(executable,command,NULL,NULL,TRUE,CREATE_NO_WINDOW,NULL,NULL,startup,process)!=0;
    SIZE_T size=0;(void)initialize(NULL,1,0,&size);
    if(!size||size>65536)return 0;
    void *list=malloc(size);if(!list)return 0;
    int initialized=initialize(list,1,0,&size)!=0,ok=0;
    if(initialized&&update(list,0,(DWORD_PTR)0x00020002,handles,(SIZE_T)count*sizeof(*handles),NULL,NULL)){
        struct wtop_startup_ex extended;memset(&extended,0,sizeof(extended));
        extended.startup=*startup;extended.startup.cb=sizeof(extended);extended.attributes=list;
        ok=CreateProcessW(executable,command,NULL,NULL,TRUE,CREATE_NO_WINDOW|0x00080000,
            NULL,NULL,&extended.startup,process)!=0;
    }
    if(initialized)destroy(list);
    free(list);return ok;
}
#endif
