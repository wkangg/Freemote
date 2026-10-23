#import "BTTVEmote.h"

@implementation BTTVEmote

- (id)initWithDictData:(NSDictionary *)data emoteType:(EmoteType)type {
    self = [super init];

    if(self) {
        _emoteType = type;

        if(type == SevenTV || type == SevenTVGlobal)
            return [self loadSevenTVData:data] ? self : nil;
        
        if(data[@"code"])
            _emoteText = data[@"code"];
        
        if(data[@"id"]) {
            if([data[@"id"] isKindOfClass:[NSNumber class]])
                _emoteID = [data[@"id"] stringValue];
            else
                _emoteID = data[@"id"];
        }
        
        if(data[@"imageType"] && [data[@"imageType"] isKindOfClass:[NSString class]])
            _isAnimated = [data[@"imageType"] isEqualToString:@"gif"];

        if(data[@"images"]) {
            //Emotes like this are ffz emotes, which have IDs that conflict with the default twitch emotes
            //To make them unique I add "ffz" to the end of the ID
            _emoteID = [_emoteID stringByAppendingString:@"ffz"];
            if(data[@"images"][@"1x"] && [data[@"images"][@"1x"] isKindOfClass:[NSString class]])
                _image1x = [NSURL URLWithString:data[@"images"][@"1x"]];
            if(data[@"images"][@"2x"] && [data[@"images"][@"2x"] isKindOfClass:[NSString class]])
                _image2x = [NSURL URLWithString:data[@"images"][@"2x"]];
        } else {
            _image1x = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.betterttv.net/emote/%@/1x", _emoteID]];
            _image2x = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.betterttv.net/emote/%@/2x", _emoteID]];
        }
    }

    return self;
}

// 7TV emote set entry: {id, name (the alias used in this set), data: {animated, ...}}
- (BOOL)loadSevenTVData:(NSDictionary *)data {
    NSString *emoteID = data[@"id"];
    NSString *name = data[@"name"];
    NSDictionary *emoteData = data[@"data"];
    if(![emoteID isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]])
        return NO;

    _emoteText = name;
    // Suffixed like FFZ IDs so they can't collide with other providers
    _emoteID = [emoteID stringByAppendingString:@"7tv"];
    _isAnimated = [emoteData isKindOfClass:[NSDictionary class]] && [emoteData[@"animated"] boolValue];

    // 7TV serves webp/avif plus gif (animated) or png (static); the app can only decode the latter
    NSString *extension = _isAnimated ? @"gif" : @"png";
    _image1x = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/1x.%@", emoteID, extension]];
    _image2x = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/2x.%@", emoteID, extension]];
    return YES;
}

@end