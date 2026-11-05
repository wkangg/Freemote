#import <Foundation/Foundation.h>
#import <stdatomic.h>

// Logs to the system log, and to a file shown in settings while FMDebugLogKey is on
void FMLogMessage(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *FMLogContents(void);
void FMLogClear(void);

#define FMLog(fmt, ...) FMLogMessage(@fmt, ##__VA_ARGS__)

// For things that can happen on every message: logs the first `limit` times from this call site only
#define FMLogFirst(limit, fmt, ...) do { \
    static atomic_int _fmLogCount; \
    if(atomic_fetch_add(&_fmLogCount, 1) < (limit)) \
        FMLog(fmt, ##__VA_ARGS__); \
} while(0)
