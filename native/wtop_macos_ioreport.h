/* Read-only IOReport sources with explicit warmup, failure and sample epochs. */
#ifndef WTOP_MACOS_IOREPORT_H
#define WTOP_MACOS_IOREPORT_H
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#define WTOP_REPORT_MAX_CHANNELS 1024
#define WTOP_REPORT_MAX_RAW_BYTES (1024 * 1024)
enum wtop_report_source { WTOP_REPORT_GPU, WTOP_REPORT_CPU, WTOP_REPORT_ENERGY, WTOP_REPORT_COUNT };
enum wtop_report_status { WTOP_REPORT_FAILED, WTOP_REPORT_WARMUP, WTOP_REPORT_FRESH };
struct wtop_report_sample {
    CFDictionaryRef owner; /* Caller releases this owned result, on every status. */
    CFArrayRef items;      /* Borrowed from owner; raw on warmup, delta on fresh. */
    uint64_t epoch, timestamp_ns;
    enum wtop_report_status status;
};
struct wtop_ioreport_functions {
    int32_t (*format)(CFDictionaryRef);
    int64_t (*integer)(CFDictionaryRef, int32_t);
    CFStringRef (*name)(CFDictionaryRef);
    CFStringRef (*unit)(CFDictionaryRef);
    int32_t (*state_count)(CFDictionaryRef);
    CFStringRef (*state_name)(CFDictionaryRef, int32_t);
    int64_t (*residency)(CFDictionaryRef, int32_t);
};
extern struct wtop_ioreport_functions wtop_ioreport;
enum wtop_report_status wtop_ioreport_sample(enum wtop_report_source source, struct wtop_report_sample *sample);
void wtop_ioreport_reset(enum wtop_report_source source);
void wtop_ioreport_cleanup(void);
#endif
