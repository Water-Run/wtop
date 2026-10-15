/* A failed subscription is closed; a later poll can discover the source again. */
#include "wtop_macos_ioreport.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef struct IOReportSubscription *subscription;
struct wtop_ioreport_functions wtop_ioreport;
static struct {
    void *library;
    int resolved, cleanup_registered;
    CFDictionaryRef (*copy_group)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
    subscription (*subscribe)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
    CFDictionaryRef (*samples)(subscription, CFMutableDictionaryRef, CFTypeRef);
    CFDictionaryRef (*delta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
} api;
static struct report_set {
    subscription subscription;
    CFMutableDictionaryRef channels, subscribed;
    CFDictionaryRef previous;
    CFArrayRef metadata;
    uint64_t epoch;
} sets[WTOP_REPORT_COUNT];

void wtop_ioreport_reset(enum wtop_report_source source) {
    if (source < 0 || source >= WTOP_REPORT_COUNT) return;
    struct report_set *set = &sets[source];
    if (set->previous) CFRelease(set->previous);
    if (set->metadata) CFRelease(set->metadata);
    if (set->subscription) CFRelease(set->subscription);
    if (set->subscribed) CFRelease(set->subscribed);
    if (set->channels) CFRelease(set->channels);
    uint64_t epoch = set->epoch;
    memset(set, 0, sizeof(*set)); set->epoch = epoch;
}
void wtop_ioreport_cleanup(void) {
    for (int source = 0; source < WTOP_REPORT_COUNT; ++source) wtop_ioreport_reset(source);
    if (api.library) dlclose(api.library);
    api.library = NULL; api.resolved = 0;
    memset(&wtop_ioreport, 0, sizeof(wtop_ioreport));
}
static int ready(enum wtop_report_source source) {
    if (!api.cleanup_registered) {
        if (atexit(wtop_ioreport_cleanup) != 0) return 0;
        api.cleanup_registered = 1;
    }
    if (!api.library) api.library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!api.library) return 0; /* Retry a transient load failure next time. */
    if (!api.resolved) {
        api.resolved = 1;
        api.copy_group = (void *)dlsym(api.library, "IOReportCopyChannelsInGroup");
        api.subscribe = (void *)dlsym(api.library, "IOReportCreateSubscription");
        api.samples = (void *)dlsym(api.library, "IOReportCreateSamples");
        api.delta = (void *)dlsym(api.library, "IOReportCreateSamplesDelta");
        wtop_ioreport.format = (void *)dlsym(api.library, "IOReportChannelGetFormat");
        wtop_ioreport.integer = (void *)dlsym(api.library, "IOReportSimpleGetIntegerValue");
        wtop_ioreport.name = (void *)dlsym(api.library, "IOReportChannelGetChannelName");
        wtop_ioreport.unit = (void *)dlsym(api.library, "IOReportChannelGetUnitLabel");
        wtop_ioreport.state_count = (void *)dlsym(api.library, "IOReportStateGetCount");
        wtop_ioreport.state_name = (void *)dlsym(api.library, "IOReportStateGetNameForIndex");
        wtop_ioreport.residency = (void *)dlsym(api.library, "IOReportStateGetResidency");
    }
    return api.copy_group && api.subscribe && api.samples && api.delta && wtop_ioreport.name && wtop_ioreport.format
        && (source == WTOP_REPORT_ENERGY ? wtop_ioreport.integer && wtop_ioreport.unit
            : wtop_ioreport.state_count && wtop_ioreport.state_name && wtop_ioreport.residency);
}
static CFArrayRef channel_list(CFTypeRef dictionary) {
    if (!dictionary || CFGetTypeID(dictionary) != CFDictionaryGetTypeID()) return NULL;
    CFTypeRef items = CFDictionaryGetValue(dictionary, CFSTR("IOReportChannels"));
    if (!items || CFGetTypeID(items) != CFArrayGetTypeID()) return NULL;
    CFIndex count = CFArrayGetCount(items);
    return count > 0 && count <= WTOP_REPORT_MAX_CHANNELS ? items : NULL;
}
/* RawElements contains counters/timestamps. Everything identifying the source
 * stays in metadata: driver, group, legend (ID/format/name), and encoded unit. */
struct report_identity {uint64_t driver,channel;CFDictionaryRef item;};
static int identity_compare(const void *a,const void *b){
    const struct report_identity *x=a,*y=b;
    if(x->driver!=y->driver)return (x->driver>y->driver)-(x->driver<y->driver);
    return (x->channel>y->channel)-(x->channel<y->channel);
}
static CFArrayRef metadata(CFArrayRef items) {
    CFIndex count=CFArrayGetCount(items);
    struct report_identity *keys=malloc((size_t)count*sizeof(*keys));
    CFMutableArrayRef result=NULL;
    if(!keys)return NULL;
    for(CFIndex i=0;i<count;++i){
        CFTypeRef item=CFArrayGetValueAtIndex(items,i);
        if(!item||CFGetTypeID(item)!=CFDictionaryGetTypeID())goto invalid;
        CFTypeRef legend=CFDictionaryGetValue(item,CFSTR("LegendChannel"));
        CFTypeRef raw=CFDictionaryGetValue(item,CFSTR("RawElements"));
        CFTypeRef info=CFDictionaryGetValue(item,CFSTR("IOReportChannelInfo"));
        CFTypeRef driver=CFDictionaryGetValue(item,CFSTR("DriverID"));
        if(!legend||CFGetTypeID(legend)!=CFArrayGetTypeID()||CFArrayGetCount(legend)<2
            ||CFGetTypeID(CFArrayGetValueAtIndex(legend,0))!=CFNumberGetTypeID()
            ||CFGetTypeID(CFArrayGetValueAtIndex(legend,1))!=CFNumberGetTypeID()
            ||CFNumberIsFloatType(CFArrayGetValueAtIndex(legend,0))
            ||CFNumberIsFloatType(CFArrayGetValueAtIndex(legend,1))
            ||(CFArrayGetCount(legend)>2&&CFGetTypeID(CFArrayGetValueAtIndex(legend,2))!=CFStringGetTypeID())
            ||!raw||CFGetTypeID(raw)!=CFDataGetTypeID()||CFDataGetLength(raw)<64
            ||CFDataGetLength(raw)%64||CFDataGetLength(raw)>WTOP_REPORT_MAX_RAW_BYTES
            ||!driver||CFGetTypeID(driver)!=CFNumberGetTypeID()||CFNumberIsFloatType(driver)
            ||!info||CFGetTypeID(info)!=CFDictionaryGetTypeID())goto invalid;
        int64_t driver_id,channel_id;
        if(!CFNumberGetValue(driver,kCFNumberSInt64Type,&driver_id)
            ||!CFNumberGetValue(CFArrayGetValueAtIndex(legend,0),kCFNumberSInt64Type,&channel_id))goto invalid;
        keys[i]=(struct report_identity){(uint64_t)driver_id,(uint64_t)channel_id,item};
    }
    qsort(keys,(size_t)count,sizeof(*keys),identity_compare);
    result=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    if(!result)goto invalid;
    for(CFIndex i=0;i<count;++i){
        if(i&&keys[i].driver==keys[i-1].driver&&keys[i].channel==keys[i-1].channel)goto invalid;
        CFMutableDictionaryRef identity=CFDictionaryCreateMutableCopy(NULL,0,keys[i].item);
        if(!identity)goto invalid;
        CFDictionaryRemoveValue(identity,CFSTR("RawElements"));
        CFPropertyListRef frozen=CFPropertyListCreateDeepCopy(NULL,identity,kCFPropertyListImmutable);
        CFRelease(identity);
        if(!frozen)goto invalid;
        CFArrayAppendValue(result,frozen);CFRelease(frozen);
    }
    free(keys);return result;
invalid:
    if(result)CFRelease(result);free(keys);return NULL;
}
static int same_metadata(CFArrayRef a,CFArrayRef b){return a&&b&&CFEqual(a,b);}
static int open_set(enum wtop_report_source source) {
    struct report_set *set = &sets[source];
    if (set->subscription) return 1;
    if (!ready(source) || set->epoch == UINT64_MAX) return 0;
    CFStringRef group = source == WTOP_REPORT_ENERGY ? CFSTR("Energy Model")
        : source == WTOP_REPORT_CPU ? CFSTR("CPU Stats") : CFSTR("GPU Stats");
    CFStringRef subgroup = source == WTOP_REPORT_ENERGY ? NULL : source == WTOP_REPORT_CPU
        ? CFSTR("CPU Complex Performance States") : CFSTR("GPU Performance States");
    CFDictionaryRef found = api.copy_group(group, subgroup, 0, 0, 0);
    if (!channel_list(found)) { if (found) CFRelease(found); return 0; }
    set->channels = CFDictionaryCreateMutableCopy(NULL, 0, found); CFRelease(found);
    if (!set->channels) return 0;
    set->subscription = api.subscribe(NULL, set->channels, &set->subscribed, 0, NULL);
    if (!set->subscription || !channel_list(set->subscribed)) { wtop_ioreport_reset(source); return 0; }
    ++set->epoch;
    return 1;
}
enum wtop_report_status wtop_ioreport_sample(enum wtop_report_source source, struct wtop_report_sample *sample) {
    memset(sample, 0, sizeof(*sample));
    if (source < 0 || source >= WTOP_REPORT_COUNT || !open_set(source)) return WTOP_REPORT_FAILED;
    struct report_set *set = &sets[source];
    CFDictionaryRef current = api.samples(set->subscription, set->subscribed, NULL), delta = NULL;
    struct timespec now;
    int clock_ok=clock_gettime(CLOCK_MONOTONIC,&now)==0;
    CFArrayRef current_items = channel_list(current), current_metadata = NULL, delta_metadata = NULL;
    if (!current_items || !(current_metadata = metadata(current_items))
        || !clock_ok || now.tv_sec < 0
        || now.tv_nsec < 0 || now.tv_nsec >= 1000000000
        || (uint64_t)now.tv_sec > ((uint64_t)INT64_MAX - (uint64_t)now.tv_nsec) / UINT64_C(1000000000)) goto failed;
    sample->timestamp_ns = (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
    sample->epoch = set->epoch;
    if (!set->previous) {
        sample->owner = CFRetain(current); sample->items = current_items;
        sample->status = WTOP_REPORT_WARMUP;
    } else {
        if (!same_metadata(set->metadata, current_metadata)) goto failed;
        delta = api.delta(set->previous, current, NULL);
        CFArrayRef items = channel_list(delta);
        if (!items || !(delta_metadata = metadata(items)) || !same_metadata(current_metadata, delta_metadata)) goto failed;
        sample->owner = delta; sample->items = items; sample->status = WTOP_REPORT_FRESH;
        delta = NULL;
    }
    if (set->previous) CFRelease(set->previous);
    if (set->metadata) CFRelease(set->metadata);
    set->previous = current; set->metadata = current_metadata;
    if (delta_metadata) CFRelease(delta_metadata);
    return sample->status;
failed:
    if (delta_metadata) CFRelease(delta_metadata);
    if (current_metadata) CFRelease(current_metadata);
    if (delta) CFRelease(delta);
    if (current) CFRelease(current);
    wtop_ioreport_reset(source);
    memset(sample, 0, sizeof(*sample));
    return WTOP_REPORT_FAILED;
}
