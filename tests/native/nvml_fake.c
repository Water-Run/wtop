#define _POSIX_C_SOURCE 200809L
#define NVML_NO_UNVERSIONED_FUNC_DEFS
#ifdef WTOP_NVML_SDK_HEADER
#include WTOP_NVML_SDK_HEADER
#else
#include "../fixtures/nvml/sdk.h"
#endif
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>

static int mode, refs, inits, shutdowns, calls, count_calls, uuid_calls[2], legacy_calls, power_calls;
static unsigned long long last_seen[2];
static int cards[2];
static void fixture_hang(void){for(;;)pause();}
static void fixture_control(void) {
    const char *path=getenv("WTOP_NVML_FIXTURE_CONTROL");if(!path)return;
    FILE *file=fopen(path,"r");if(!file)return;
    int value;if(fscanf(file,"%d",&value)==1)mode=value;fclose(file);
}
__attribute__((constructor)) static void fixture_constructor(void) {
    const char *setting=getenv("WTOP_NVML_FIXTURE_MODE");int scenario=setting?atoi(setting):0;
    if(scenario==45)fixture_hang();
    if(scenario==50){puts("driver stdout must not enter the protocol");fputs("driver stderr noise\n",stderr);fflush(stdout);fflush(stderr);}
    if(scenario==56){const char bad[]="corrupt driver bytes";ssize_t sent=write(3,bad,sizeof(bad));(void)sent;}
    if(scenario==57){uint32_t bad[16]={0x4d4e5457,1,UINT32_MAX};ssize_t sent=write(3,bad,sizeof(bad));(void)sent;}
    if(scenario==58){
        const char *value=getenv("WTOP_NVML_TEST_FD_INO");struct stat st;
        if(value&&!fstat(20,&st)&&(unsigned long long)st.st_ino==strtoull(value,NULL,10))_exit(123);
    }
}
void fixture_reset(int scenario) { assert(!refs); mode = scenario; inits = shutdowns = calls = count_calls = legacy_calls = power_calls = 0; memset(uuid_calls,0,sizeof(uuid_calls)); memset(last_seen,0,sizeof(last_seen)); }
void fixture_mode(int scenario) { mode = scenario; count_calls = 0; memset(uuid_calls,0,sizeof(uuid_calls)); }
int fixture_refs(void) { return refs; }
int fixture_inits(void) { return inits; }
int fixture_shutdowns(void) { return shutdowns; }
int fixture_legacy(void) { return legacy_calls; }
int fixture_power_calls(void) { return power_calls; }
unsigned long long fixture_cursor(int card) { return last_seen[card]; }
#if WTOP_NVML_VARIANT != 2
static int id(nvmlDevice_t device) {
    assert(refs > 0); calls++;
    for (int i = 0; i < 2; ++i) if (device == (nvmlDevice_t)&cards[i]) return i;
    assert(!"invalid opaque NVML device"); return 0;
}
#endif
#if WTOP_NVML_VARIANT == 1
nvmlReturn_t nvmlInit(void)
#else
nvmlReturn_t nvmlInit_v2(void)
#endif
{ const char *setting = getenv("WTOP_NVML_FIXTURE_MODE");
  if (setting) mode = atoi(setting);
  if(mode==46)fixture_hang();
  if(mode==52){struct timespec delay={0,800000000};nanosleep(&delay,NULL);}
  inits++; if (mode == 1) return 9; refs++; return 0; }
#if WTOP_NVML_VARIANT != 3
nvmlReturn_t nvmlShutdown(void) { if(mode==49)fixture_hang();assert(refs > 0); refs--; shutdowns++; return 0; }
#endif
#if WTOP_NVML_VARIANT == 1
nvmlReturn_t nvmlDeviceGetCount(unsigned int *count)
#else
nvmlReturn_t nvmlDeviceGetCount_v2(unsigned int *count)
#endif
{
    fixture_control();
    assert(refs > 0); count_calls++;
    if(mode==47)fixture_hang();
    if (mode == 2) return 9;
    if (mode == 3) return 4;
    if (mode == 34) return 15;
    *count = mode == 5 ? 65 : mode == 32 && count_calls % 2 == 0 ? 3 : 2; return 0;
}
#if WTOP_NVML_VARIANT == 1
nvmlReturn_t nvmlDeviceGetHandleByIndex(unsigned int index, nvmlDevice_t *device)
#else
nvmlReturn_t nvmlDeviceGetHandleByIndex_v2(unsigned int index, nvmlDevice_t *device)
#endif
{
    assert(refs > 0);
    if (index >= 2 || (mode == 4 && index == 0)) return 6;
    *device = (nvmlDevice_t)&cards[mode == 30 ? 1 - index : index]; return 0;
}
#if WTOP_NVML_VARIANT != 2
static int failed(nvmlDevice_t device) { (void)id(device); return mode == 33; }
nvmlReturn_t nvmlSystemGetDriverVersion(char *out, unsigned int size) {
    assert(refs > 0 && size >= 80);
    if (mode == 6) memset(out,'X',size); else snprintf(out,size,"595.00"); return 0;
}
nvmlReturn_t nvmlDeviceGetName(nvmlDevice_t device, char *out, unsigned int size) {
    if (failed(device)) return 1;
    if (mode == 6) memset(out,'X',size); else snprintf(out,size,"NVIDIA SDK fixture %d",id(device)); return 0;
}
nvmlReturn_t nvmlDeviceGetUUID(nvmlDevice_t device, char *out, unsigned int size) {
    if (failed(device)) return 1;
    int card = id(device); uuid_calls[card]++;
    if (mode == 6) memset(out,'X',size);
    else snprintf(out,size,"GPU-fixture-%d",mode == 31 && card == 0 && uuid_calls[card] % 2 == 0 ? 99 : card);
    return 0;
}
#if WTOP_NVML_VARIANT == 1
nvmlReturn_t nvmlDeviceGetPciInfo(nvmlDevice_t device, nvmlPciInfo_t *out)
#else
nvmlReturn_t nvmlDeviceGetPciInfo_v3(nvmlDevice_t device, nvmlPciInfo_t *out)
#endif
{
    if (failed(device)) return 1;
    memset(out,0xff,sizeof(*out));
    if (mode == 6) return 0;
    out->domain = mode == 38 ? 0x10000u : 0xabcd; out->bus = (unsigned int)id(device) + 3;
    out->device = 0x1a; out->pciDeviceId = 0x20b010de; out->pciSubSystemId = 0x100110de;
    snprintf(out->busIdLegacy,sizeof(out->busIdLegacy),"%04x:%02x:1a.3",out->domain,out->bus);
#if WTOP_NVML_VARIANT != 1
    snprintf(out->busId,sizeof(out->busId),"%08x:%02x:1a.3",out->domain,out->bus);
    if (mode == 39) out->bus++;
#endif
    return 0;
}
nvmlReturn_t nvmlDeviceGetUtilizationRates(nvmlDevice_t device, nvmlUtilization_t *out) {
    if(mode==48)fixture_hang();
    if(mode==51){raise(SIGSEGV);_exit(99);}
    if (failed(device)) return 1;
    out->gpu = mode == 7 ? 101 : mode == 8 ? 0 : 71;
    out->memory = mode == 7 ? UINT_MAX : mode == 8 ? 0 : 12; return 0;
}
nvmlReturn_t nvmlDeviceGetMemoryInfo(nvmlDevice_t device, nvmlMemory_t *out) {
    if (failed(device)) return 1;
    out->total = mode == 8 ? 0 : 24ULL << 30; out->free = 0;
    out->used = mode == 7 ? out->total + 1 : mode == 8 ? 0 : 6ULL << 30; return 0;
}
nvmlReturn_t nvmlDeviceGetTemperature(nvmlDevice_t device, nvmlTemperatureSensors_t sensor, unsigned int *out) {
    if (failed(device)) return 1;
    assert(sensor == 0); *out = mode == 7 ? UINT_MAX : mode == 8 ? 0 : 58; return 0;
}
nvmlReturn_t nvmlDeviceGetPowerUsage(nvmlDevice_t device, unsigned int *out) {
    if (failed(device)) return 1;
    power_calls++; *out = mode == 7 || mode == 37 ? UINT_MAX : mode == 8 ? 0 : 123456; return 0;
}
nvmlReturn_t nvmlDeviceGetEnforcedPowerLimit(nvmlDevice_t device, unsigned int *out) {
    if (failed(device)) return 1;
    *out = mode == 7 ? UINT_MAX : 355500; return 0;
}
nvmlReturn_t nvmlDeviceGetClockInfo(nvmlDevice_t device, nvmlClockType_t clock, unsigned int *out) {
    if (failed(device)) return 1;
    assert(clock == 0 || clock == 2); *out = mode == 7 ? UINT_MAX : mode == 8 ? 0 : clock == 0 ? 2510 : 1050; return 0;
}
nvmlReturn_t nvmlDeviceGetMaxClockInfo(nvmlDevice_t device, nvmlClockType_t clock, unsigned int *out) {
    if (failed(device)) return 1;
    assert(clock == 0); *out = mode == 7 ? UINT_MAX : 2900; return 0;
}
nvmlReturn_t nvmlDeviceGetFanSpeed(nvmlDevice_t device, unsigned int *out) {
    if (failed(device)) return 1;
    *out = mode == 7 ? 101 : mode == 8 ? 0 : 42; return 0;
}
nvmlReturn_t nvmlDeviceGetPerformanceState(nvmlDevice_t device, nvmlPstates_t *out) {
    if (failed(device)) return 1;
    *out = mode == 7 ? 32 : 0; return 0;
}
#if WTOP_NVML_VARIANT != 1
nvmlReturn_t nvmlDeviceGetCurrentClocksEventReasons(nvmlDevice_t device, unsigned long long *out) {
    if (failed(device)) return 1;
    if (mode == 12) return 4;
    if (mode == 13 || WTOP_NVML_VARIANT == 4) return 13;
    *out = mode == 9 ? 0 : mode == 10 ? 0x44 : mode == 11 ? (1ULL << 63) | 4 : mode == 15 ? ~0ULL : 4; return 0;
}
nvmlReturn_t nvmlDeviceGetSupportedClocksEventReasons(nvmlDevice_t device, unsigned long long *out) {
    if (failed(device)) return 1;
    if (mode == 14 || WTOP_NVML_VARIANT == 4) return 3;
    *out = 0x7ff; return 0;
}
nvmlReturn_t nvmlDeviceGetFieldValues(nvmlDevice_t device, int count, nvmlFieldValue_t *out) {
    if (failed(device)) return 1;
    assert(count == 2 && out[0].fieldId == 186 && out[1].fieldId == 185);
    assert(out[0].scopeId == 0 && out[1].scopeId == 0);
    for (int i = 0; i < 2; ++i) {
        struct timespec now; assert(clock_gettime(CLOCK_REALTIME, &now)==0);
        out[i].nvmlReturn = 0; out[i].valueType = 1;
        out[i].timestamp = (long long)now.tv_sec * 1000000 + now.tv_nsec / 1000;
        if ((mode==40 && i==0) || mode==41) out[i].timestamp -= 6000000;
        if (mode==42) out[i].timestamp += 6000000;
        if (mode==43) out[i].timestamp = 0;
        out[i].latencyUsec = 0;
        out[i].value.uiVal = mode == 8 ? 0 : i == 0 ? 300000 : 42250;
        if (mode == 7 || mode == 37) { out[i].valueType = 0; out[i].value.dVal = NAN; }
        if (mode == 16 && i == 0) out[i].nvmlReturn = 3;
        if (mode == 17) out[i].valueType = 100;
        if (mode == 18) { out[i].nvmlReturn = i == 0 ? 4 : 3; out[i].value.uiVal = 90000000; }
        if (mode == 19) { out[i].scopeId = 1; out[i].value.uiVal = 90000000; }
    }
    if (mode >= 20 && mode <= 25) {
        unsigned int type = (unsigned int)(mode - 20); out[0].valueType = type;
        switch (type) {
            case 0: out[0].value.dVal = 300000.0; break;
            case 1: out[0].value.uiVal = 300000; break;
            case 2: out[0].value.ulVal = 300000; break;
            case 3: out[0].value.ullVal = 300000; break;
            case 4: out[0].value.sllVal = 300000; break;
            case 5: out[0].value.siVal = 300000; break;
        }
    }
    return 0;
}
#endif
nvmlReturn_t nvmlDeviceGetCurrentClocksThrottleReasons(nvmlDevice_t device, unsigned long long *out) {
    if (failed(device)) return 1;
    legacy_calls++; if (mode == 12) return 4;
    *out = mode == 9 ? 0 : mode == 10 ? 0x44 : mode == 11 ? (1ULL << 63) | 4 : mode == 15 ? ~0ULL : 4; return 0;
}
nvmlReturn_t nvmlDeviceGetSupportedClocksThrottleReasons(nvmlDevice_t device, unsigned long long *out) {
    if (failed(device)) return 1;
    if (mode == 14) return 3;
    *out = 0x7ff; return 0;
}
#if WTOP_NVML_VARIANT != 1
static nvmlReturn_t process_values(nvmlDevice_t device, unsigned int *count, nvmlProcessInfo_t *out, int graphics) {
    if (failed(device)) return 1;
    assert(*count == 256);
    if (mode == 26) { *count = 500; return 7; }
    memset(out,0xff,2 * sizeof(*out));
    out[0].pid = mode == 27 ? 0 : 4242; out[0].usedGpuMemory = mode == 36 ? ~0ULL : 1ULL << 30;
    out[0].gpuInstanceId = 3; out[0].computeInstanceId = 4;
    if (!graphics) {
        out[1].pid = mode == 27 ? UINT_MAX : 4343; out[1].usedGpuMemory = 2ULL << 30; *count = 2;
    } else if (mode == 28) {
        out[1].pid = 4242; out[1].usedGpuMemory = 3ULL << 30;
        out[1].gpuInstanceId = 5; out[1].computeInstanceId = 6; *count = 2;
    } else *count = 1;
    return 0;
}
#if WTOP_NVML_VARIANT != 1 && WTOP_NVML_VARIANT != 4
nvmlReturn_t nvmlDeviceGetComputeRunningProcesses_v3(nvmlDevice_t d, unsigned int *n, nvmlProcessInfo_t *out) { return process_values(d,n,out,0); }
nvmlReturn_t nvmlDeviceGetGraphicsRunningProcesses_v3(nvmlDevice_t d, unsigned int *n, nvmlProcessInfo_t *out) { return process_values(d,n,out,1); }
#endif
#if WTOP_NVML_VARIANT == 4
nvmlReturn_t nvmlDeviceGetComputeRunningProcesses_v2(nvmlDevice_t d, unsigned int *n, nvmlProcessInfo_v2_t *out) { return process_values(d,n,out,0); }
nvmlReturn_t nvmlDeviceGetGraphicsRunningProcesses_v2(nvmlDevice_t d, unsigned int *n, nvmlProcessInfo_v2_t *out) { return process_values(d,n,out,1); }
#endif
#endif
#if WTOP_NVML_VARIANT == 1
nvmlReturn_t nvmlDeviceGetComputeRunningProcesses(nvmlDevice_t device, unsigned int *count, nvmlProcessInfo_v1_t *out) {
    if (failed(device)) return 1;
    assert(*count == 256);
    if (mode == 26) { *count = 500; return 7; }
    *count = 1; out[0].pid = mode == 27 ? 0 : 4242; out[0].usedGpuMemory = mode == 36 ? ~0ULL : 1ULL << 30; return 0;
}
nvmlReturn_t nvmlDeviceGetGraphicsRunningProcesses(nvmlDevice_t device, unsigned int *count, nvmlProcessInfo_v1_t *out) {
    return nvmlDeviceGetComputeRunningProcesses(device,count,out);
}
#endif
nvmlReturn_t nvmlDeviceGetProcessUtilization(nvmlDevice_t device, nvmlProcessUtilizationSample_t *out, unsigned int *count, unsigned long long previous) {
    if (failed(device)) return 1;
    int card = id(device); last_seen[card] = previous; assert(*count == 256);
    if (mode == 35) return 6;
    if (mode == 26) { *count = 500; return 7; }
    memset(out,0,2 * sizeof(*out)); *count = 2;
    out[0].pid = out[1].pid = mode == 27 ? UINT_MAX : 4242;
    out[0].timeStamp = previous ? previous + 100 : 200 + (unsigned long long)card * 1000;
    out[1].timeStamp = out[0].timeStamp - 100;
    out[0].smUtil = 10; out[1].smUtil = 90;
    return 0;
}
#endif
