/* Shared SDK output operations. The SDK reader can target Lua or the bounded
 * worker protocol without linking the worker against a Lua runtime. */
#ifndef WTOP_NVML_OUTPUT_H
#define WTOP_NVML_OUTPUT_H
#include <stdint.h>
enum nvml_operation {
    NVML_TABLE=1, NVML_INTEGER, NVML_NUMBER, NVML_STRING, NVML_BOOLEAN,
    NVML_FIELD, NVML_INDEX, NVML_DISCARD
};
typedef struct nvml_output {
    void *context;
    int failed;
    void (*emit)(struct nvml_output *,enum nvml_operation,const char *,int64_t,double,const char *);
} nvml_output;
static inline void nvml_table(nvml_output *o,int array,int fields) {
    o->emit(o,NVML_TABLE,NULL,((int64_t)array<<32)|(unsigned int)fields,0,NULL);
}
static inline void integer_field(nvml_output *o,const char *key,int64_t value) {
    o->emit(o,NVML_INTEGER,key,value,0,NULL);
}
static inline void number_field(nvml_output *o,const char *key,double value) {
    o->emit(o,NVML_NUMBER,key,0,value,NULL);
}
static inline void string_field(nvml_output *o,const char *key,const char *value) {
    o->emit(o,NVML_STRING,key,0,0,value);
}
static inline void boolean_field(nvml_output *o,const char *key,int value) {
    o->emit(o,NVML_BOOLEAN,key,value!=0,0,NULL);
}
static inline void nvml_field_attach(nvml_output *o,const char *key) {
    o->emit(o,NVML_FIELD,key,0,0,NULL);
}
static inline void nvml_index(nvml_output *o,int index) {
    o->emit(o,NVML_INDEX,NULL,index,0,NULL);
}
static inline void nvml_discard(nvml_output *o) {
    o->emit(o,NVML_DISCARD,NULL,0,0,NULL);
}
#endif
