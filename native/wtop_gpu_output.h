/* Shared GPU SDK output operations. Each backend can target Lua or the bounded
 * worker protocol without linking the worker against a Lua runtime. */
#ifndef WTOP_GPU_OUTPUT_H
#define WTOP_GPU_OUTPUT_H
#include <stdint.h>
#include <stddef.h>
enum gpu_operation {
    GPU_TABLE=1, GPU_INTEGER, GPU_NUMBER, GPU_STRING, GPU_BOOLEAN,
    GPU_FIELD, GPU_INDEX, GPU_DISCARD
};
typedef struct gpu_output {
    void *context;
    int failed;
    void (*emit)(struct gpu_output *,enum gpu_operation,const char *,int64_t,double,const char *);
} gpu_output;
static inline void gpu_table(gpu_output *o,int array,int fields) {
    o->emit(o,GPU_TABLE,NULL,((int64_t)array<<32)|(unsigned int)fields,0,NULL);
}
static inline void integer_field(gpu_output *o,const char *key,int64_t value) {
    o->emit(o,GPU_INTEGER,key,value,0,NULL);
}
static inline void number_field(gpu_output *o,const char *key,double value) {
    o->emit(o,GPU_NUMBER,key,0,value,NULL);
}
static inline void string_field(gpu_output *o,const char *key,const char *value) {
    o->emit(o,GPU_STRING,key,0,0,value);
}
static inline void boolean_field(gpu_output *o,const char *key,int value) {
    o->emit(o,GPU_BOOLEAN,key,value!=0,0,NULL);
}
static inline void gpu_field_attach(gpu_output *o,const char *key) {
    o->emit(o,GPU_FIELD,key,0,0,NULL);
}
static inline void gpu_index(gpu_output *o,int index) {
    o->emit(o,GPU_INDEX,NULL,index,0,NULL);
}
static inline void gpu_discard(gpu_output *o) {
    o->emit(o,GPU_DISCARD,NULL,0,0,NULL);
}
#endif
