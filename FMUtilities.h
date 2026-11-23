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

// The value at the path of keys through nested dictionaries, or nil where one isn't a dictionary
static inline id FMValueAtPath(id json, NSArray<NSString *> *path) {
    for(NSString *key in path)
        json = [json isKindOfClass:[NSDictionary class]] ? json[key] : nil;
    return json;
}

// Each emote position in an IRC emotes tag: "<id>:<from>-<to>,.../...", in code points, `to` inclusive
static inline void FMEnumerateIRCEmotes(NSString *tag, void (^block)(NSString *emoteID, NSUInteger from, NSUInteger to)) {
    for(NSString *emote in [tag componentsSeparatedByString:@"/"]) {
        NSRange colon = [emote rangeOfString:@":"];
        if(colon.location == NSNotFound || colon.location == 0)
            continue;
        NSString *emoteID = [emote substringToIndex:colon.location];
        for(NSString *range in [[emote substringFromIndex:NSMaxRange(colon)] componentsSeparatedByString:@","]) {
            NSArray<NSString *> *ends = [range componentsSeparatedByString:@"-"];
            if(ends.count == 2 && ends[0].integerValue >= 0 && ends[1].integerValue >= ends[0].integerValue)
                block(emoteID, ends[0].integerValue, ends[1].integerValue);
        }
    }
}

// The text of a /me ("\x01ACTION <text>\x01"), which IRC emote positions count from, or the text as is
static inline NSString *FMIRCActionText(NSString *text) {
    if(![text hasPrefix:@"\x01" "ACTION "])
        return text;
    return [[text substringFromIndex:8] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\x01"]];
}
