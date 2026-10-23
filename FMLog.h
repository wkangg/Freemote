#import <os/log.h>
#import <stdatomic.h>

// NSLog redacts arguments as <private> on device; mark them %{public}@ instead
#define FMLog(fmt, ...) os_log(OS_LOG_DEFAULT, "[Freemote] " fmt, ##__VA_ARGS__)

// For things that can happen on every message: logs the first `limit` times from this call site only
#define FMLogFirst(limit, fmt, ...) do { \
    static atomic_int _fmLogCount; \
    if(atomic_fetch_add(&_fmLogCount, 1) < (limit)) \
        FMLog(fmt, ##__VA_ARGS__); \
} while(0)
