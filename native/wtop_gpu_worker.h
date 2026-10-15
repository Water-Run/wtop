#ifndef WTOP_GPU_WORKER_H
#define WTOP_GPU_WORKER_H
#include "wtop_gpu_output.h"
enum gpu_vendor { GPU_NVML, GPU_AMDSMI, GPU_LEVELZERO, GPU_VENDOR_COUNT };
#ifdef WTOP_GPU_WORKER
const char *wtop_nvml_collect(gpu_output *out,int processes);
void wtop_nvml_finish(void);
const char *wtop_amdsmi_collect(gpu_output *out,int processes);
const char *wtop_levelzero_prepare(int legacy);
const char *wtop_levelzero_collect(gpu_output *out,int processes);
void wtop_levelzero_finish(void);
#else
#include <lua.h>
int wtop_gpu_worker_open(lua_State *L);
int wtop_gpu_worker_query(lua_State *L);
int wtop_gpu_worker_close(lua_State *L);
#endif
#endif
