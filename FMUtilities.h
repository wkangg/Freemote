#import <Foundation/Foundation.h>

// Small helpers shared by more than one file

// Missing, or JSON null
static inline BOOL FMIsNull(id value) {
    return !value || value == [NSNull null];
}

// A Twitch channel (or video) ID: a non-empty string of digits
static inline BOOL FMIsChannelID(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length]
        && [(NSString *)value rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet].invertedSet].location == NSNotFound;
}
