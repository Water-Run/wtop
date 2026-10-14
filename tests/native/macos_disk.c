/* Exercise media ownership and the real disk collector without touching disks. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <IOKit/storage/IOStorageDeviceCharacteristics.h>
#include <IOKit/storage/IOStorageProtocolCharacteristics.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { MEDIA_CHANGED = 1, DRIVER_CHANGED = 2, NAME_CHANGED = 4,
    PROVIDER_CHANGED = 8, MEDIA_REPARENTED = 16, MULTIPLE_WHOLE = 32,
    DUPLICATE_NAME = 64, COUNTER_MISSING = 128, ENUM_FAILED = 256,
    ENUM_INVALID = 512, DRIVER_FLOOD = 1024, CHILD_FLOOD = 2048,
    COUNTER_OVERFLOW = 4096, UNKNOWN_REMOVABLE = 8192, BAD_NAME = 16384,
    WHOLE_CHANGED = 32768 };
static unsigned mode, references, next_calls, parent_calls[20], id_calls[20], name_calls[20];
static unsigned whole_calls[20];
static int oom_enabled, fail_allocation;
static CFMutableDictionaryRef properties[20];
static const unsigned parents[20] = { 0,0,1,2,3,4,5,5,5,5,2,10,11,4 };
struct iterator { unsigned used, kind, entry, cursor; };
static struct iterator iterators[16];

static unsigned retain(unsigned object) { if (object) ++references; return object; }
static unsigned new_iterator(unsigned kind, unsigned entry) {
    for (unsigned i = 0; i < 16; ++i) if (!iterators[i].used) {
        iterators[i] = (struct iterator){1,kind,entry,0}; ++references; return 100+i;
    }
    assert(0); return 0;
}
static CFMutableDictionaryRef fixture_matching(const char *name) {
    assert(!strcmp(name, kIOBlockStorageDriverClass));
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
}
static kern_return_t fixture_services(mach_port_t port, CFDictionaryRef matching,
    io_iterator_t *iterator) {
    (void)port; CFRelease(matching); *iterator = 0;
    if (mode & ENUM_FAILED) return KERN_FAILURE;
    *iterator = new_iterator(1,0); return KERN_SUCCESS;
}
static io_object_t fixture_next(io_iterator_t handle) {
    assert(handle >= 100 && handle < 116); ++next_calls;
    struct iterator *it = &iterators[handle-100]; assert(it->used);
    unsigned cursor = it->cursor++;
    if (it->kind == 1) {
        if (mode & DRIVER_FLOOD) return retain(5);
        static const unsigned drivers[] = {5,11,13};
        return cursor < 3 ? retain(drivers[cursor]) : 0;
    }
    if (it->kind == 2) {
        if ((mode & CHILD_FLOOD) && it->entry == 5) return retain(6);
        if (it->entry == 5) {
            static const unsigned children[] = {6,7,8,9};
            unsigned count = mode & MULTIPLE_WHOLE ? 4 : 3;
            return cursor < count ? retain(children[cursor]) : 0;
        }
        if (it->entry == 11 && cursor == 0) return retain(12);
        return 0;
    }
    if (cursor) return 0;
    unsigned parent = parents[it->entry];
    if ((mode & PROVIDER_CHANGED) && it->entry == 5 && parent_calls[5] > 1) parent = 10;
    if ((mode & MEDIA_REPARENTED) && it->entry == 8 && parent_calls[8] > 1) parent = 11;
    return retain(parent);
}
static boolean_t fixture_valid(io_iterator_t handle) {
    return !((mode & ENUM_INVALID) && iterators[handle-100].kind == 1);
}
static kern_return_t fixture_release(io_object_t object) {
    assert(object && references); --references;
    if (object >= 100) {
        assert(iterators[object-100].used);
        if (oom_enabled && iterators[object-100].kind == 1) fail_allocation = 1;
        iterators[object-100].used = 0;
    }
    return KERN_SUCCESS;
}
static kern_return_t fixture_children(io_registry_entry_t entry, const io_name_t plane,
    io_iterator_t *iterator) {
    (void)plane; *iterator = new_iterator(2,entry); return KERN_SUCCESS;
}
static kern_return_t fixture_parent(io_registry_entry_t entry, const io_name_t plane,
    io_iterator_t *iterator) {
    (void)plane; ++parent_calls[entry]; *iterator = new_iterator(3,entry); return KERN_SUCCESS;
}
static boolean_t fixture_plane(io_registry_entry_t entry, const io_name_t plane) {
    (void)plane; return entry != 1;
}
static kern_return_t fixture_id(io_registry_entry_t entry, uint64_t *id) {
    assert(entry > 0 && entry < 20); ++id_calls[entry]; *id = 1000+entry;
    if ((mode & MEDIA_CHANGED) && entry == 8 && id_calls[8] > 1) *id += 10000;
    if ((mode & DRIVER_CHANGED) && entry == 5 && id_calls[5] > 1) *id += 10000;
    return KERN_SUCCESS;
}
static boolean_t fixture_class(io_object_t entry, const io_name_t name) {
    if (!strcmp(name,"IOMedia")) return entry==7 || entry==8 || entry==9 || entry==12;
    if (!strcmp(name,"IOPCIDevice")) return entry==2;
    if (!strcmp(name,"IOUSBHostDevice")) return entry==3;
    return 0;
}
static io_registry_entry_t fixture_root(mach_port_t port) { (void)port; return retain(1); }
static boolean_t fixture_equal(io_object_t a, io_object_t b) { return a==b; }
static CFTypeRef fixture_property(io_registry_entry_t entry, CFStringRef key,
    CFAllocatorRef allocator, IOOptionBits options) {
    (void)allocator; (void)options;
    if (CFEqual(key,CFSTR(kIOMediaWholeKey))) {
        ++whole_calls[entry];
        if ((mode & WHOLE_CHANGED) && entry==8 && whole_calls[8]>1) return CFRetain(kCFBooleanFalse);
    }
    if (CFEqual(key,CFSTR(kIOBSDNameKey))) {
        ++name_calls[entry];
        if ((mode & NAME_CHANGED) && entry==8 && name_calls[8]>1) return CFRetain(CFSTR("disk9"));
        if ((mode & DUPLICATE_NAME) && entry==12) return CFRetain(CFSTR("disk0"));
        if ((mode & BAD_NAME) && entry==8) {
            static const UInt8 bytes[]="disk0\0wrong";
            return CFStringCreateWithBytes(NULL,bytes,sizeof(bytes)-1,kCFStringEncodingUTF8,0);
        }
    }
    if ((mode & UNKNOWN_REMOVABLE) && CFEqual(key,CFSTR(kIOMediaRemovableKey))) return NULL;
    CFTypeRef value = CFDictionaryGetValue(properties[entry],key);
    return value ? CFRetain(value) : NULL;
}
#define IOServiceMatching fixture_matching
#define IOServiceGetMatchingServices fixture_services
#define IOIteratorNext fixture_next
#define IOIteratorIsValid fixture_valid
#define IOObjectRelease fixture_release
#define IORegistryEntryGetChildIterator fixture_children
#define IORegistryEntryGetParentIterator fixture_parent
#define IORegistryEntryInPlane fixture_plane
#define IORegistryEntryGetRegistryEntryID fixture_id
#define IOObjectConformsTo fixture_class
#define IORegistryGetRootEntry fixture_root
#define IOObjectIsEqualTo fixture_equal
#define IORegistryEntryCreateCFProperty fixture_property
#include "../../native/wtop_macos_disk.c"

static void put_number(CFMutableDictionaryRef d, CFStringRef key, int64_t value) {
    CFNumberRef number = CFNumberCreate(NULL,kCFNumberSInt64Type,&value);
    CFDictionarySetValue(d,key,number); CFRelease(number);
}
static void set_statistics(unsigned entry) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL,0,
        &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    for (unsigned i=0;i<6;++i) {
        if ((mode & COUNTER_MISSING) && entry==5 && i==0) continue;
        int64_t value = i<4 ? 0 : 100;
        if ((mode & COUNTER_OVERFLOW) && i>=4) value=INT64_MAX;
        put_number(d,counter_key(i),value);
    }
    CFDictionarySetValue(properties[entry],CFSTR(kIOBlockStorageDriverStatisticsKey),d); CFRelease(d);
}
static void assert_released(void) {
    assert(references==0);
    for (unsigned i=1;i<20;++i) {
        assert(CFGetRetainCount(properties[i])==1);
        for(unsigned k=0;k<3;++k) {
            CFStringRef key=k==0 ? CFSTR(kIOBlockStorageDriverStatisticsKey) : k==1
                ? CFSTR(kIOPropertyDeviceCharacteristicsKey) : CFSTR(kIOPropertyProtocolCharacteristicsKey);
            CFTypeRef value=CFDictionaryGetValue(properties[i],key);
            if(value) assert(CFGetRetainCount(value)==1);
        }
    }
}
static void check(lua_State *L,unsigned flags,const char *script) {
    mode=flags;next_calls=0;
    memset(parent_calls,0,sizeof(parent_calls));memset(id_calls,0,sizeof(id_calls));memset(name_calls,0,sizeof(name_calls));
    memset(whole_calls,0,sizeof(whole_calls));
    set_statistics(5);set_statistics(11);
    lua_pushcfunction(L,wtop_collect_disk);int status=lua_pcall(L,0,1,0);
    if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));assert(status==LUA_OK);
    assert_released();lua_setglobal(L,"data");status=luaL_dostring(L,script);
    if(status!=LUA_OK)fprintf(stderr,"%s\n",lua_tostring(L,-1));assert(status==LUA_OK);
}
struct allocator {lua_Alloc original;void *context;};
static void *failing_allocator(void *context,void *pointer,size_t old,size_t size) {
    struct allocator *a=context;
    if(size && fail_allocation) {assert_released();return NULL;}
    return a->original(a->context,pointer,old,size);
}
int main(void) {
    for(unsigned i=1;i<20;++i) properties[i]=CFDictionaryCreateMutable(NULL,0,
        &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    for(unsigned i=7;i<=12;++i)if(i==7 || i==8 || i==9 || i==12) {
        CFDictionarySetValue(properties[i],CFSTR(kIOMediaWholeKey),i==7?kCFBooleanFalse:kCFBooleanTrue);
        CFDictionarySetValue(properties[i],CFSTR(kIOBSDNameKey),i==8?CFSTR("disk0"):CFSTR("disk1"));
        CFDictionarySetValue(properties[i],CFSTR(kIOMediaRemovableKey),kCFBooleanFalse);
        put_number(properties[i],CFSTR(kIOMediaSizeKey),0);
    }
    for(unsigned i=4;i<=10;i+=6) {
        CFMutableDictionaryRef d=CFDictionaryCreateMutable(NULL,0,
            &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(d,CFSTR(kIOPropertyProductNameKey),CFSTR("中文 SSD  "));
        CFDictionarySetValue(d,CFSTR(kIOPropertyMediumTypeKey),CFSTR(kIOPropertyMediumTypeSolidStateKey));
        CFDictionarySetValue(properties[i],CFSTR(kIOPropertyDeviceCharacteristicsKey),d);CFRelease(d);
        d=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(d,CFSTR(kIOPropertyPhysicalInterconnectTypeKey),CFSTR("USB"));
        CFDictionarySetValue(properties[i],CFSTR(kIOPropertyProtocolCharacteristicsKey),d);CFRelease(d);
    }
    lua_State *L=luaL_newstate();assert(L);luaL_openlibs(L);
    check(L,0,"assert(data.quality==nil and #data.devices==2 and data.total==2 and not data.truncated); "
        "local a,b=data.devices[1],data.devices[2]; assert(a.name=='disk0' and a.stable_id=='ioreg:1005:1008' and a.identity_quality=='stable'); "
        "assert(a._registry_parent_id=='ioreg:1003' and a._registry_parent_bus=='usb' and b._registry_parent_id=='ioreg:1002' and b._registry_parent_bus=='pci'); "
        "assert(a.identity.model=='中文 SSD' and a.identity.size_bytes==0 and a.identity.removable==false and a.identity.rotational==0); "
        "assert(a.counters.bytes_read==0 and a.counters.service_time_ns==200)");
    for(unsigned flag=MEDIA_CHANGED;flag<=MEDIA_REPARENTED;flag<<=1)
        check(L,flag,"assert(data.quality=='partial' and #data.devices==1 and data.devices[1].name=='disk1')");
    check(L,MULTIPLE_WHOLE,"assert(data.quality=='partial' and #data.devices==1)");
    check(L,DUPLICATE_NAME,"assert(data.quality=='partial' and #data.devices==0)");
    check(L,COUNTER_MISSING,"assert(data.quality=='partial' and data.devices[1].partial and data.devices[1].counters.bytes_read==nil and data.devices[1].counters.reads==0)");
    check(L,ENUM_INVALID,"assert(data.quality=='partial' and data.devices[1]._registry_parent_id==nil)");
    check(L,DRIVER_FLOOD,"assert(data.quality=='partial' and data.truncated and data.total==4096 and #data.devices==0)");assert(next_calls<50000);
    check(L,CHILD_FLOOD,"assert(data.quality=='partial' and #data.devices==1)");assert(next_calls<200);
    check(L,COUNTER_OVERFLOW,"assert(data.devices[1].counters.read_time_ns==math.maxinteger and data.devices[1].counters.service_time_ns==nil)");
    check(L,UNKNOWN_REMOVABLE,"assert(data.quality==nil and data.devices[1].identity.removable==nil)");
    check(L,BAD_NAME,"assert(data.quality=='partial' and #data.devices==1)");
    check(L,WHOLE_CHANGED,"assert(data.quality=='partial' and #data.devices==1)");
    mode=ENUM_FAILED;lua_pushcfunction(L,wtop_collect_disk);assert(lua_pcall(L,0,2,0)==LUA_OK);assert(lua_isnil(L,-2));lua_pop(L,2);assert_released();
    mode=0;memset(parent_calls,0,sizeof(parent_calls));memset(id_calls,0,sizeof(id_calls));memset(name_calls,0,sizeof(name_calls));
    set_statistics(5);set_statistics(11);
    struct allocator a;a.original=lua_getallocf(L,&a.context);lua_setallocf(L,failing_allocator,&a);
    lua_pushcfunction(L,wtop_collect_disk);oom_enabled=1;int status=lua_pcall(L,0,1,0);
    oom_enabled=fail_allocation=0;assert(status==LUA_ERRMEM);assert_released();lua_setallocf(L,a.original,a.context);lua_close(L);
    for(unsigned i=1;i<20;++i)CFRelease(properties[i]);
    puts("macOS disks: whole media, driver/media epochs, BSD reuse, provider/media reparenting, duplicate names, zero/missing fields, Unicode, overflow, scan limits and OOM cleanup passed");
    return 0;
}
