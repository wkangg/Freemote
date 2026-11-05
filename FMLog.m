#import "FMLog.h"
#import "FMSettings.h"
#import <os/log.h>

static const unsigned long long kMaxLogSize = 10 * 1024 * 1024;

static dispatch_queue_t logQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.gilesgc.freemote.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *logPath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"Freemote.log"];
}

void FMLogMessage(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    // %{public} so it isn't redacted as <private> on device
    os_log(OS_LOG_DEFAULT, "[Freemote] %{public}@", message);
    if(![NSUserDefaults.standardUserDefaults boolForKey:FMDebugLogKey])
        return;
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";
    });
    NSDate *date = [NSDate date];
    dispatch_async(logQueue(), ^{
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:date], message];
        NSString *path = logPath();
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if(!handle) {
            [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        unsigned long long size = [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
        if(size < kMaxLogSize)
            return;
        // Keep the newer half, from the start of a line
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSData *tail = [data subdataWithRange:NSMakeRange(data.length / 2, data.length - data.length / 2)];
        NSRange newline = [tail rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, tail.length)];
        if(newline.location != NSNotFound)
            tail = [tail subdataWithRange:NSMakeRange(NSMaxRange(newline), tail.length - NSMaxRange(newline))];
        [tail writeToFile:path atomically:YES];
    });
}

NSString *FMLogContents(void) {
    __block NSString *contents;
    dispatch_sync(logQueue(), ^{
        contents = [NSString stringWithContentsOfFile:logPath() encoding:NSUTF8StringEncoding error:nil];
    });
    return contents ?: @"";
}

void FMLogClear(void) {
    dispatch_sync(logQueue(), ^{
        [NSFileManager.defaultManager removeItemAtPath:logPath() error:nil];
    });
}
